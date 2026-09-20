import Foundation

// Foundation only. This is the one file in `SigstopCore` that touches the filesystem,
// and it is still forbidden AppKit (CLAUDE.md §3.1) and every networking module
// (CLAUDE.md §4.3). It reads and writes exactly one directory tree — the storage root
// it was handed — and nothing else on the disk (docs/PRIVACY.md §2.1).
//
// It reads no clock: `prune` takes `now`, and every event carries its own timestamp
// from a `TimeSource` upstream (CLAUDE.md §3.2).

/// The on-disk store.
///
/// ```
/// <root>/                        (0700)
/// ├── events/
/// │   ├── 2026-09-19.jsonl       (0600)  append-only, one JSON object per line
/// │   └── 2026-09-20.jsonl
/// └── summaries/
///     └── 2026-09.json           (0600)
/// ```
///
/// No database, no binary blob, no encoding. The format is chosen so that `cat` is a
/// complete audit tool — a skeptical developer should understand a line in ten seconds
/// and the whole file in a minute. That is a feature, not a shortcut.
public final class FileEventStore: EventStore, @unchecked Sendable {
    public let root: URL
    public let eventsDirectory: URL
    public let summariesDirectory: URL

    private let lock = NSLock()
    private let fm = FileManager.default

    /// - Parameter root: the storage root. Creating it (and `events/`, `summaries/`)
    ///   is the only directory creation this type ever performs.
    public init(root: URL) throws {
        self.root = root
        self.eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        self.summariesDirectory = root.appendingPathComponent("summaries", isDirectory: true)
        try createTree()
    }

    /// `~/Library/Application Support/<bundleID>` — or the sandboxed container's
    /// equivalent, which `applicationSupport` already accounts for when the caller got
    /// it from `FileManager`. Resolving the URL is the app layer's job; this type only
    /// assembles the path so `SigstopCore` never has to ask the OS anything.
    public static func defaultRoot(applicationSupport: URL, bundleID: String) -> URL {
        applicationSupport.appendingPathComponent(bundleID, isDirectory: true)
    }

    private func createTree() throws {
        for dir in [root, eventsDirectory, summariesDirectory] {
            do {
                try fm.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw StoreError.notWritable(
                    path: dir.path, reason: (error as NSError).localizedDescription
                )
            }
        }
    }

    // MARK: - Append

    public func append(_ event: LoggedEvent) throws {
        try append(contentsOf: [event])
    }

    public func append(contentsOf events: [LoggedEvent]) throws {
        guard !events.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var byDay: [CalendarDay: [LoggedEvent]] = [:]
        for event in events { byDay[event.fileDay, default: []].append(event) }
        for (day, dayEvents) in byDay.sorted(by: { $0.key < $1.key }) {
            let text = try EventLogCodec.encodeLines(dayEvents.sorted { $0.at < $1.at })
            try appendRaw(text, to: url(for: day))
        }
    }

