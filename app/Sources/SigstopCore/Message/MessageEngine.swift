import Foundation

public protocol RandomSource: AnyObject, Sendable {
    func nextUniform() -> Double
}

public final class SeededRandomSource: RandomSource, @unchecked Sendable {
    private let lock = NSLock()
    private var generator: SeededGenerator

    public init(seed: UInt64) {
        self.generator = SeededGenerator(seed: seed)
    }

    public func nextUniform() -> Double {
        lock.withLock {
            Double(generator.next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }
    }
}

public final class SystemRandomSource: RandomSource, @unchecked Sendable {
    public init() {}
    public func nextUniform() -> Double {
        var g = SystemRandomNumberGenerator()
        return Double.random(in: 0..<1, using: &g)
    }
}

enum StableHash {
    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

public struct RenderedMessage: Sendable, Hashable {
    public let templateID: String
    public let title: String?
    public let text: String
    public let tone: Tone
    public let category: String
    public let escalation: EscalationLevel
    public let isFallback: Bool
    public let theatrical: Bool

    public init(
        templateID: String, title: String?, text: String, tone: Tone, category: String,
        escalation: EscalationLevel, isFallback: Bool, theatrical: Bool
    ) {
        self.templateID = templateID
        self.title = title
        self.text = text
        self.tone = tone
        self.category = category
        self.escalation = escalation
        self.isFallback = isFallback
        self.theatrical = theatrical
    }
}

public enum RejectionReason: String, Sendable, Hashable, Codable {
    case escalationOutOfRange
    case toneAboveUserCeiling
    case toneNotAllowedAtThisLevel
    case predicateFailed
    case confidenceGate
    case requiredSlotUnavailable
    case unsupportedSchema
    case recencyRules
    case renderFailed
}

public struct SelectionTrace: Sendable, Hashable {
    public var totalTemplates: Int = 0
    public var afterHardGates: Int = 0
    public var afterRecency: Int = 0
    public var relaxation: RelaxationStage = .strict
    public var topScore: Int = 0
    public var bandSize: Int = 0
    public var effectiveToneCeiling: Tone = .friendly
    public var bandIDs: [String] = []
    public var rejections: [String: RejectionReason] = [:]
}

public struct SelectionResult: Sendable, Hashable {
    public let message: RenderedMessage
    public let trace: SelectionTrace
}

public final class MessageEngine: @unchecked Sendable {
    public let corpus: Corpus
    public let ledger: RecencyLedger
    public let slots: SlotResolver
    private let rng: any RandomSource

    public init(
        corpus: Corpus = .bundled,
        ledger: RecencyLedger = RecencyLedger(),
        slots: SlotResolver = SlotResolver(),
        rng: any RandomSource = SystemRandomSource()
    ) {
        self.corpus = corpus
        self.ledger = ledger
        self.slots = slots
        self.rng = rng
    }

    public static func effectiveToneCeiling(
        at level: EscalationLevel, userCeiling: Tone
    ) -> Tone {
        let levelCap: Tone
        switch level {
        case .first:     levelCap = .sarcastic
        case .second:    levelCap = .roast
        case .third:     levelCap = (userCeiling == .nuclear) ? .nuclear : .roast
        case .incident:  levelCap = .nuclear
        }
        return min(levelCap, userCeiling)
    }

    public static func confidenceGate(_ t: MessageTemplate, _ ctx: MessageContext) -> Bool {
        let usesActivity = t.usesActivityClaim
        let usesApp = t.usesAppPredicate

        if usesActivity && ctx.activityConfidence < t.minConfidence { return false }
        if usesApp && ctx.appConfidence < max(t.minConfidence, 0.60) { return false }

        if usesActivity && ctx.activityConfidence < 0.35 { return false }
        if usesApp && ctx.appConfidence < 0.35 { return false }
        return true
    }

