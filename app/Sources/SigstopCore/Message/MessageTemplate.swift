import Foundation

// MARK: - Predicates

public enum Predicate: Sendable, Hashable, Codable {
    case app(Set<AppKey>)
    case appFamily(Set<AppFamily>)
    case activity(Set<Activity>)
    case workBand(Set<WorkBand>)
    case timeBand(Set<TimeBand>)
    case weekday(Set<Weekday>)
    case minutesSinceBreak(atLeast: Int)
    case streak(StreakKey, atLeast: Int)
    case fact(FactKey, FactMatch)

    public func holds(in ctx: MessageContext) -> Bool {
        switch self {
        case .app(let s):
            return s.contains(ctx.app)
        case .appFamily(let s):
            return s.contains(ctx.appFamily)
        case .activity(let s):
            var node: Activity? = ctx.activity
            while let n = node {
                if s.contains(n) { return true }
                node = n.parent
            }
            return false
        case .workBand(let s):
            return s.contains(ctx.workBand)
        case .timeBand(let s):
            return s.contains(ctx.timeBand)
        case .weekday(let s):
            return s.contains(ctx.weekday)
        case .minutesSinceBreak(let n):
            return ctx.minutesSinceLastBreak >= n
        case .streak(let key, let n):
            return ctx.streak(key) >= n
        case .fact(let key, let match):
            guard let v = ctx.facts[key] else { return false }
            switch (match, v) {
            case (.isTrue, .bool(let b)):                return b
            case (.isFalse, .bool(let b)):               return !b
            case (.intAtLeast(let n), .int(let i)):      return i >= n
            case (.equalsString(let s), .string(let t)): return s == t
            default:                                     return false
            }
        }
    }

    /// How much context this predicate commits to. Higher = more specific = better match.
    /// Set size deliberately does not reduce the weight: penalising `[.vscode, .zed]`
    /// would push contributors to duplicate every line per app.
    public var specificity: Int {
        switch self {
        case .app:               return 40
        case .activity:          return 30
        case .fact:              return 25
        case .streak:            return 20
        case .appFamily:         return 15
        case .workBand:          return 12
        case .timeBand:          return 12
        case .minutesSinceBreak: return 8
        case .weekday:           return 5
        }
    }

    /// Stable label used for tracing and for the deterministic tie-break.
    public var kindName: String {
        switch self {
        case .app:               return "app"
        case .appFamily:         return "appFamily"
        case .activity:          return "activity"
        case .workBand:          return "workBand"
        case .timeBand:          return "timeBand"
        case .weekday:           return "weekday"
        case .minutesSinceBreak: return "minutesSinceBreak"
        case .streak:            return "streak"
        case .fact:              return "fact"
        }
    }

    // MARK: Codable, the `{ "p": ..., "in": [...] }` wire format from §7.2

    private enum CodingKeys: String, CodingKey {
        case p, `in`, atLeast, key, match, value
    }