    /// Append-only, `0600`, one `write` per batch, then `fsync`.
    ///
    /// Crash safety, concretely. A process killed mid-write leaves a partial final line
    /// with no trailing newline. Two things then hold:
    ///
    /// 1. The reader skips and counts that line instead of dying on it, so the rest of
    ///    the day survives intact.
    /// 2. The next append **heals the tail** — if the file does not end in a newline, a
    ///    newline is written first. Without that step the torn bytes would fuse with the
    ///    next event and quietly corrupt two lines instead of one.
    private func appendRaw(_ text: String, to url: URL) throws {
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(
                atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]
            ) else {
                throw StoreError.notWritable(path: url.path, reason: "could not create file")
            }
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let last = try handle.read(upToCount: 1)
            if last != Data([0x0A]) {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0x0A]))
            }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.synchronize()
    }

    // MARK: - Read

    public func url(for day: CalendarDay) -> URL {
        eventsDirectory.appendingPathComponent(day.fileName)
    }

    public func availableDays() throws -> [CalendarDay] {
        lock.lock()
        defer { lock.unlock() }
        return try unlockedAvailableDays()
    }

    private func unlockedAvailableDays() throws -> [CalendarDay] {
        let contents = (try? fm.contentsOfDirectory(
            at: eventsDirectory, includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { CalendarDay.parse($0.deletingPathExtension().lastPathComponent) }
            .sorted()
    }

    public func load(day: CalendarDay) throws -> DayLoad {
        lock.lock()
        defer { lock.unlock() }
        return unlockedLoad(day: day)
    }

    private func unlockedLoad(day: CalendarDay) -> DayLoad {
        let path = url(for: day)
        guard let data = fm.contents(atPath: path.path) else { return .empty(day) }
        let result = EventLogCodec.decodeLines(String(decoding: data, as: UTF8.self))
        return DayLoad(day: day, events: result.events, malformedLines: result.malformedLines)
    }

    // MARK: - Export

    public func exportText() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let days = try unlockedAvailableDays()
        var cache: [CalendarDay: [LoggedEvent]] = [:]
        for day in days { cache[day] = unlockedLoad(day: day).events }
        return try ExportWriter.render(location: root.path, days: days) { cache[$0] ?? [] }
    }

    public struct ExportReport: Sendable, Hashable {
        public let destination: String
        public let days: Int
        public let events: Int
        public let bytes: Int

        public var userFacingSummary: String {
            "Exported \(events) events across \(days) day(s) "
                + "(\(DeletionReport.humanBytes(bytes))) to \(destination)."
        }
    }

    /// Write the export as a single file the user can open in any text editor.
    /// Written atomically: readers of `destination` see either the old file or the whole
    /// new one, never a half-written export.
    @discardableResult
    public func export(to destination: URL) throws -> ExportReport {
        let text = try exportText()
        lock.lock()
        defer { lock.unlock() }
        let data = Data(text.utf8)
        try writeAtomically(data, to: destination)
        let days = try unlockedAvailableDays()
        let events = days.reduce(0) { $0 + unlockedLoad(day: $1).events.count }
        return ExportReport(
            destination: destination.path, days: days.count, events: events, bytes: data.count
        )
    }

    /// temp file in the same directory, fsync, then `rename(2)` via `replaceItemAt`.
    /// Same-directory is load-bearing: a cross-volume move is a copy, and a copy is not
    /// atomic.
    func writeAtomically(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)"
        )
        guard fm.createFile(
            atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]
        ) else {
            throw StoreError.notWritable(path: temp.path, reason: "could not create temp file")
        }
        do {
            let handle = try FileHandle(forWritingTo: temp)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: destination)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    // MARK: - Summaries

    /// `summaries/YYYY-MM.json`, one object per day, rewritten atomically.
    /// Summaries outlive raw events (90 days vs 7) because they are a hundredth of the
    /// data and answer "what did last month look like" without keeping the trace.
    public func writeSummary(_ summary: DailySummary) throws {
        lock.lock()
        defer { lock.unlock() }
        let name = "\(Pad.four(summary.day.year))-\(Pad.two(summary.day.month)).json"
        let path = summariesDirectory.appendingPathComponent(name)

        var file: SummaryFile
        if let data = fm.contents(atPath: path.path),
           let decoded = try? JSONDecoder().decode(SummaryFile.self, from: data) {
            file = decoded
        } else {
            file = SummaryFile(v: EventSchema.version, days: [:])
        }
        file.days[summary.day.description] = summary

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writeAtomically(try encoder.encode(file), to: path)
    }

    public func readSummaries(year: Int, month: Int) throws -> [CalendarDay: DailySummary] {
        lock.lock()
        defer { lock.unlock() }
        let name = "\(Pad.four(year))-\(Pad.two(month)).json"
        let path = summariesDirectory.appendingPathComponent(name)
        guard
            let data = fm.contents(atPath: path.path),
            let file = try? JSONDecoder().decode(SummaryFile.self, from: data)
        else { return [:] }
        var out: [CalendarDay: DailySummary] = [:]
        for (key, value) in file.days {
            if let day = CalendarDay.parse(key) { out[day] = value }
        }
        return out
    }

    struct SummaryFile: Codable {
        var v: Int
        var days: [String: DailySummary]
    }

    // MARK: - Retention

    /// Retention is a file deletion, never a rewrite. That is the payoff for one file
    /// per day: nothing is ever partially scrubbed (docs/PRIVACY.md §4.5).
    @discardableResult
    public func prune(retentionDays: Int, asOf now: Date) throws -> PruneReport {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = PruneMath.cutoffDay(retentionDays: retentionDays, asOf: now)
        var removedDays: [CalendarDay] = []
        var removedEvents = 0
        for day in try unlockedAvailableDays() where PruneMath.shouldDrop(day, cutoff: cutoff) {
            removedEvents += unlockedLoad(day: day).events.count
            try fm.removeItem(at: url(for: day))
            removedDays.append(day)
        }
        return PruneReport(
            removedDays: removedDays, removedEvents: removedEvents, retentionDays: retentionDays
        )
    }

    // MARK: - Delete

    /// Removes the storage directory recursively and reports what went. No archive, no
    /// tombstone, no soft delete (docs/PRIVACY.md §4.6). The tree is recreated empty so
    /// the app keeps working without a relaunch.
    @discardableResult
    public func deleteEverything() throws -> DeletionReport {
        lock.lock()
        defer { lock.unlock() }

        let days = try unlockedAvailableDays()
        let removedEvents = days.reduce(0) { $0 + unlockedLoad(day: $1).events.count }
        let (files, bytes) = measure(root)

        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
        try createTree()

        return DeletionReport(
            location: root.path,
            removedFiles: files,
            removedBytes: bytes,
            removedDays: days,
            removedEvents: removedEvents
        )
    }

    private func measure(_ directory: URL) -> (files: Int, bytes: Int) {
        guard let e = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return (0, 0) }
        var files = 0
        var bytes = 0
        for case let url as URL in e {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            files += 1
            bytes += values?.fileSize ?? 0
        }
        return (files, bytes)
    }
}
