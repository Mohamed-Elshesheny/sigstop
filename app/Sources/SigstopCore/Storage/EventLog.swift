import Foundation

// MARK: - Schema

public enum EventSchema {
    /// Bumped on any breaking change. Readers reject unknown majors rather than
    /// guessing at a format they do not understand. See docs/PRIVACY.md §4.3.
    public static let version = 1
}

// MARK: - Calendar day

/// A bare year/month/day. No time zone is attached, because the same value serves two
/// different purposes and conflating them is a bug:
///
/// * **File key**, `CalendarDay.utc(of:)`. Event-log files are named by the UTC date
///   of the event, which is what makes `t`'s first ten characters and the file name the
///   same string (docs/PRIVACY.md §4.3).
/// * **Logical day**, `CalendarDay.local(of:...)`. The daily rollup's day, in the
///   user's calendar, with the boundary at 04:00 (docs/BREAK-DECISION.md §14).
///
/// A rollup for one logical day therefore reads up to three UTC files.
public struct CalendarDay: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// A gregorian calendar pinned to UTC, used for file keys and timestamp formatting
    /// so that neither depends on the machine's time zone or locale.
    public static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    /// The UTC date of `date`. This is the event-log **file** key.
    public static func utc(of date: Date) -> CalendarDay {
        let c = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return CalendarDay(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    /// The **logical** day `date` belongs to: the local calendar day, with the boundary
    /// moved to `boundaryHour` so that 01:30 still belongs to the day before.
    public static func local(
        of date: Date,
        calendar: Calendar = .current,
        boundaryHour: Int = 4
    ) -> CalendarDay {
        let shifted = date.addingTimeInterval(-Double(boundaryHour) * 3600)
        let c = calendar.dateComponents([.year, .month, .day], from: shifted)
        return CalendarDay(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    /// `[boundaryHour on this day, boundaryHour on the next day)`, in `calendar`'s time
    /// zone. `nil` only when the components do not name a real date.
    public func interval(boundaryHour: Int = 4, calendar: Calendar = .current) -> DateInterval? {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = boundaryHour
        comps.minute = 0
        comps.second = 0
        guard
            let start = calendar.date(from: comps),
            let end = calendar.date(byAdding: .day, value: 1, to: start)
        else { return nil }
        return DateInterval(start: start, end: end)
    }

    public func adding(days: Int) -> CalendarDay {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12 // midday: immune to a DST shift in either direction
        guard
            let anchor = CalendarDay.utcCalendar.date(from: comps),
            let moved = CalendarDay.utcCalendar.date(byAdding: .day, value: days, to: anchor)
        else { return self }
        return .utc(of: moved)
    }

    /// `"2026-09-20"`. Zero-padded, which is what makes lexicographic comparison of file
    /// names equivalent to chronological comparison (docs/PRIVACY.md §4.5).
    public var description: String {
        "\(Pad.four(year))-\(Pad.two(month))-\(Pad.two(day))"
    }

    public var fileName: String { "\(description).jsonl" }

    public static func parse(_ s: some StringProtocol) -> CalendarDay? {
        let b = Array(s.utf8)
        guard b.count == 10, b[4] == 0x2D, b[7] == 0x2D else { return nil }
        guard
            let y = Digits.read(b, 0..<4),
            let m = Digits.read(b, 5..<7),
            let d = Digits.read(b, 8..<10),
            (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        return CalendarDay(year: y, month: m, day: d)
    }

    public static func < (a: Self, b: Self) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

extension CalendarDay: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        guard let parsed = CalendarDay.parse(raw) else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "not a YYYY-MM-DD day: \(raw)"
            )
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

// MARK: - Timestamps

enum Pad {
    static func two(_ n: Int) -> String { (0..<10).contains(n) ? "0\(n)" : "\(n)" }
    static func four(_ n: Int) -> String {
        guard n >= 0 else { return "\(n)" }
        if n >= 1000 { return "\(n)" }
        if n >= 100 { return "0\(n)" }
        if n >= 10 { return "00\(n)" }
        return "000\(n)"
    }
}

enum Digits {
    static func read(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        var value = 0
        for i in range {
            let c = bytes[i]
            guard c >= 0x30, c <= 0x39 else { return nil }
            value = value * 10 + Int(c - 0x30)
        }
        return value
    }
}

/// ISO-8601, UTC, **second resolution**. Sub-second precision is deliberately discarded
/// (docs/PRIVACY.md §4.3): a millisecond-accurate trace of a person's day is a finer
/// record than this app has any reason to keep.
///
/// Hand-rolled rather than `ISO8601DateFormatter` for two reasons, the formatter is a
/// non-`Sendable` class, and a fixed 20-character grammar is easier for a skeptical
/// reader to confirm than a formatter's option set.
public enum ISO8601Second {
    public static func string(from date: Date) -> String {
        let floored = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        let c = CalendarDay.utcCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: floored
        )
        let ymd = "\(Pad.four(c.year ?? 0))-\(Pad.two(c.month ?? 0))-\(Pad.two(c.day ?? 0))"
        let hms = "\(Pad.two(c.hour ?? 0)):\(Pad.two(c.minute ?? 0)):\(Pad.two(c.second ?? 0))"
        return "\(ymd)T\(hms)Z"
    }

    public static func date(from s: some StringProtocol) -> Date? {
        let b = Array(s.utf8)
        guard b.count == 20,
              b[4] == 0x2D, b[7] == 0x2D,   // -
              b[10] == 0x54,                // T
              b[13] == 0x3A, b[16] == 0x3A, // :
              b[19] == 0x5A                 // Z
        else { return nil }
        guard
            let year = Digits.read(b, 0..<4),
            let month = Digits.read(b, 5..<7),
            let day = Digits.read(b, 8..<10),
            let hour = Digits.read(b, 11..<13),
            let minute = Digits.read(b, 14..<16),
            let second = Digits.read(b, 17..<19)
        else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        return CalendarDay.utcCalendar.date(from: comps)
    }
}

// MARK: - Event vocabulary

/// The complete event vocabulary.
///
/// There is no `other`, no free-text `note`, and no field anywhere in `LoggedEvent`
/// that can hold a window title, a URL path, a file path, document text, or a
/// keystroke. That is enforced by the type rather than by review convention: to
/// persist a title you would have to add a field here, which is a diff a reviewer
/// cannot miss. See docs/PRIVACY.md §1.2 rows 12–14 and CLAUDE.md §4.4.
///
/// Raw values are the short strings written to disk.
public enum EventKind: String, Sendable, Codable, CaseIterable, Hashable {
    case start
    case stop
    case focus
    case idleBegin = "idle_begin"
    case idleEnd = "idle_end"
    case lock
    case unlock
    /// The machine suspended. `display_sleep` is a different fact and has its own name:
    /// the screen going dark while the process keeps running is not the machine stopping,
    /// and collapsing the two made a log that appeared to record the same event twice.
    case sleep
    case wake
    case displaySleep = "display_sleep"
    case displayWake = "display_wake"
    case sessionOut = "session_out"
    case sessionIn = "session_in"
    /// A break **opportunity** opened: continuous active work reached the target, i.e.
    /// the engine entered `breakDue`, including entries immediately suppressed by
    /// quiet hours or a hard block (docs/BREAK-DECISION.md §14.1).
    ///
    /// Compliance is undefined without it: a prompt that was never delivered still
    /// opened an opportunity, and the difference between "missed" and "never asked" is
    /// the whole honesty of the metric.
    ///
    /// This shipped for a while without being listed in docs/PRIVACY.md §4.3, which
    /// claims to be the complete vocabulary. It is listed there now, along with
    /// `break_begin` and `break_end` which had drifted the same way.
    case breakOpen = "break_open"
    case breakPrompt = "break_prompt"
    case breakResponse = "break_response"
    /// A candidate break started. `origin` says how it started.
    case breakBegin = "break_begin"
    /// It ended. `dur_s` is the measured duration; the *reader*, not the writer, decides
    /// whether that was long enough to qualify.
    case breakEnd = "break_end"
    /// A break opportunity ended, with the `CycleOutcome` that ended it.
    ///
    /// Without this a cycle could be closed as expired, quietSuppressed, dailyCapReached,
    /// ignoredExhausted, skipped or honored and leave no trace at all. The day that
    /// produced the 20:06:51Z incident holds seventeen `break_open` lines and twelve
    /// `break_response` lines: five opportunities simply stop existing mid-file, and the
    /// difference between "the user said no" and "the app gave up" was unrecoverable.
    case cycleClose = "cycle_close"
    /// Why the app is or is not allowed to speak right now, written when the answer
    /// changes rather than when it is computed.
    ///
    /// The verdict is recomputed on every five second tick. A fourteen minute hold
    /// produces 168 identical answers and used to keep none of them, so "why did you say
    /// nothing at 20:12" had no answer after the fact. CLAUDE.md §4.1 requires the app to
    /// always be able to say why it thinks what it thinks; this is that promise for the
    /// one question the whole product turns on.
    case gate
}

/// What the developer did with a delivered prompt.
public enum BreakResponseAction: String, Sendable, Codable, CaseIterable, Hashable {
    case taken
    case skipped
    case snoozed
    /// The prompt timed out with no interaction (docs/BREAK-DECISION.md §10).
    case ignored
}

// MARK: - The record

/// One line of `events/YYYY-MM-DD.jsonl`.
///
/// On-disk field names are the short ones from docs/PRIVACY.md §4.3 (`v`, `t`, `e`,
/// `app`, …), and optional fields are omitted entirely when `nil`, so a line stays
/// short enough to read at a glance. That is the actual design goal: `cat` is meant to
/// be a complete audit tool.
public struct LoggedEvent: Sendable, Hashable, Codable {
    public var v: Int
    /// UTC, second resolution.
    public var at: Date
    public var kind: EventKind

    /// Bundle identifier, e.g. `com.apple.dt.Xcode`. Never a path, never a title.
    public var app: String?
    /// Coarse category from `categories.json`: `code`, `browse`, `meet`, `write`, `other`.
    public var category: String?
    /// The inferred `Activity`. Derived, never raw input.
    public var activity: Activity?
    /// The five-value window-title classification. **Never the title itself.**
    public var titleSignal: String?
    /// Length of the idle period that just ended. Kept for auditability only, the
    /// rollup diffs real timestamps instead of trusting this (CLAUDE.md §3.4).
    public var idleSeconds: Int?
    /// The signal a prompt was named after, on `break_prompt`. Typed, because the
    /// paragraph above promises no field here can hold free text and a `String?` was
    /// quietly the one that could.
    public var reason: SignalName?
    /// How a break opportunity ended. Typed, so the field can hold one of six values and
    /// nothing else.
    public var outcome: CycleOutcome?
    /// Why a prompt was or was not allowed. Typed for the same reason: a closed
    /// vocabulary of twenty-four, never a sentence, and never anything derived from a
    /// window title (CLAUDE.md §4.4).
    public var gate: GateReason?
    public var action: BreakResponseAction?
    public var snoozeSeconds: Int?
    /// Present on `break_prompt` when the prompt was **not** delivered: why it was
    /// withheld (`meeting`, `quiet_hours`, `rate_limit`, …). Its presence is what makes
    /// an opportunity excludable rather than missed.
    public var deferred: GateReason?
    public var origin: BreakOrigin?
    public var durationSeconds: Int?
    /// The `CycleID` this event belongs to, so counters scope to a cycle.
    public var cycle: Int?

    public init(
        v: Int = EventSchema.version,
        at: Date,
        kind: EventKind,
        app: String? = nil,
        category: String? = nil,
        activity: Activity? = nil,
        titleSignal: String? = nil,
        idleSeconds: Int? = nil,
        reason: SignalName? = nil,
        outcome: CycleOutcome? = nil,
        gate: GateReason? = nil,
        action: BreakResponseAction? = nil,
        snoozeSeconds: Int? = nil,
        deferred: GateReason? = nil,
        origin: BreakOrigin? = nil,
        durationSeconds: Int? = nil,
        cycle: Int? = nil
    ) {
        self.v = v
        self.at = at
        self.kind = kind
        self.app = app
        self.category = category
        self.activity = activity
        self.titleSignal = titleSignal
        self.idleSeconds = idleSeconds
        self.reason = reason
        self.outcome = outcome
        self.gate = gate
        self.action = action
        self.snoozeSeconds = snoozeSeconds
        self.deferred = deferred
        self.origin = origin
        self.durationSeconds = durationSeconds
        self.cycle = cycle
    }

    /// The UTC day whose file this line belongs in.
    public var fileDay: CalendarDay { .utc(of: at) }

    /// True for a `break_prompt` that actually reached the developer.
    public var wasDelivered: Bool { kind == .breakPrompt && deferred == nil }

    private enum CodingKeys: String, CodingKey {
        case v
        case at = "t"
        case kind = "e"
        case app
        case category = "cat"
        case activity = "act"
        case titleSignal = "sig"
        case idleSeconds = "idle_s"
        case reason
        case outcome
        case gate
        case action
        case snoozeSeconds = "snooze_s"
        case deferred
        case origin
        case durationSeconds = "dur_s"
        case cycle
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? EventSchema.version
        guard v <= EventSchema.version else { throw StoreError.unsupportedSchemaVersion(v) }
        let stamp = try c.decode(String.self, forKey: .at)
        guard let parsed = ISO8601Second.date(from: stamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .at, in: c, debugDescription: "not an ISO-8601 UTC second: \(stamp)"
            )
        }
        at = parsed
        kind = try c.decode(EventKind.self, forKey: .kind)
        app = try c.decodeIfPresent(String.self, forKey: .app)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        activity = try c.decodeIfPresent(Activity.self, forKey: .activity)
        titleSignal = try c.decodeIfPresent(String.self, forKey: .titleSignal)
        idleSeconds = try c.decodeIfPresent(Int.self, forKey: .idleSeconds)
        reason = try c.decodeIfPresent(SignalName.self, forKey: .reason)
        outcome = try c.decodeIfPresent(CycleOutcome.self, forKey: .outcome)
        gate = try c.decodeIfPresent(GateReason.self, forKey: .gate)
        action = try c.decodeIfPresent(BreakResponseAction.self, forKey: .action)
        snoozeSeconds = try c.decodeIfPresent(Int.self, forKey: .snoozeSeconds)
        deferred = try c.decodeIfPresent(GateReason.self, forKey: .deferred)
        origin = try c.decodeIfPresent(BreakOrigin.self, forKey: .origin)
        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds)
        cycle = try c.decodeIfPresent(Int.self, forKey: .cycle)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(ISO8601Second.string(from: at), forKey: .at)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(app, forKey: .app)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(activity, forKey: .activity)
        try c.encodeIfPresent(titleSignal, forKey: .titleSignal)
        try c.encodeIfPresent(idleSeconds, forKey: .idleSeconds)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encodeIfPresent(outcome, forKey: .outcome)
        try c.encodeIfPresent(gate, forKey: .gate)
        try c.encodeIfPresent(action, forKey: .action)
        try c.encodeIfPresent(snoozeSeconds, forKey: .snoozeSeconds)
        try c.encodeIfPresent(deferred, forKey: .deferred)
        try c.encodeIfPresent(origin, forKey: .origin)
        try c.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try c.encodeIfPresent(cycle, forKey: .cycle)
    }
}

// MARK: - Convenience constructors

extension LoggedEvent {
    public static func start(at: Date) -> LoggedEvent { LoggedEvent(at: at, kind: .start) }
    public static func stop(at: Date) -> LoggedEvent { LoggedEvent(at: at, kind: .stop) }

    public static func focus(
        at: Date,
        app: String?,
        category: String? = nil,
        activity: Activity? = nil,
        titleSignal: String? = nil
    ) -> LoggedEvent {
        LoggedEvent(
            at: at, kind: .focus, app: app, category: category,
            activity: activity, titleSignal: titleSignal
        )
    }

    public static func idleBegin(at: Date) -> LoggedEvent { LoggedEvent(at: at, kind: .idleBegin) }

    public static func idleEnd(at: Date, idleSeconds: Int? = nil) -> LoggedEvent {
        LoggedEvent(at: at, kind: .idleEnd, idleSeconds: idleSeconds)
    }

    public static func system(at: Date, _ kind: EventKind) -> LoggedEvent {
        LoggedEvent(at: at, kind: kind)
    }

    public static func breakOpen(at: Date, cycle: CycleID) -> LoggedEvent {
        LoggedEvent(at: at, kind: .breakOpen, cycle: cycle.rawValue)
    }

    public static func breakPrompt(
        at: Date, cycle: CycleID, reason: SignalName? = nil, deferred: GateReason? = nil
    ) -> LoggedEvent {
        LoggedEvent(
            at: at, kind: .breakPrompt, reason: reason,
            deferred: deferred, cycle: cycle.rawValue
        )
    }

    public static func breakResponse(
        at: Date, cycle: CycleID, action: BreakResponseAction, snoozeSeconds: Int? = nil
    ) -> LoggedEvent {
        LoggedEvent(
            at: at, kind: .breakResponse, action: action,
            snoozeSeconds: snoozeSeconds, cycle: cycle.rawValue
        )
    }

    public static func breakBegin(
        at: Date, origin: BreakOrigin, cycle: CycleID? = nil
    ) -> LoggedEvent {
        LoggedEvent(at: at, kind: .breakBegin, origin: origin, cycle: cycle?.rawValue)
    }

    public static func breakEnd(
        at: Date, origin: BreakOrigin, durationSeconds: Int, cycle: CycleID? = nil
    ) -> LoggedEvent {
        LoggedEvent(
            at: at, kind: .breakEnd, origin: origin,
            durationSeconds: durationSeconds, cycle: cycle?.rawValue
        )
    }

    public static func cycleClose(at: Date, cycle: CycleID, outcome: CycleOutcome) -> LoggedEvent {
        LoggedEvent(at: at, kind: .cycleClose, outcome: outcome, cycle: cycle.rawValue)
    }

    public static func gate(at: Date, reason: GateReason, cycle: CycleID? = nil) -> LoggedEvent {
        LoggedEvent(at: at, kind: .gate, gate: reason, cycle: cycle?.rawValue)
    }
}

// MARK: - Codec

/// JSONL in, JSONL out. One event per line, plain field names, nothing encoded.
///
/// The decoder is forgiving in exactly one direction: a line it cannot parse is
/// **skipped and counted**, never guessed at and never fatal. That is what turns a
/// crash mid-append into a one-line loss instead of a corrupt history
/// (docs/PRIVACY.md §4.3).
public enum EventLogCodec {
    /// Lines beginning with this are human-written headers in an export, not data.
    /// Skipping them is what keeps an export re-readable by this same decoder.
    public static let commentPrefix = "#"

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func encode(_ event: LoggedEvent) throws -> String {
        String(decoding: try makeEncoder().encode(event), as: UTF8.self)
    }

    public static func encodeLines(_ events: [LoggedEvent]) throws -> String {
        guard !events.isEmpty else { return "" }
        let encoder = makeEncoder()
        var out = ""
        for event in events {
            out += String(decoding: try encoder.encode(event), as: UTF8.self)
            out += "\n"
        }
        return out
    }

    public static func decode(_ line: some StringProtocol) -> LoggedEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(commentPrefix) else { return nil }
        return try? JSONDecoder().decode(LoggedEvent.self, from: Data(trimmed.utf8))
    }

    public struct DecodeResult: Sendable, Hashable {
        public let events: [LoggedEvent]
        /// Lines that were neither blank, a comment, nor a valid event. A torn tail from
        /// a crash lands here.
        public let malformedLines: Int

        public init(events: [LoggedEvent], malformedLines: Int) {
            self.events = events
            self.malformedLines = malformedLines
        }
    }

    public static func decodeLines(_ text: some StringProtocol) -> DecodeResult {
        var events: [LoggedEvent] = []
        var malformed = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(commentPrefix) { continue }
            if let event = decode(trimmed) {
                events.append(event)
            } else {
                malformed += 1
            }
        }
        return DecodeResult(events: events, malformedLines: malformed)
    }
}
