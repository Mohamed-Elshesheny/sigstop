import Foundation

public enum BadgeID: String, Sendable, Hashable, CaseIterable, Codable {
    case stoppedOnce = "stopped-1"
    case niceN10 = "nice-n-10"
    case unmasked
    case provablyHalts = "provably-halts"
    case sigDFL = "sig-dfl"
    case einval
    case schedYield = "sched-yield"
    case earlyReturn = "early-return"
    case nohup
    case stoppedHundred = "stopped-100"
}

public enum BadgeMotif: String, Sendable, Hashable, Codable {
    case jobLine = "job-line"
    case descent
    case liftedGate = "lifted-gate"
    case tombstone
    case straightThrough = "straight-through"
    case escalation
    case handoff
    case earlyExit = "early-exit"
    case detached
    case jobLineFull = "job-line-full"
}

public enum BadgeThreshold {
    public static let firstBreak = 1
    public static let tenBreaks = 10
    public static let hundredBreaks = 100
    public static let haltingDays = 10
    public static let reflexAccepts = 5
    public static let reflexWindow: TimeInterval = 15
    public static let yieldMinimumWork: TimeInterval = 4 * 3600
    public static let yieldStretchCeiling: TimeInterval = 3600
    public static let clockDays = 5
    public static let earlyHour = 10
    public static let lateHour = 1
}

public struct BadgeEvidence: Sendable, Hashable {
    public var breaksTaken: Int
    public var cleanDays: Int
    public var reflexAccepts: Int
    public var reachedSigstop: Bool
    public var yieldDays: Int
    public var earlyDays: Int
    public var lateDays: Int

    public init(
        breaksTaken: Int = 0,
        cleanDays: Int = 0,
        reflexAccepts: Int = 0,
        reachedSigstop: Bool = false,
        yieldDays: Int = 0,
        earlyDays: Int = 0,
        lateDays: Int = 0
    ) {
        self.breaksTaken = breaksTaken
        self.cleanDays = cleanDays
        self.reflexAccepts = reflexAccepts
        self.reachedSigstop = reachedSigstop
        self.yieldDays = yieldDays
        self.earlyDays = earlyDays
        self.lateDays = lateDays
    }
}

public struct BadgeProgress: Sendable, Hashable {
    public let have: Int
    public let need: Int

    public init(have: Int, need: Int) {
        self.have = have
        self.need = need
    }

    public var fraction: Double { need > 0 ? Double(have) / Double(need) : 0 }
}

public struct Badge: Sendable, Identifiable {
    public let id: BadgeID
    public let title: String
    public let motif: BadgeMotif
    public let blurb: String
    public let lockedHint: String
    public let needs: Int
    public let durable: Bool
    let counting: @Sendable (BadgeEvidence) -> Int

    public init(
        id: BadgeID,
        title: String,
        motif: BadgeMotif,
        blurb: String,
        lockedHint: String,
        needs: Int,
        durable: Bool,
        counting: @escaping @Sendable (BadgeEvidence) -> Int
    ) {
        self.id = id
        self.title = title
        self.motif = motif
        self.blurb = blurb
        self.lockedHint = lockedHint
        self.needs = needs
        self.durable = durable
        self.counting = counting
    }

    public func isEarned(_ evidence: BadgeEvidence) -> Bool {
        counting(evidence) >= needs
    }

    public func progress(_ evidence: BadgeEvidence) -> BadgeProgress? {
        guard durable, needs > 1 else { return nil }
        return BadgeProgress(have: min(counting(evidence), needs), need: needs)
    }
}

extension Badge: Equatable {
    public static func == (a: Badge, b: Badge) -> Bool { a.id == b.id }
}

extension Badge: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension Badge {

