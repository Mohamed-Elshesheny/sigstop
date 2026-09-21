import Foundation

// MARK: - The rule these ten obey

/// Ten marks, and the one rule that decided every one of them.
///
/// **No badge may reward working longer.** A mark for "ten hours of active work" would
/// have the app fighting itself: the product exists to interrupt long stretches, so
/// paying someone for a long stretch inverts it. Every badge here rewards either taking
/// the break or not needing one, and `yielded` explicitly rewards *not* overrunning.
///
/// **Second rule: nothing new is observed.** Every condition below is arithmetic over
/// the `DailySummary` values and the event vocabulary that already existed. No field was
/// added to `LoggedEvent`, no signal was added to the sensors, and `docs/PRIVACY.md`'s
/// inventory grew by exactly one derived artefact, the ledger of which of these ten
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

/// The object each badge is drawn as, fixed per badge and part of its identity.
///
/// This used to be a geometry: circle, triangle, square, up to octagon, with the side
/// count rising with difficulty. It was replaced because a set of ten things that differ
/// only by how many sides they have gives nobody a reason to want the next one, which is
/// the only job a badge has. Each case below names a small, specific object from the
/// world its badge is about, so the ten read as ten different things at a glance instead
/// of as one thing counted seven ways.
///
/// `SigstopCore` only names them. The App layer draws them, and the pair that bookends
/// the set, `jobLine` and `jobLineFull`, is deliberately the same object twice.
public enum BadgeMotif: String, Sendable, Hashable, Codable {
    /// A shell job line: brackets with one suspended job standing between them.
    case jobLine = "job-line"
    /// A staircase going down. Your own priority, lowered a step at a time.
    case descent
    /// A barrier arm swung clear of the road. Nothing is in the way of the signal.
    case liftedGate = "lifted-gate"
    /// A proof narrowing to its last line, closed by a tombstone.
    case tombstone
    /// An arrow through the gap where a handler would have sat, entirely unbent.
    case straightThrough = "straight-through"
    /// The four-rung escalation ladder from `CLAUDE.md` §0, with the top rung reached.
    case escalation
    /// A run queue with its front slot vacated, the yielder arcing round to the back.
    case handoff
    /// A function whose last statements are never reached, and the arrow that left.
    case earlyExit = "early-exit"
    /// A process still running under a terminal that is no longer there.
    case detached
    /// The same brackets as `jobLine`, with every slot in them filled.
    case jobLineFull = "job-line-full"
}

// MARK: - Thresholds

/// The numbers in the ten conditions, named once so the copy, the predicates and the
/// tests cannot drift apart.
public enum BadgeThreshold {
    /// `[1]+ Stopped`.
    public static let firstBreak = 1
    /// `ten down`. The count is in the name; if this constant changes the name is wrong.
    public static let tenBreaks = 10
    /// `[100]+ Stopped`.
    public static let hundredBreaks = 100
    /// `always halts`, days where every break offered was taken.
    public static let haltingDays = 10
    /// `no handler`, how many prompts must be accepted inside `reflexWindow`.
    public static let reflexAccepts = 5
    /// The default disposition runs immediately. Fifteen seconds is "you did not think
    /// about it", which is the whole joke.
    public static let reflexWindow: TimeInterval = 15
    /// `yielded`, a real working day, so the badge cannot be won by doing nothing.
    public static let yieldMinimumWork: TimeInterval = 4 * 3600
    /// …in which no single continuous stretch passed this. Yielding before you are
    /// preempted is the entire point of the mark.
    public static let yieldStretchCeiling: TimeInterval = 3600
    /// `early return` / `still running`, how many separate days each needs.
    public static let clockDays = 5
    /// Local hour before which a break counts as an `early return`.
    public static let earlyHour = 10
    /// Local hour after which a break counts as a late one. The window closes at the
    /// logical day boundary, which is 04:00, so this is 01:00 to 04:00, the hours a job
    /// outlives the terminal that started it.
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

// MARK: - How far along

/// How far a locked badge is from unlocking.
///
/// Only some badges have one, and the rule is the same distinction `BadgeDay` already
/// draws. Six of the ten are arithmetic over stored `DailySummary` values, which survive
/// the seven-day prune, so their counts only ever rise. The other four need the raw event
/// log, so what the app can still *see* shrinks as the log ages: showing "4 of 5" one
/// week and "1 of 5" the next would be a number going backwards, and the badge set exists
/// partly to have none of those. Those four say what they take and nothing more.
public struct BadgeProgress: Sendable, Hashable {
    /// Never above `need`, so a finished bar cannot read "12 of 10".
    public let have: Int
    public let need: Int

    public init(have: Int, need: Int) {
        self.have = have
        self.need = need
    }

    public var fraction: Double { need > 0 ? Double(have) / Double(need) : 0 }
}

// MARK: - The badge

/// One mark: what it is called, what it looks like, what it says, and the only question
/// that decides whether it is earned.
///
/// The predicate is a stored property rather than a `switch` somewhere else so that a
/// reader can check the claim in the copy against the arithmetic without leaving the
/// line. `Equatable` and `Hashable` are by `id` alone, two values with the same id are
/// the same badge whatever the copy says this release.
public struct Badge: Sendable, Identifiable {
    public let id: BadgeID
    /// The name, exactly as the naming panel fixed it. Not renamed, not title-cased.
    public let title: String
    /// What it is drawn as. Part of the badge's identity, not a rendering choice, which
    /// is why it lives here beside the name rather than in a switch in the view layer.
    public let motif: BadgeMotif
    /// What it means, once it is yours.
    public let blurb: String
    /// What it takes, said plainly. Shown while it is locked, so it must read as a
    /// description of a thing that has not happened yet, never as a failure.
    public let lockedHint: String
    /// How many it takes.
    public let needs: Int
    /// Whether `counting` reads a number that survives the seven-day prune. See
    /// `BadgeProgress`.
    public let durable: Bool
    /// The number this badge counts. The condition is not written separately: it is
    /// `counting >= needs`, so a row cannot show "9 of 10" beside a badge that has
    /// already unlocked, and changing a threshold cannot leave a counter behind.
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

    /// The whole condition.
    public func isEarned(_ evidence: BadgeEvidence) -> Bool {
        counting(evidence) >= needs
    }

    /// What to draw under a locked row, or nothing when a count would be noise or a lie:
    /// `needs == 1` has nothing to report between zero and done, and a badge whose
    /// evidence is pruned would report a number that goes down.
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

// MARK: - The catalogue

extension Badge {

    /// The ten, in the order they are shown. The order is the order they tend to arrive
    /// in, and it puts the two bracketed job lines at either end of the list on purpose.
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

// MARK: - The ledger

/// Which of the ten have unlocked, and on what day.
///
/// **Once earned, it stays earned, including across a prune.** Raw events are kept for
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
    /// heard of and then rewrite the file without it, the same permanent loss the type
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
