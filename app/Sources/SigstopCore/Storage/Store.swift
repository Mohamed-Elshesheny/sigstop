import Foundation

// MARK: - Errors

public enum StoreError: Error, Sendable, Hashable {
    /// A line claims a schema version this build does not understand. Readers reject
    /// unknown majors instead of guessing (docs/PRIVACY.md §4.3).
    case unsupportedSchemaVersion(Int)
    /// The storage root could not be created or written.
    case notWritable(path: String, reason: String)
    case notADirectory(path: String)
}

// MARK: - Reports

/// One day's worth of log, plus an honest count of what could not be read.
public struct DayLoad: Sendable, Hashable {
    public let day: CalendarDay
    /// Sorted ascending by timestamp.
    public let events: [LoggedEvent]
    /// Lines that did not parse. Surfaced rather than swallowed: a corrupt file never
    /// crashes the app and never *silently* changes your history.
    public let malformedLines: Int

    public init(day: CalendarDay, events: [LoggedEvent], malformedLines: Int = 0) {
        self.day = day
        self.events = events.sorted { $0.at < $1.at }
        self.malformedLines = malformedLines
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

/// What a "delete everything" actually removed. The app says what it did rather than
/// showing a spinner and a checkmark (docs/PRIVACY.md §4.6).
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

    /// Verbatim shape from docs/PRIVACY.md §4.6, including the honest footer about the
    /// two things no application can clean up for you.
    public var userFacingSummary: String {
        let size = DeletionReport.humanBytes(removedBytes)
        return """
        Deleted: \(location)  (\(removedFiles) files, \(size))
        Removed \(removedEvents) events across \(removedDays.count) day(s).

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

// MARK: - The protocol

/// Everything that touches durable state goes through here.
///
/// The point of the indirection is that `DailyRollup` never performs I/O: it is handed
/// `[LoggedEvent]` and returns a value. `FileEventStore` is the only thing in the tree
/// that knows a filesystem exists, and `InMemoryEventStore` is what the tests use, so
/// the rollup's behaviour is provable without a disk, a GUI session, or a clock.
public protocol EventStore: Sendable {
    /// Append one event. Implementations must be crash-safe at line granularity: a
    /// process that dies mid-write loses at most the line it was writing.
    func append(_ event: LoggedEvent) throws
    func append(contentsOf events: [LoggedEvent]) throws

    /// Every UTC day that currently has a log, ascending.
    func availableDays() throws -> [CalendarDay]

    func load(day: CalendarDay) throws -> DayLoad

    /// A single, self-describing text blob the user can read end to end. Nothing is
    /// transformed or filtered — the export is a copy, so what you audit is what the
    /// app has (docs/PRIVACY.md §4.6).
    func exportText() throws -> String

    /// Drop everything older than `retentionDays` counted back from `now`.
    /// `retentionDays == 0` means keep nothing — a real mode, not a degenerate one.
    @discardableResult
    func prune(retentionDays: Int, asOf now: Date) throws -> PruneReport

    /// Remove everything, and say what was removed.
    @discardableResult
    func deleteEverything() throws -> DeletionReport
}

// MARK: - Shared behaviour

extension EventStore {
    public func append(contentsOf events: [LoggedEvent]) throws {
        for event in events { try append(event) }
    }

    public func load(days: [CalendarDay]) throws -> [DayLoad] {
        try days.map { try load(day: $0) }
    }

    /// Every event that could belong to one **logical** day (local calendar, 04:00
    /// boundary). Reads the UTC files on either side, because a logical day straddles
    /// up to three of them, then clips to the day's interval.
    ///
    /// Events from just before the interval are deliberately kept: the walk needs to
    /// know which app was frontmost when the day began.
    public func events(
        forLogicalDay day: CalendarDay,
        calendar: Calendar = .current,
        policy: RollupPolicy = .default
    ) throws -> (events: [LoggedEvent], malformedLines: Int) {
        let loads = try [day.adding(days: -1), day, day.adding(days: 1)].map {
            try load(day: $0)
        }
        let merged = loads.flatMap(\.events).sorted { $0.at < $1.at }
        let malformed = loads.reduce(0) { $0 + $1.malformedLines }
        guard let interval = day.interval(boundaryHour: policy.dayBoundaryHour, calendar: calendar)
        else { return (merged, malformed) }
        let inWindow = merged.filter { $0.at >= interval.start && $0.at < interval.end }
        let before = merged.last { $0.at < interval.start }
        return ((before.map { [$0] } ?? []) + inWindow, malformed)
    }

    /// Retention default for raw events (docs/PRIVACY.md §4.5).
    public static var defaultRetentionDays: Int { 7 }
}

/// Retention defaults, in one place so the UI and the store cannot disagree.
public enum Retention {
    /// docs/PRIVACY.md §4.5. Range 0…365; 0 is "memory-only mode".
    public static let defaultEventDays = 7
    public static let minimumEventDays = 0
    public static let maximumEventDays = 365
    /// Daily summaries outlive raw events, because they are a hundredth of the data.
    public static let defaultSummaryDays = 90

    public static func clampEventDays(_ days: Int) -> Int {
        min(max(days, minimumEventDays), maximumEventDays)
    }
}

// MARK: - In-memory implementation

/// The reference implementation, and the one the tests use.
///
/// It is also the shape of "memory-only mode" (retention = 0 days): the engine works,
/// the summary is computed, and nothing is ever written to disk.
public final class InMemoryEventStore: EventStore, @unchecked Sendable {
    private let lock = NSLock()
    private var days: [CalendarDay: [LoggedEvent]] = [:]
    /// Injected so a test can simulate a log that already contains a torn line.
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

    /// Test affordance: pretend `count` lines of `day` were unreadable.
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
        for day in days.keys.sorted() where PruneMath.shouldDrop(day, cutoff: cutoff) {
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

// MARK: - Pruning arithmetic

/// Split out so both stores prune by the same rule and one test pins it.
public enum PruneMath {
    /// The oldest day that survives. `nil` means "keep nothing".
    public static func cutoffDay(retentionDays: Int, asOf now: Date) -> CalendarDay? {
        guard retentionDays > 0 else { return nil }
        let today = CalendarDay.utc(of: now)
        return today.adding(days: -(retentionDays - 1))
    }

    public static func shouldDrop(_ day: CalendarDay, cutoff: CalendarDay?) -> Bool {
        guard let cutoff else { return true }
        return day < cutoff
    }
}

// MARK: - Export rendering

/// One file, plain text, readable top to bottom.
///
/// Header lines start with `#`, which `EventLogCodec` skips — so the export is not only
/// human-readable, it feeds straight back into this same reader.
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
        out += "# schema v\(EventSchema.version) — one JSON object per line, see docs/PRIVACY.md §4.3\n"
        out += "# source: \(location)\n"
        if let first = days.first, let last = days.last {
            out += "# days: \(first) .. \(last)  (\(days.count))\n"
        } else {
            out += "# days: none\n"
        }
        out += "# events: \(total)\n"
        out += "# fields: v=schema, t=UTC second, e=event, app=bundle id, cat=category,\n"
        out += "#         act=inferred activity, sig=window-title CLASS (never the title),\n"
        out += "#         idle_s, reason, action, snooze_s, deferred, origin, dur_s, cycle\n"
        out += "# nothing here is transformed or filtered; this is a copy of what is on disk.\n"
        out += body
        return out
    }
}