    public static let all: [Badge] = [
        Badge(
            id: .stoppedOnce,
            title: "[1]+ Stopped",
            motif: .jobLine,
            blurb: "Your first break. It is what the shell prints when a job is suspended, "
                + "and the job is fine: registers, memory, all of it still there.",
            lockedHint: "Take one break.",
            needs: BadgeThreshold.firstBreak,
            durable: true
        ) { $0.breaksTaken },

        Badge(
            id: .niceN10,
            title: "ten down",
            motif: .descent,
            blurb: "Ten breaks. Ten times you took your own priority down a step, and nobody "
                + "else had to do it for you.",
            lockedHint: "Ten breaks in total. The count is in the name.",
            needs: BadgeThreshold.tenBreaks,
            durable: true
        ) { $0.breaksTaken },

        Badge(
            id: .unmasked,
            title: "nothing blocked",
            motif: .liftedGate,
            blurb: "A day where every break the app actually asked for happened. Nothing "
                + "deferred, nothing pending, nothing in the way.",
            lockedHint: "One day where every break offered was taken.",
            needs: 1,
            durable: true
        ) { $0.cleanDays },

        Badge(
            id: .provablyHalts,
            title: "always halts",
            motif: .tombstone,
            blurb: "Ten of those days. Whether an arbitrary program halts is undecidable. "
                + "You are not an arbitrary program, and this is ten days of evidence.",
            lockedHint: "Ten days where every break offered was taken.",
            needs: BadgeThreshold.haltingDays,
            durable: true
        ) { $0.cleanDays },

        Badge(
            id: .sigDFL,
            title: "no handler",
            motif: .straightThrough,
            blurb: "Five prompts accepted inside fifteen seconds. Nothing caught them, "
                + "nothing thought about them, the default just ran.",
            lockedHint: "Accept five prompts within fifteen seconds of being asked.",
            needs: BadgeThreshold.reflexAccepts,
            durable: false
        ) { $0.reflexAccepts },

        Badge(
            id: .einval,
            title: "uncatchable",
            motif: .escalation,
            blurb: "You let one prompt climb all four rungs. The top one cannot be caught, "
                + "blocked or ignored by anybody, ever, and the kernel will not even let "
                + "you try to install a handler for it.",
            lockedHint: "Let one prompt reach the fourth rung, SIGSTOP.",
            needs: 1,
            durable: false
        ) { $0.reachedSigstop ? 1 : 0 },

        Badge(
            id: .schedYield,
            title: "yielded",
            motif: .handoff,
            blurb: "Four hours of work and not one stretch past the hour. You handed the "
                + "slot back before anything had to take it from you.",
            lockedHint: "A day of at least four hours where no single stretch passed an hour.",
            needs: 1,
            durable: true
        ) { $0.yieldDays },

        Badge(
            id: .earlyReturn,
            title: "early return",
            motif: .earlyExit,
            blurb: "Five days with a break before ten in the morning. Out before the "
                + "branching got complicated.",
            lockedHint: "Take a break before 10:00 on five separate days.",
            needs: BadgeThreshold.clockDays,
            durable: false
        ) { $0.earlyDays },

        Badge(
            id: .nohup,
            title: "still running",
            motif: .detached,
            blurb: "Five nights with a break after one in the morning. The terminal is "
                + "closed and the link to it is cut: the job is the thing still running, "
                + "and you are the part that stopped.",
            lockedHint: "Take a break after 01:00 on five separate days.",
            needs: BadgeThreshold.clockDays,
            durable: false
        ) { $0.lateDays },

        Badge(
            id: .stoppedHundred,
            title: "[100]+ Stopped",
            motif: .jobLineFull,
            blurb: "A hundred breaks. The shell prints the same line it printed the first "
                + "time. Only the number in the brackets moved.",
            lockedHint: "A hundred breaks in total.",
            needs: BadgeThreshold.hundredBreaks,
            durable: true
        ) { $0.breaksTaken },
    ]

    public static func badge(_ id: BadgeID) -> Badge {
        all.first { $0.id == id } ?? all[0]
    }
}

public struct BadgeLedger: Sendable, Hashable {
    public private(set) var unlocked: [BadgeID: CalendarDay]

    private var unrecognised: [String: String]

    public init(unlocked: [BadgeID: CalendarDay] = [:]) {
        self.unlocked = unlocked
        self.unrecognised = [:]
    }

    public static let empty = BadgeLedger()

    public var count: Int { unlocked.count }
    public var isEmpty: Bool { unlocked.isEmpty }

    public func contains(_ id: BadgeID) -> Bool { unlocked[id] != nil }
    public func date(for id: BadgeID) -> CalendarDay? { unlocked[id] }

    public mutating func record(_ id: BadgeID, on day: CalendarDay) {
        if let existing = unlocked[id], existing <= day { return }
        unlocked[id] = day
    }

    public func merging(_ other: BadgeLedger) -> BadgeLedger {
        var merged = self
        for (id, day) in other.unlocked { merged.record(id, on: day) }
        merged.unrecognised.merge(other.unrecognised) { mine, _ in mine }
        return merged
    }

    public func newlyUnlocked(since earlier: BadgeLedger) -> [BadgeID] {
        Badge.all.map(\.id).filter { contains($0) && !earlier.contains($0) }
    }
}

extension BadgeLedger: Codable {
    private enum CodingKeys: String, CodingKey {
        case v
        case unlocked
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .v) ?? EventSchema.version
        guard version <= EventSchema.version else {
            throw StoreError.unsupportedSchemaVersion(version)
        }
        let raw = try c.decodeIfPresent([String: String].self, forKey: .unlocked) ?? [:]
        var out: [BadgeID: CalendarDay] = [:]
        var kept: [String: String] = [:]
        for (key, value) in raw {
            guard let id = BadgeID(rawValue: key), let day = CalendarDay.parse(value) else {
                kept[key] = value
                continue
            }
            out[id] = day
        }
        self.init(unlocked: out)
        self.unrecognised = kept
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(EventSchema.version, forKey: .v)
        var raw = unrecognised
        for (id, day) in unlocked { raw[id.rawValue] = day.description }
        try c.encode(raw, forKey: .unlocked)
    }
}