    private static func decodeSet<T: RawRepresentable & Hashable & Decodable>(
        _ c: KeyedDecodingContainer<CodingKeys>, _ kind: String
    ) throws -> Set<T> where T.RawValue == String {
        let raw = try c.decode([String].self, forKey: .in)
        guard !raw.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .in, in: c, debugDescription: "predicate '\(kind)' needs a non-empty 'in'")
        }
        var out = Set<T>()
        for s in raw {
            guard let v = T(rawValue: s) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .in, in: c,
                    debugDescription: "'\(s)' is not a valid value for predicate '\(kind)'")
            }
            out.insert(v)
        }
        return out
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let p = try c.decode(String.self, forKey: .p)
        switch p {
        case "app":       self = .app(try Self.decodeSet(c, p))
        case "appFamily": self = .appFamily(try Self.decodeSet(c, p))
        case "activity":  self = .activity(try Self.decodeSet(c, p))
        case "workBand":  self = .workBand(try Self.decodeSet(c, p))
        case "timeBand":  self = .timeBand(try Self.decodeSet(c, p))
        case "weekday":   self = .weekday(try Self.decodeSet(c, p))
        case "minutesSinceBreak":
            self = .minutesSinceBreak(atLeast: try c.decode(Int.self, forKey: .atLeast))
        case "streak":
            let raw = try c.decode(String.self, forKey: .key)
            guard let k = StreakKey(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .key, in: c, debugDescription: "unknown streak key '\(raw)'")
            }
            self = .streak(k, atLeast: try c.decode(Int.self, forKey: .atLeast))
        case "fact":
            let raw = try c.decode(String.self, forKey: .key)
            guard let k = FactKey(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .key, in: c, debugDescription: "unknown fact key '\(raw)'")
            }
            let m = try c.decode(String.self, forKey: .match)
            switch m {
            case "isTrue":  self = .fact(k, .isTrue)
            case "isFalse": self = .fact(k, .isFalse)
            case "intAtLeast":
                self = .fact(k, .intAtLeast(try c.decode(Int.self, forKey: .value)))
            case "equalsString":
                self = .fact(k, .equalsString(try c.decode(String.self, forKey: .value)))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .match, in: c, debugDescription: "unknown match '\(m)'")
            }
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .p, in: c, debugDescription: "unknown predicate '\(p)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kindName, forKey: .p)
        func put<T: RawRepresentable>(_ s: Set<T>) throws where T.RawValue == String {
            try c.encode(s.map(\.rawValue).sorted(), forKey: .in)
        }
        switch self {
        case .app(let s):       try put(s)
        case .appFamily(let s): try put(s)
        case .activity(let s):  try put(s)
        case .workBand(let s):  try put(s)
        case .timeBand(let s):  try put(s)
        case .weekday(let s):   try put(s)
        case .minutesSinceBreak(let n):
            try c.encode(n, forKey: .atLeast)
        case .streak(let k, let n):
            try c.encode(k.rawValue, forKey: .key)
            try c.encode(n, forKey: .atLeast)
        case .fact(let k, let m):
            try c.encode(k.rawValue, forKey: .key)
            switch m {
            case .isTrue:  try c.encode("isTrue", forKey: .match)
            case .isFalse: try c.encode("isFalse", forKey: .match)
            case .intAtLeast(let n):
                try c.encode("intAtLeast", forKey: .match)
                try c.encode(n, forKey: .value)
            case .equalsString(let s):
                try c.encode("equalsString", forKey: .match)
                try c.encode(s, forKey: .value)
            }
        }
    }
}

// MARK: - Template

