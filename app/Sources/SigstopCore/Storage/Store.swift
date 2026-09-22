import Foundation

public enum StoreError: Error, Sendable, Hashable {
    case unsupportedSchemaVersion(Int)
    case notWritable(path: String, reason: String)
    case notADirectory(path: String)
    case unreadable(days: [CalendarDay])
}

public struct DayLoad: Sendable, Hashable {
    public let day: CalendarDay
    public let events: [LoggedEvent]
    public let malformedLines: Int
    public let unreadable: Bool

    public init(
        day: CalendarDay,
        events: [LoggedEvent],
        malformedLines: Int = 0,
        unreadable: Bool = false
    ) {
        self.day = day
        self.events = events.sorted { $0.at < $1.at }
        self.malformedLines = malformedLines
        self.unreadable = unreadable
    }

    public static func empty(_ day: CalendarDay) -> DayLoad {
        DayLoad(day: day, events: [], malformedLines: 0)
    }
}

public struct PruneReport: Sendable, Hashable {
    public let removedDays: [CalendarDay]
    public let removedEvents: Int
    public let retentionDays: Int

    public init(removedDays: [CalendarDay], removedEvents: Int, retentionDays: Int) {
        self.removedDays = removedDays
        self.removedEvents = removedEvents
        self.retentionDays = retentionDays
    }

    public var isEmpty: Bool { removedDays.isEmpty }

    public var userFacingSummary: String {
        guard !removedDays.isEmpty else {
            return "Nothing to prune. Retention is \(retentionDays) days."
        }
        let range = removedDays.count == 1
            ? "\(removedDays[0])"
            : "\(removedDays[0]) – \(removedDays[removedDays.count - 1])"
        return "Pruned \(removedDays.count) day(s) (\(range)), \(removedEvents) events, "
            + "older than the \(retentionDays)-day retention window."
    }
}

public struct DeletionReport: Sendable, Hashable {
    public let location: String
    public let removedFiles: Int
    public let removedBytes: Int
    public let removedDays: [CalendarDay]
    public let removedEvents: Int

    public init(
        location: String,
        removedFiles: Int,
        removedBytes: Int,
        removedDays: [CalendarDay],
        removedEvents: Int
    ) {
        self.location = location
        self.removedFiles = removedFiles
        self.removedBytes = removedBytes
        self.removedDays = removedDays
        self.removedEvents = removedEvents
    }

    public var userFacingSummary: String {
        let size = DeletionReport.humanBytes(removedBytes)
        return """
        Deleted: \(location)  (\(removedFiles) files, \(size))
        Removed \(removedEvents) events across \(removedDays.count) day(s).
        sigstop is still running, so a new, empty log starts from now.

        Two things this app cannot remove for you:
          • The Accessibility permission you granted. Remove it in
            System Settings → Privacy & Security → Accessibility,
            or run:  tccutil reset Accessibility <BUNDLE_ID>
          • System log entries macOS wrote. Run:  sudo log erase --all   (clears the whole system log)

        There is no archive, no tombstone, no soft delete, and no copy kept anywhere.
        """
    }

    static func humanBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        let kb = Double(n) / 1024
        if kb < 1024 { return "\(Int(kb.rounded())) KB" }
        return String(format: "%.1f MB", kb / 1024)
    }
}

public protocol EventStore: Sendable {
    func append(_ event: LoggedEvent) throws
    func append(contentsOf events: [LoggedEvent]) throws

    func availableDays() throws -> [CalendarDay]

    func load(day: CalendarDay) throws -> DayLoad

    func exportText() throws -> String

    @discardableResult
    func prune(retentionDays: Int, asOf now: Date) throws -> PruneReport

    @discardableResult
    func deleteEverything() throws -> DeletionReport
}

extension EventStore {
    public func append(contentsOf events: [LoggedEvent]) throws {
        for event in events { try append(event) }
    }

    public func load(days: [CalendarDay]) throws -> [DayLoad] {
        try days.map { try load(day: $0) }
    }

    public func events(
        forLogicalDay day: CalendarDay,
        calendar: Calendar = .current,
        policy: RollupPolicy = .default
    ) throws -> (events: [LoggedEvent], malformedLines: Int) {
        let loads = try [day.adding(days: -1), day, day.adding(days: 1)].map {
            try load(day: $0)
        }
        let unreadable = loads.filter(\.unreadable).map(\.day)
        if !unreadable.isEmpty { throw StoreError.unreadable(days: unreadable) }
        let merged = loads.flatMap(\.events).sorted { $0.at < $1.at }
        let malformed = loads.reduce(0) { $0 + $1.malformedLines }
        guard let interval = day.interval(boundaryHour: policy.dayBoundaryHour, calendar: calendar)
        else { return (merged, malformed) }
        let inWindow = merged.filter { $0.at >= interval.start && $0.at < interval.end }
        let before = merged.last { $0.at < interval.start }
        return ((before.map { [$0] } ?? []) + inWindow, malformed)
    }

