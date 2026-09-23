import Foundation

public final class FileEventStore: EventStore, @unchecked Sendable {
    public static let largestDayFile = 32 * 1024 * 1024
    static let largestRecordFile = 32 * 1024 * 1024
    static let leftAsItIs = "it is there but will not open, so it is left as it is rather than replaced"

    public let root: URL
    public let eventsDirectory: URL
    public let summariesDirectory: URL

    private let lock = NSLock()
    private let fm = FileManager.default

    public init(root: URL) throws {
        self.root = root
        self.eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        self.summariesDirectory = root.appendingPathComponent("summaries", isDirectory: true)
        try createTree()
    }

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
            guard SecureFile.isOwnDirectory(dir) else {
                throw StoreError.notWritable(
                    path: dir.path, reason: "it is a symbolic link or not a folder of yours, so nothing is written through it"
                )
            }
        }
    }

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

    private func appendRaw(_ text: String, to url: URL) throws {
        try SecureFile.append(Data(text.utf8), to: url)
    }

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
        let data: Data
        switch SecureFile.read(url(for: day), limit: Self.largestDayFile) {
        case .absent: return .empty(day)
        case .unreadable: return DayLoad(day: day, events: [], malformedLines: 0, unreadable: true)
        case .contents(let contents): data = contents
        }
        let result = EventLogCodec.decodeLines(String(decoding: data, as: UTF8.self))
        return DayLoad(day: day, events: result.events, malformedLines: result.malformedLines)
    }

    public func exportText() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let days = try unlockedAvailableDays()
        var cache: [CalendarDay: [LoggedEvent]] = [:]
        var unreadable: [CalendarDay] = []
        for day in days {
            let loaded = unlockedLoad(day: day)
            cache[day] = loaded.events
            if loaded.unreadable { unreadable.append(day) }
        }
        let location = (root.path as NSString).abbreviatingWithTildeInPath
        let text = try ExportWriter.render(location: location, days: days) { cache[$0] ?? [] }
        guard !unreadable.isEmpty else { return text }
        let list = unreadable.map(\.description).joined(separator: ", ")
        return text + "\nNot exported, the file is there but would not open: \(list)\n"
    }

    public struct ExportReport: Sendable, Hashable {
        public let destination: String
        public let days: Int
        public let events: Int
        public let bytes: Int
        public let unreadable: [CalendarDay]

        public var userFacingSummary: String {
            let exported = "Exported \(events) events across \(days) day(s) "
                + "(\(DeletionReport.humanBytes(bytes))) to \(destination)."
            guard !unreadable.isEmpty else { return exported }
            let list = unreadable.map(\.description).joined(separator: ", ")
            return exported + " Not exported, the file is there but would not open: \(list)."
        }
    }

    @discardableResult
    public func export(to destination: URL) throws -> ExportReport {
        let text = try exportText()
        lock.lock()
        defer { lock.unlock() }
        let data = Data(text.utf8)
        try writeAtomically(data, to: destination)
        let loads = try unlockedAvailableDays().map { unlockedLoad(day: $0) }
        let readable = loads.filter { !$0.unreadable }
        return ExportReport(
            destination: destination.path,
            days: readable.count,
            events: readable.reduce(0) { $0 + $1.events.count },
            bytes: data.count,
            unreadable: loads.filter(\.unreadable).map(\.day)
        )
    }

    func writeAtomically(_ data: Data, to destination: URL) throws {
        try SecureFile.write(data, to: destination)
    }

    public func writeSummary(_ summary: DailySummary) throws {
        lock.lock()
        defer { lock.unlock() }
        let name = "\(Pad.four(summary.day.year))-\(Pad.two(summary.day.month)).json"
        let path = summariesDirectory.appendingPathComponent(name)

        var file: SummaryFile
        switch SecureFile.read(path, limit: Self.largestRecordFile) {
        case .absent:
            file = SummaryFile(v: EventSchema.version, days: [:])
        case .unreadable:
            throw StoreError.notWritable(path: path.path, reason: Self.leftAsItIs)
        case .contents(let data):
            if let decoded = try? JSONDecoder().decode(SummaryFile.self, from: data) {
                file = decoded
            } else {
                var aside = path.appendingPathExtension("unreadable")
                var n = 2
                while fm.fileExists(atPath: aside.path) {
                    aside = path.appendingPathExtension("unreadable-\(n)")
                    n += 1
                }
                try fm.moveItem(at: path, to: aside)
                file = SummaryFile(v: EventSchema.version, days: [:])
            }
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

    public func readAllSummaries() throws -> [CalendarDay: DailySummary] {
        lock.lock()
        defer { lock.unlock() }
        let contents = (try? fm.contentsOfDirectory(
            at: summariesDirectory, includingPropertiesForKeys: nil
        )) ?? []
        var out: [CalendarDay: DailySummary] = [:]
        for url in contents where url.pathExtension == "json" {
            guard
                let data = fm.contents(atPath: url.path),
                let file = try? JSONDecoder().decode(SummaryFile.self, from: data)
            else { continue }
            for (key, value) in file.days where value.isPlausible {
                if let day = CalendarDay.parse(key) { out[day] = value }
            }
        }
        return out
    }

    public var badgesFile: URL {
        root.appendingPathComponent("badges.json", isDirectory: false)
    }

    public func writeBadges(_ ledger: BadgeLedger) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writeAtomically(try encoder.encode(ledger), to: badgesFile)
    }

    public func readBadges() -> BadgeLedger {
        lock.lock()
        defer { lock.unlock() }
        guard let data = fm.contents(atPath: badgesFile.path) else { return .empty }
        return (try? JSONDecoder().decode(BadgeLedger.self, from: data)) ?? .empty
    }

    public var countersFile: URL {
        root.appendingPathComponent("counters.json", isDirectory: false)
    }

    public func writeCounters(_ counters: DailyCounters) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writeAtomically(try encoder.encode(counters), to: countersFile)
    }

    public func readCounters() -> DailyCounters? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = fm.contents(atPath: countersFile.path),
              let counters = try? JSONDecoder().decode(DailyCounters.self, from: data),
              counters.isPlausible
        else { return nil }
        return counters
    }

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
