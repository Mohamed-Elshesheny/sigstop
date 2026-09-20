import Foundation

// MARK: - The rule these ten obey

/// Ten marks, and the one rule that decided every one of them.
///
/// **No badge may reward working longer.** A mark for "ten hours of active work" would
/// have the app fighting itself: the product exists to interrupt long stretches, so
/// paying someone for a long stretch inverts it. Every badge here rewards either taking
/// the break or not needing one, and `sched_yield` explicitly rewards *not* overrunning.
///
/// **Second rule: nothing new is observed.** Every condition below is arithmetic over
/// the `DailySummary` values and the event vocabulary that already existed. No field was
/// added to `LoggedEvent`, no signal was added to the sensors, and `docs/PRIVACY.md`'s
/// inventory grew by exactly one derived artefact — the ledger of which of these ten
/// have unlocked. A badge is not a reason to watch someone more closely.
///
/// **There is no streak.** Nothing here expires, nothing is lost by missing a day, and
/// none of it can go down. That is the whole difference between this and the category of
/// app that keeps a number hostage.
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

/// The geometry, fixed per badge by the naming panel and not a decoration.
///
/// Side count rises roughly with difficulty — circle, triangle, square, diamond,
/// pentagon, hexagon, octagon — so the pane reads as a progression without anyone
/// having to explain it. The App layer draws these; `SigstopCore` only names them,
/// because a shape is part of a badge's identity and identity belongs in the domain.
public enum BadgeShape: String, Sendable, Hashable, Codable {
    case circle
    case triangle
    case square
    case diamond
    case pentagon
    case hexagon
    case octagon

    /// Sides of the regular polygon, or `nil` for the circle.
    public var sides: Int? {
        switch self {
        case .circle: return nil
        case .triangle: return 3
        case .square, .diamond: return 4
        case .pentagon: return 5
        case .hexagon: return 6
        case .octagon: return 8
        }
    }
}

// MARK: - Thresholds

/// The numbers in the ten conditions, named once so the copy, the predicates and the
/// tests cannot drift apart.
public enum BadgeThreshold {
    /// `[1]+ Stopped`.
    public static let firstBreak = 1
    /// `nice -n 10`. The count is in the name; if this constant changes the name is wrong.
    public static let tenBreaks = 10
    /// `[100]+ Stopped`.
    public static let hundredBreaks = 100
    /// `provably halts` — days where every break offered was taken.
    public static let haltingDays = 10
    /// `SIG_DFL` — how many prompts must be accepted inside `reflexWindow`.
    public static let reflexAccepts = 5
    /// The default disposition runs immediately. Fifteen seconds is "you did not think
    /// about it", which is the whole joke.
    public static let reflexWindow: TimeInterval = 15
    /// `sched_yield` — a real working day, so the badge cannot be won by doing nothing.
    public static let yieldMinimumWork: TimeInterval = 4 * 3600
    /// …in which no single continuous stretch passed this. Yielding before you are
    /// preempted is the entire point of the mark.
    public static let yieldStretchCeiling: TimeInterval = 3600
    /// `early return` / `nohup` — how many separate days each needs.
    public static let clockDays = 5
    /// Local hour before which a break counts as an `early return`.
    public static let earlyHour = 10
    /// Local hour after which a break counts as `nohup`. The window closes at the
    /// logical day boundary, which is 04:00 — so this is 01:00 to 04:00, the hours the
    /// command is named for.
    public static let lateHour = 1
}

// MARK: - Evidence

