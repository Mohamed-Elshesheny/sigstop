import Foundation

public enum EventSchema {
    public static let version = 1
}

public struct CalendarDay: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    public static func utc(of date: Date) -> CalendarDay {
        let c = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return CalendarDay(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    public static func local(
        of date: Date,
        calendar: Calendar = .current,
        boundaryHour: Int = 4
    ) -> CalendarDay {
        let shifted = date.addingTimeInterval(-Double(boundaryHour) * 3600)
        let c = keyed(like: calendar).dateComponents([.year, .month, .day], from: shifted)
        return CalendarDay(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    static func keyed(like calendar: Calendar) -> Calendar {
        guard calendar.identifier != .gregorian else { return calendar }
        var c = Calendar(identifier: .gregorian)
        c.timeZone = calendar.timeZone
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    public func interval(boundaryHour: Int = 4, calendar: Calendar = .current) -> DateInterval? {
        let calendar = CalendarDay.keyed(like: calendar)
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
        comps.hour = 12
        guard
            let anchor = CalendarDay.utcCalendar.date(from: comps),
            let moved = CalendarDay.utcCalendar.date(byAdding: .day, value: days, to: anchor)
        else { return self }
        return .utc(of: moved)
    }

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
              b[4] == 0x2D, b[7] == 0x2D,
              b[10] == 0x54,
              b[13] == 0x3A, b[16] == 0x3A,
              b[19] == 0x5A
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

public enum EventKind: String, Sendable, Codable, CaseIterable, Hashable {
    case start
    case stop
    case focus
    case idleBegin = "idle_begin"
    case idleEnd = "idle_end"
    case lock
    case unlock
    case sleep
    case wake
    case displaySleep = "display_sleep"
    case displayWake = "display_wake"
    case sessionOut = "session_out"
    case sessionIn = "session_in"
    case breakOpen = "break_open"
    case breakPrompt = "break_prompt"
    case breakResponse = "break_response"
    case breakBegin = "break_begin"
    case breakEnd = "break_end"
    case cycleClose = "cycle_close"
    case gate
}

public enum BreakResponseAction: String, Sendable, Codable, CaseIterable, Hashable {
    case taken
    case skipped
    case snoozed
    case ignored
}

public struct LoggedEvent: Sendable, Hashable, Codable {
    public var v: Int
    public var at: Date
    public var kind: EventKind

    public var app: String?
    public var category: String?
    public var activity: Activity?
    public var titleSignal: String?
    public var idleSeconds: Int?
    public var reason: SignalName?
    public var outcome: CycleOutcome?
    public var gate: GateReason?
    public var action: BreakResponseAction?
    public var snoozeSeconds: Int?
    public var deferred: GateReason?
    public var origin: BreakOrigin?
    public var durationSeconds: Int?
    public var thresholdSeconds: Int?
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
        thresholdSeconds: Int? = nil,
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
        self.thresholdSeconds = thresholdSeconds
        self.cycle = cycle
    }

    public var fileDay: CalendarDay { .utc(of: at) }

    public var wasDelivered: Bool { kind == .breakPrompt && deferred == nil }

    enum CodingKeys: String, CodingKey, CaseIterable {
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
        case thresholdSeconds = "plan_s"
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
        thresholdSeconds = try c.decodeIfPresent(Int.self, forKey: .thresholdSeconds)
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
        try c.encodeIfPresent(thresholdSeconds, forKey: .thresholdSeconds)
        try c.encodeIfPresent(cycle, forKey: .cycle)
    }
}

extension LoggedEvent.CodingKeys {
    var gloss: String {
        switch self {
        case .v:               return "schema"
        case .at:              return "UTC second"
        case .kind:            return "event"
        case .app:             return "bundle id"
        case .category:        return "category"
        case .activity:        return "inferred activity"
        case .titleSignal:     return "window-title CLASS (never the title)"
        case .idleSeconds:     return "length of the idle period that just ended"
        case .reason:          return "the signal a prompt is named after"
        case .outcome:         return "how a break opportunity ended"
        case .gate:            return "why a prompt was or was not allowed"
        case .action:          return "what was done with a prompt"
        case .snoozeSeconds:   return "snooze length in seconds"
        case .deferred:        return "why a prompt was withheld"
        case .origin:          return "how a break started"
        case .durationSeconds: return "break length in seconds"
        case .thresholdSeconds: return "the length it had to reach to count"
        case .cycle:           return "which break opportunity this line belongs to"
        }
    }
}

extension LoggedEvent {
    static func fieldGuide(width: Int = 66) -> [String] {
        var lines: [String] = []
        var current = ""
        for key in CodingKeys.allCases {
            let entry = "\(key.rawValue)=\(key.gloss)"
            if current.isEmpty {
                current = entry
            } else if current.count + 2 + entry.count <= width {
                current += ", " + entry
            } else {
                lines.append(current + ",")
                current = entry
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}

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
        at: Date, origin: BreakOrigin, durationSeconds: Int,
        thresholdSeconds: Int? = nil, cycle: CycleID? = nil
    ) -> LoggedEvent {
        LoggedEvent(
            at: at, kind: .breakEnd, origin: origin,
            durationSeconds: durationSeconds, thresholdSeconds: thresholdSeconds,
            cycle: cycle?.rawValue
        )
    }

    public static func cycleClose(at: Date, cycle: CycleID, outcome: CycleOutcome) -> LoggedEvent {
        LoggedEvent(at: at, kind: .cycleClose, outcome: outcome, cycle: cycle.rawValue)
    }

    public static func gate(at: Date, reason: GateReason, cycle: CycleID? = nil) -> LoggedEvent {
        LoggedEvent(at: at, kind: .gate, gate: reason, cycle: cycle?.rawValue)
    }
}

public enum EventLogCodec {
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