    public func select(for ctx: MessageContext, record: Bool = true) -> SelectionResult {
        var trace = SelectionTrace()
        trace.totalTemplates = corpus.templates.count

        let ceiling = Self.effectiveToneCeiling(
            at: ctx.escalation, userCeiling: ctx.toneCeiling)
        trace.effectiveToneCeiling = ceiling
        let table = slots.table(for: ctx)

        var eligible: [MessageTemplate] = []
        eligible.reserveCapacity(corpus.templates.count)
        for t in corpus.templates {
            if let reason = Self.hardGateRejection(t, ctx, ceiling: ceiling, slots: slots, table: table) {
                trace.rejections[t.id] = reason
            } else {
                eligible.append(t)
            }
        }
        trace.afterHardGates = eligible.count

        let lastShownID = ledger.recentTemplateIDs(limit: 1).first
        var stage: RelaxationStage = .strict
        var candidates: [MessageTemplate] = []

        for s in RelaxationStage.allCases where s < .emergency {
            stage = s
            candidates = eligible.filter {
                $0.id != lastShownID
                    && ledger.allows($0, at: s, now: ctx.now, calendar: ctx.calendar)
            }
            if !candidates.isEmpty { break }
        }

        if candidates.isEmpty {
            stage = .emergency
            let pool = Corpus.emergencyPool.filter { $0.escalation.contains(ctx.escalation) }
            candidates = pool.filter { $0.id != lastShownID }
            if candidates.isEmpty { candidates = pool }
            if candidates.isEmpty { candidates = Corpus.emergencyPool }
        }
        trace.relaxation = stage
        trace.afterRecency = candidates.count

        var band = Self.band(candidates, ctx: ctx)
        trace.topScore = band.first.map(Scorer.score) ?? 0
        trace.bandSize = band.count
        trace.bandIDs = band.map(\.id)

        var chosen: MessageTemplate?
        var rendered: String?
        while !band.isEmpty {
            let pick = weightedPick(band, now: ctx.now)
            if let text = slots.fill(pick, table: table, family: ctx.appFamily) {
                chosen = pick
                rendered = text
                break
            }
            trace.rejections[pick.id] = .renderFailed
            band.removeAll { $0.id == pick.id }
            candidates.removeAll { $0.id == pick.id }
            if band.isEmpty { band = Self.band(candidates, ctx: ctx) }
        }

        if chosen == nil {
            for t in Corpus.emergencyPool where rendered == nil {
                if let text = slots.fill(t, table: table, family: ctx.appFamily) {
                    chosen = t
                    rendered = text
                    trace.relaxation = .emergency
                }
            }
        }

        let template = chosen ?? Corpus.lastResort
        let text = rendered ?? Corpus.lastResort.text

        if record {
            ledger.record(template, at: ctx.now)
        }

        let message = RenderedMessage(
            templateID: template.id,
            title: template.title,
            text: text,
            tone: template.tone,
            category: template.category,
            escalation: ctx.escalation,
            isFallback: template.isFallback,
            theatrical: template.theatrical
        )
        return SelectionResult(message: message, trace: trace)
    }

    public static func hardGateRejection(
        _ t: MessageTemplate,
        _ ctx: MessageContext,
        ceiling: Tone,
        slots: SlotResolver,
        table: [SlotKey: SlotValue]
    ) -> RejectionReason? {
        guard t.escalation.contains(ctx.escalation) else { return .escalationOutOfRange }
        guard t.tone <= ctx.toneCeiling else { return .toneAboveUserCeiling }
        guard t.tone <= ceiling else { return .toneNotAllowedAtThisLevel }
        guard t.when.allSatisfy({ $0.holds(in: ctx) }) else { return .predicateFailed }
        guard confidenceGate(t, ctx) else { return .confidenceGate }
        guard slots.canSatisfyRequired(t, table: table) else { return .requiredSlotUnavailable }
        return nil
    }

    static func band(_ candidates: [MessageTemplate], ctx: MessageContext) -> [MessageTemplate] {
        guard let best = candidates.map(Scorer.score).max() else { return [] }
        let cut = best - Scorer.bandTolerance
        return candidates
            .filter { Scorer.score($0) >= cut }
            .sorted {
                let (a, b) = (Scorer.score($0), Scorer.score($1))
                if a != b { return a > b }
                if $0.weight != $1.weight { return $0.weight > $1.weight }
                let (ka, kb) = (tieBreakKey($0, ctx: ctx), tieBreakKey($1, ctx: ctx))
                if ka != kb { return ka < kb }
                return $0.id < $1.id
            }
    }

    func weightedPick(_ band: [MessageTemplate], now: Date) -> MessageTemplate {
        precondition(!band.isEmpty, "weightedPick requires a non-empty band")
        if band.count == 1 { return band[0] }

        let weights = band.map { t -> Double in
            let toneFactor = ledger.toneIsOverused(t.tone) ? Policy.toneRepeatWeightMultiplier : 1.0
            return max(0.0001, t.weight * ledger.freshness(t, now: now) * toneFactor)
        }
        let total = weights.reduce(0, +)
        guard total > 0, total.isFinite else { return band[0] }

        var target = rng.nextUniform() * total
        for (i, w) in weights.enumerated() {
            target -= w
            if target < 0 { return band[i] }
        }
        return band[band.count - 1]
    }

    public static func tieBreakKey(_ t: MessageTemplate, ctx: MessageContext) -> UInt64 {
        let day = ctx.calendar.startOfDay(for: ctx.now).timeIntervalSince1970
        return StableHash.fnv1a("\(t.id)|\(Int(day))|\(ctx.escalation.rawValue)")
    }
}