/// Everything the ten predicates are allowed to look at, accumulated across days.
///
/// Deliberately a flat tally rather than the day list itself: a predicate that could
/// walk the history could be written to reward a long day, and this type makes that
/// impossible to express. Nothing in here can decrease.
public struct BadgeEvidence: Sendable, Hashable {
    /// Qualifying breaks across every day seen: accepted, idle-inferred, user-initiated.
    public var breaksTaken: Int
    /// Days where every break the app actually asked for was taken, and it asked at
    /// least once.
    public var cleanDays: Int
    /// Prompts accepted within `BadgeThreshold.reflexWindow` of being delivered.
    public var reflexAccepts: Int
    /// A prompt was let all the way to the fourth rung, `SIGSTOP`.
    public var reachedSigstop: Bool
    /// Days of real work where nothing ran past the stretch ceiling.
    public var yieldDays: Int
    /// Separate days with a break before `BadgeThreshold.earlyHour`.
    public var earlyDays: Int
    /// Separate days with a break after `BadgeThreshold.lateHour`.
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

// MARK: - The badge

/// One mark: what it is called, what it looks like, what it says, and the only question
/// that decides whether it is earned.
///
/// The predicate is a stored property rather than a `switch` somewhere else so that a
/// reader can check the claim in the copy against the arithmetic without leaving the
/// line. `Equatable` and `Hashable` are by `id` alone — two values with the same id are
/// the same badge whatever the copy says this release.
public struct Badge: Sendable, Identifiable {
    public let id: BadgeID
    /// The name, exactly as the naming panel fixed it. Not renamed, not title-cased.
    public let title: String
    public let shape: BadgeShape
    /// The character knocked out of the filled shape. One or two, because a glyph that
    /// needs three is a glyph nobody can read at 28 points.
    public let glyph: String
    /// What it means, once it is yours.
    public let blurb: String
    /// What it takes, said plainly. Shown while it is locked, so it must read as a
    /// description of a thing that has not happened yet — never as a failure.
    public let lockedHint: String
    /// The whole condition.
    public let isEarned: @Sendable (BadgeEvidence) -> Bool

    public init(
        id: BadgeID,
        title: String,
        shape: BadgeShape,
        glyph: String,
        blurb: String,
        lockedHint: String,
        isEarned: @escaping @Sendable (BadgeEvidence) -> Bool
    ) {
        self.id = id
        self.title = title
        self.shape = shape
        self.glyph = glyph
        self.blurb = blurb
        self.lockedHint = lockedHint
        self.isEarned = isEarned
    }
}

extension Badge: Equatable {
    public static func == (a: Badge, b: Badge) -> Bool { a.id == b.id }
}

extension Badge: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - The catalogue

extension Badge {

    /// The ten, in the order they are shown. Sides rise with difficulty, so the order is
    /// also the shape progression.
    public static let all: [Badge] = [
        Badge(
            id: .stoppedOnce,
            title: "[1]+ Stopped",
            shape: .circle,
            glyph: "1",
            blurb: "Your first break. It is what the shell prints when a job is suspended, "
                + "and the job is fine: registers, memory, all of it still there.",
            lockedHint: "Take one break."
        ) { $0.breaksTaken >= BadgeThreshold.firstBreak },

        Badge(
            id: .niceN10,
            title: "nice -n 10",
            shape: .triangle,
            glyph: "n",
            blurb: "Ten breaks. You have lowered your own priority ten times without anyone "
                + "having to do it for you.",
            lockedHint: "Ten breaks in total. The count is in the name."
        ) { $0.breaksTaken >= BadgeThreshold.tenBreaks },

        Badge(
            id: .unmasked,
            title: "unmasked",
            shape: .square,
            glyph: "u",
            blurb: "A day where every break the app actually asked for happened. Nothing "
                + "blocked, nothing pending, no handler in the way.",
            lockedHint: "One day where every break offered was taken."
        ) { $0.cleanDays >= 1 },

        Badge(
            id: .provablyHalts,
            title: "provably halts",
            shape: .hexagon,
            glyph: "h",
            blurb: "Ten of those days. Whether an arbitrary program halts is undecidable. "
                + "You are not an arbitrary program, and here is the evidence.",
            lockedHint: "Ten days where every break offered was taken."
        ) { $0.cleanDays >= BadgeThreshold.haltingDays },

        Badge(
            id: .sigDFL,
            title: "SIG_DFL",
            shape: .pentagon,
            glyph: "D",
            blurb: "Five prompts accepted inside fifteen seconds. No handler installed, "
                + "no deliberation, the signal just runs.",
            lockedHint: "Accept five prompts within fifteen seconds of being asked."
        ) { $0.reflexAccepts >= BadgeThreshold.reflexAccepts },

        Badge(
            id: .einval,
            title: "EINVAL",
            shape: .diamond,
            glyph: "E",
            blurb: "You let one prompt climb all four rungs to SIGSTOP. sigaction() answers "
                + "EINVAL if you try to install a handler for that one. The refusal is "
                + "documented; the attempt was always the funny part.",
            lockedHint: "Let one prompt reach the fourth rung, SIGSTOP."
        ) { $0.reachedSigstop },

        Badge(
            id: .schedYield,
            title: "sched_yield",
            shape: .hexagon,
            glyph: "y",
            blurb: "Four hours of work and not one stretch past the hour. You gave up the "
                + "CPU before anything had to take it from you.",
            lockedHint: "A day of at least four hours where no single stretch passed an hour."
        ) {
            $0.yieldDays >= 1
        },

        Badge(
            id: .earlyReturn,
            title: "early return",
            shape: .triangle,
            glyph: "r",
            blurb: "Five days with a break before ten in the morning. Out before the "
                + "branching got complicated.",
            lockedHint: "Take a break before 10:00 on five separate days."
        ) { $0.earlyDays >= BadgeThreshold.clockDays },

        Badge(
            id: .nohup,
            title: "nohup",
            shape: .pentagon,
            glyph: "&",
            blurb: "Five nights with a break after one in the morning. Whatever you are "
                + "running, it has stopped caring whether the terminal is still there.",
            lockedHint: "Take a break after 01:00 on five separate days."
        ) { $0.lateDays >= BadgeThreshold.clockDays },

        Badge(
            id: .stoppedHundred,
            title: "[100]+ Stopped",
            shape: .octagon,
            glyph: "00",
            blurb: "A hundred breaks. The shell prints the same line it printed the first "
                + "time. Only the number in the brackets moved.",
            lockedHint: "A hundred breaks in total."
        ) { $0.breaksTaken >= BadgeThreshold.hundredBreaks },
    ]