public struct MessageTemplate: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String?
    public let text: String
    /// A variant sentence with the optional slots removed. How a line keeps its joke when
    /// one detail goes missing.
    public let altText: String?
    public let tone: Tone
    public let category: String
    public let escalation: ClosedRange<EscalationLevel>
    public let minConfidence: Double
    /// True when the line asserts, as fact, what the developer is doing. These are the
    /// lines that destroy the product when they are wrong, so they are gated hardest.
    public let claimsActivity: Bool
    public let requiredSlots: [SlotKey]
    public let optionalSlots: [SlotKey]
    public let when: [Predicate]
    public let weight: Double
    public let authorPriority: Int
    public let cooldownHours: Int?
    public let isFallback: Bool
    public let theatrical: Bool
    public let plural: [SlotKey: [String: String]]?
    public let notes: String?

    public init(
        id: String,
        title: String? = nil,
        text: String,
        altText: String? = nil,
        tone: Tone,
        category: String,
        escalation: ClosedRange<EscalationLevel>,
        minConfidence: Double = 0,
        claimsActivity: Bool = false,
        requiredSlots: [SlotKey] = [],
        optionalSlots: [SlotKey] = [],
        when: [Predicate] = [],
        weight: Double = 1.0,
        authorPriority: Int = 0,
        cooldownHours: Int? = nil,
        isFallback: Bool = false,
        theatrical: Bool = false,
        plural: [SlotKey: [String: String]]? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.altText = altText
        self.tone = tone
        self.category = category
        self.escalation = escalation
        self.minConfidence = min(max(minConfidence, 0), 1)
        self.claimsActivity = claimsActivity
        self.requiredSlots = requiredSlots
        self.optionalSlots = optionalSlots
        self.when = when
        self.weight = min(max(weight, 0.1), 5.0)
        self.authorPriority = min(max(authorPriority, -10), 10)
        self.cooldownHours = cooldownHours
        self.isFallback = isFallback
        self.theatrical = theatrical
        self.plural = plural
        self.notes = notes
    }

    /// Every slot the rendered line may need to fill.
    public var allSlots: [SlotKey] { requiredSlots + optionalSlots }

    public var usesAppPredicate: Bool {
        when.contains { if case .app = $0 { return true }; return false }
            || requiredSlots.contains(.app)
    }

    /// A template "uses" the activity if it matches on one, prints one, or claims one.
    public var usesActivityClaim: Bool {
        when.contains { if case .activity = $0 { return true }; return false }
            || requiredSlots.contains(.activity)
            || claimsActivity
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, title, text, altText, tone, category, escalation, minConfidence
        case claimsActivity, requiredSlots, optionalSlots, when, weight, authorPriority
        case cooldownHours, isFallback, theatrical, plural, notes
    }

    private struct EscalationBounds: Codable {
        let min: Int
        let max: Int
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let bounds = try c.decode(EscalationBounds.self, forKey: .escalation)
        let lo = EscalationLevel(rawValue: Swift.min(Swift.max(bounds.min, 1), 4)) ?? .first
        let hi = EscalationLevel(rawValue: Swift.min(Swift.max(bounds.max, 1), 4)) ?? .incident
        let range = lo <= hi ? lo...hi : hi...lo

        self.init(
            id: try c.decode(String.self, forKey: .id),
            title: try c.decodeIfPresent(String.self, forKey: .title),
            text: try c.decode(String.self, forKey: .text),
            altText: try c.decodeIfPresent(String.self, forKey: .altText),
            tone: try c.decode(Tone.self, forKey: .tone),
            category: try c.decode(String.self, forKey: .category),
            escalation: range,
            minConfidence: try c.decodeIfPresent(Double.self, forKey: .minConfidence) ?? 0,
            claimsActivity: try c.decodeIfPresent(Bool.self, forKey: .claimsActivity) ?? false,
            requiredSlots: try c.decodeIfPresent([SlotKey].self, forKey: .requiredSlots) ?? [],
            optionalSlots: try c.decodeIfPresent([SlotKey].self, forKey: .optionalSlots) ?? [],
            when: try c.decodeIfPresent([Predicate].self, forKey: .when) ?? [],
            weight: try c.decodeIfPresent(Double.self, forKey: .weight) ?? 1.0,
            authorPriority: try c.decodeIfPresent(Int.self, forKey: .authorPriority) ?? 0,
            cooldownHours: try c.decodeIfPresent(Int.self, forKey: .cooldownHours),
            isFallback: try c.decodeIfPresent(Bool.self, forKey: .isFallback) ?? false,
            theatrical: try c.decodeIfPresent(Bool.self, forKey: .theatrical) ?? false,
            plural: try c.decodeIfPresent([SlotKey: [String: String]].self, forKey: .plural),
            notes: try c.decodeIfPresent(String.self, forKey: .notes)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(altText, forKey: .altText)
        try c.encode(tone, forKey: .tone)
        try c.encode(category, forKey: .category)
        try c.encode(
            EscalationBounds(min: escalation.lowerBound.rawValue, max: escalation.upperBound.rawValue),
            forKey: .escalation)
        try c.encode(minConfidence, forKey: .minConfidence)
        try c.encode(claimsActivity, forKey: .claimsActivity)
        try c.encode(requiredSlots, forKey: .requiredSlots)
        try c.encode(optionalSlots, forKey: .optionalSlots)
        try c.encode(when, forKey: .when)
        try c.encode(weight, forKey: .weight)
        try c.encode(authorPriority, forKey: .authorPriority)
        try c.encodeIfPresent(cooldownHours, forKey: .cooldownHours)
        try c.encode(isFallback, forKey: .isFallback)
        try c.encode(theatrical, forKey: .theatrical)
        try c.encodeIfPresent(plural, forKey: .plural)
        try c.encodeIfPresent(notes, forKey: .notes)
    }
}

// MARK: - Scoring

public enum Scorer {
    /// Per required slot: a line that commits to a detail is a line that earned it.
    public static let slotBonus = 4
    /// A template aimed at exactly one escalation rung is aimed.
    public static let tightEscalationBonus = 6
    /// Deliberately smaller than the cheapest strong predicate (`appFamily`, 15), so a
    /// template that pins the app or the activity can never be beaten inside the band by
    /// one that does not.
    public static let bandTolerance = 10

    public static func score(_ t: MessageTemplate) -> Int {
        var s = t.when.reduce(0) { $0 + $1.specificity }
        s += slotBonus * t.requiredSlots.count
        if t.escalation.lowerBound == t.escalation.upperBound { s += tightEscalationBonus }
        s += t.authorPriority
        return s
    }
}

// MARK: - Packs and corpus

public struct MessagePack: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let packId: String
    public let packVersion: String
    public let locale: String
    public let title: String?
    public let author: String?
    public let license: String?
    public let defaultWeight: Double?
    public let messages: [MessageTemplate]

    public static let supportedSchemaVersion = 1

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, packId, packVersion, locale, title, author, license
        case defaultWeight, messages
    }

    public init(
        schemaVersion: Int = supportedSchemaVersion,
        packId: String,
        packVersion: String = "1.0.0",
        locale: String = "en-US",
        title: String? = nil,
        author: String? = nil,
        license: String? = nil,
        defaultWeight: Double? = nil,
        messages: [MessageTemplate]
    ) {
        self.schemaVersion = schemaVersion
        self.packId = packId
        self.packVersion = packVersion
        self.locale = locale
        self.title = title
        self.author = author
        self.license = license
        self.defaultWeight = defaultWeight
        self.messages = messages
    }

    public var isSupported: Bool { schemaVersion == Self.supportedSchemaVersion }
}