    public static var defaultRetentionDays: Int { 7 }
}

public enum Retention {
    public static let defaultEventDays = 7
    public static let minimumEventDays = 0
    public static let maximumEventDays = 365
    public static let defaultSummaryDays = 90

    public static func clampEventDays(_ days: Int) -> Int {
        min(max(days, minimumEventDays), maximumEventDays)
    }
}

public final class InMemoryEventStore: EventStore, @unchecked Sendable {
    private let lock = NSLock()
    private var days: [CalendarDay: [LoggedEvent]] = [:]
    private var injectedMalformed: [CalendarDay: Int] = [:]

    public init(events: [LoggedEvent] = []) {
        for event in events { days[event.fileDay, default: []].append(event) }
        for key in days.keys { days[key]?.sort { $0.at < $1.at } }
    }

    public func append(_ event: LoggedEvent) throws {
        lock.lock()
        defer { lock.unlock() }
        days[event.fileDay, default: []].append(event)
        days[event.fileDay]?.sort { $0.at < $1.at }
    }

    public func availableDays() throws -> [CalendarDay] {
        lock.lock()
        defer { lock.unlock() }
        return days.keys.sorted()
    }

    public func load(day: CalendarDay) throws -> DayLoad {
        lock.lock()
        defer { lock.unlock() }
        return DayLoad(
            day: day,
            events: days[day] ?? [],
            malformedLines: injectedMalformed[day] ?? 0
        )
    }

    public func injectMalformedLines(_ count: Int, on day: CalendarDay) {
        lock.lock()
        defer { lock.unlock() }
        injectedMalformed[day] = count
    }

    public func exportText() throws -> String {
        lock.lock()
        let snapshot = days
        lock.unlock()
        return try ExportWriter.render(location: "(memory)", days: snapshot.keys.sorted()) { day in
            snapshot[day] ?? []
        }
    }

    @discardableResult
    public func prune(retentionDays: Int, asOf now: Date) throws -> PruneReport {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = PruneMath.cutoffDay(retentionDays: retentionDays, asOf: now)
        var removedDays: [CalendarDay] = []
        var removedEvents = 0
        for day in days.keys.sorted() where PruneMath.shouldDrop(day, cutoff: cutoff, today: CalendarDay.utc(of: now)) {
            removedEvents += days[day]?.count ?? 0
            days[day] = nil
            injectedMalformed[day] = nil
            removedDays.append(day)
        }
        return PruneReport(
            removedDays: removedDays, removedEvents: removedEvents, retentionDays: retentionDays
        )
    }

    @discardableResult
    public func deleteEverything() throws -> DeletionReport {
        lock.lock()
        defer { lock.unlock() }
        let removedDays = days.keys.sorted()
        let removedEvents = days.values.reduce(0) { $0 + $1.count }
        let bytes = (try? EventLogCodec.encodeLines(days.values.flatMap { $0 }).utf8.count) ?? 0
        days.removeAll()
        injectedMalformed.removeAll()
        return DeletionReport(
            location: "(memory)",
            removedFiles: removedDays.count,
            removedBytes: bytes,
            removedDays: removedDays,
            removedEvents: removedEvents
        )
    }
}

public enum PruneMath {
    public static func cutoffDay(retentionDays: Int, asOf now: Date) -> CalendarDay? {
        guard retentionDays > 0 else { return nil }
        let today = CalendarDay.utc(of: now)
        return today.adding(days: -(retentionDays - 1))
    }

    public static func shouldDrop(_ day: CalendarDay, cutoff: CalendarDay?, today: CalendarDay) -> Bool {
        if day > today { return true }
        guard let cutoff else { return true }
        return day < cutoff
    }
}

enum ExportWriter {
    static func render(
        location: String,
        days: [CalendarDay],
        events: (CalendarDay) -> [LoggedEvent]
    ) throws -> String {
        var out = ""
        var total = 0
        var body = ""
        for day in days {
            let dayEvents = events(day)
            total += dayEvents.count
            body += "\n# --- \(day) ---\n"
            body += try EventLogCodec.encodeLines(dayEvents)
        }
        out += "# sigstop event log export\n"
        out += "# schema v\(EventSchema.version), one JSON object per line, see docs/PRIVACY.md §4.3\n"
        out += "# source: \(location)\n"
        if let first = days.first, let last = days.last {
            out += "# days: \(first) .. \(last)  (\(days.count))\n"
        } else {
            out += "# days: none\n"
        }
        out += "# events: \(total)\n"
        for (i, line) in LoggedEvent.fieldGuide().enumerated() {
            out += i == 0 ? "# fields: \(line)\n" : "#         \(line)\n"
        }
        out += "# nothing here is transformed or filtered; this is a copy of what is on disk.\n"
        out += body
        return out
    }
}