    public static func badge(_ id: BadgeID) -> Badge {
        all.first { $0.id == id } ?? all[0]
    }
}

// MARK: - The ledger

/// Which of the ten have unlocked, and on what day.
///
/// **Once earned, it stays earned — including across a prune.** Raw events are kept for
/// seven days by default (`docs/PRIVACY.md` §4.5), so the tallies the evaluator can
/// recompute shrink as the log ages. If the unlocked set were recomputed from scratch
/// every time, a badge would silently disappear the week after it was won, which is the
/// one behaviour a record of something you did must never have. So the ledger is the
/// durable thing and the evaluator only ever *adds* to it: `merging` is a union that
/// keeps the earlier of two dates and drops nothing.
///
/// The honest consequence, stated rather than hidden: a badge can unlock *later* than
/// the day it was truly earned if the evidence for it was pruned before the app next
/// looked. It can never unlock earlier, and it can never be taken back.
public struct BadgeLedger: Sendable, Hashable {
    public private(set) var unlocked: [BadgeID: CalendarDay]

    /// Entries this build does not recognise, kept verbatim and written back unchanged.
    ///
    /// An older build opening a newer file would otherwise drop a badge it has never
    /// heard of and then rewrite the file without it — the same permanent loss the type
    /// exists to prevent, just arriving by a different route.
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

    /// Records `id` as unlocked on `day`, unless it already carries an earlier date.
    public mutating func record(_ id: BadgeID, on day: CalendarDay) {
        if let existing = unlocked[id], existing <= day { return }
        unlocked[id] = day
    }

    /// Union, keeping the earlier date. Never removes an entry from either side.
    public func merging(_ other: BadgeLedger) -> BadgeLedger {
        var merged = self
        for (id, day) in other.unlocked { merged.record(id, on: day) }
        merged.unrecognised.merge(other.unrecognised) { mine, _ in mine }
        return merged
    }

    /// The ids unlocked here that `earlier` did not have, in catalogue order.
    public func newlyUnlocked(since earlier: BadgeLedger) -> [BadgeID] {
        Badge.all.map(\.id).filter { contains($0) && !earlier.contains($0) }
    }
}

/// `badges.json`, in the same plain shape as everything else in the storage root: a
/// schema version and a flat map of badge id to the day it unlocked. Someone who opens
/// the file sees exactly what was recorded and nothing else.
///
/// ```json
/// {
///   "unlocked" : { "stopped-1" : "2026-09-20" },
///   "v" : 1
/// }
/// ```
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