public enum CorpusError: Error, Sendable, Equatable {
    case resourceMissing
    case unsupportedSchema(Int)
    case empty
}

public struct Corpus: Sendable, Hashable {
    public let packs: [MessagePack]
    /// Flattened, id-deduped (first pack wins), unsupported packs dropped wholesale,
    /// never partially, because a half-loaded pack produces exactly the coverage holes the
    /// lint exists to prevent.
    public let templates: [MessageTemplate]

    public init(packs: [MessagePack]) {
        self.packs = packs
        var seen = Set<String>()
        var flat: [MessageTemplate] = []
        for pack in packs where pack.isSupported {
            for m in pack.messages where seen.insert(m.id).inserted {
                flat.append(m)
            }
        }
        self.templates = flat
    }

    public var isEmpty: Bool { templates.isEmpty }

    public func template(id: String) -> MessageTemplate? {
        templates.first { $0.id == id }
    }

    // MARK: Loading

    /// Accepts either a single pack envelope (docs/MESSAGE-ENGINE.md §7.1) or a
    /// `{ "packs": [ ... ] }` wrapper, so a multi-pack file loads too.
    public static func decode(_ data: Data) throws -> Corpus {
        let decoder = JSONDecoder()
        if let pack = try? decoder.decode(MessagePack.self, from: data) {
            return Corpus(packs: [pack])
        }
        struct Wrapper: Decodable { let packs: [MessagePack] }
        let wrapper = try decoder.decode(Wrapper.self, from: data)
        return Corpus(packs: wrapper.packs)
    }

    /// The pack compiled into the app. Never throws at use sites: a corpus that fails to
    /// load degrades to the emergency pool rather than taking the app down.
    public static let bundled: Corpus = {
        (try? loadBundled()) ?? Corpus(packs: [])
    }()

    public static func loadBundled() throws -> Corpus {
        let candidates = [
            Bundle.module.url(forResource: "corpus", withExtension: "json"),
            Bundle.module.url(forResource: "corpus", withExtension: "json", subdirectory: "Message"),
        ]
        guard let url = candidates.compactMap({ $0 }).first else {
            throw CorpusError.resourceMissing
        }
        return try decode(try Data(contentsOf: url))
    }

    // MARK: Emergency pool

    public static let emergencyPool: [MessageTemplate] = [
        MessageTemplate(
            id: "emergency.fallback.still-here",
            text: "Whatever this is, it will still be here in five minutes. Go be somewhere else for four of them.",
            tone: .friendly, category: "emergency", escalation: EscalationLevel.first...EscalationLevel.incident,
            isFallback: true),
        MessageTemplate(
            id: "emergency.fallback.nothing-is-lost",
            text: "Stopping here costs nothing. You come back with everything you had.",
            tone: .friendly, category: "emergency", escalation: EscalationLevel.first...EscalationLevel.incident,
            isFallback: true),
        MessageTemplate(
            id: "emergency.fallback.water-exists",
            text: "Long stretch. Water exists. Go verify.",
            tone: .friendly, category: "emergency", escalation: EscalationLevel.first...EscalationLevel.incident,
            isFallback: true),
        MessageTemplate(
            id: "emergency.fallback.five-minutes",
            text: "Five minutes. That is the entire ask.",
            tone: .friendly, category: "emergency", escalation: EscalationLevel.first...EscalationLevel.incident,
            isFallback: true),
        MessageTemplate(
            id: "emergency.fallback.stand-once",
            text: "Stand up once. Sit back down if you must. The offer stands either way.",
            tone: .friendly, category: "emergency", escalation: EscalationLevel.first...EscalationLevel.incident,
            isFallback: true),
        MessageTemplate(
            id: "emergency.fallback.the-stack-survives",
            text: "The stack you are holding survives a five-minute pause. That is the whole promise.",
            tone: .friendly, category: "emergency", escalation: EscalationLevel.first...EscalationLevel.incident,
            isFallback: true),
    ]

    /// The line of absolute last resort. `select` returns a message even if every pool,
    /// including the emergency one, has somehow been emptied.
    public static let lastResort = MessageTemplate(
        id: "emergency.fallback.last-resort",
        text: "Break time. Back in five.",
        tone: .friendly, category: "emergency", escalation: EscalationLevel.first...EscalationLevel.incident,
        isFallback: true)
}
