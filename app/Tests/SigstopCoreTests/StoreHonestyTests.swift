import Foundation
import Testing

@testable import SigstopCore

@Suite("the store does not invent an answer")
struct StoreHonestyTests {

    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return c
    }

    private func scratch() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sigstop-store-\(UUID().uuidString)")
    }

    @Test("a day whose file will not open is not reported as a day you did nothing")
    func unreadableIsNotEmpty() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEventStore(root: root)

        let at = Date(timeIntervalSince1970: 1_758_500_000)
        try store.append(.breakBegin(at: at, origin: .accepted, cycle: CycleID.initial))
        let day = CalendarDay.utc(of: at)

        let before = try store.load(day: day)
        #expect(!before.events.isEmpty)
        #expect(before.unreadable == false)

        let path = root.appendingPathComponent("events/\(day.fileName)")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }

        let after = try store.load(day: day)
        #expect(after.unreadable, "a file that will not open must say so, not report an empty day")

        #expect(throws: StoreError.self, "the rollup must refuse, not report a day with no work") {
            _ = try DailyRollup.compute(day: day, from: store, calendar: Self.utc)
        }
        let export = try store.exportText()
        #expect(export.contains("would not open: \(day)"), "the export must name the day it could not read")

        let absent = try store.load(day: day.adding(days: -30))
        #expect(absent.events.isEmpty)
        #expect(absent.unreadable == false, "a missing day is empty, not unreadable")
    }

    @Test("a day file that opens and then fails to read is unreadable, not an empty day")
    func dayFileWhoseReadThrows() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEventStore(root: root)

        let at = Date(timeIntervalSince1970: 1_758_500_000)
        try store.append(.breakBegin(at: at, origin: .accepted, cycle: CycleID.initial))
        let path = store.url(for: CalendarDay.utc(of: at))

        guard case .contents(let data) = SecureFile.read(path, limit: FileEventStore.largestDayFile) else {
            Issue.record("the day file the store just wrote has to read back")
            return
        }
        #expect(!data.isEmpty)

        let failed = SecureFile.read(path, limit: FileEventStore.largestDayFile) { _, _ in
            throw POSIXError(.EIO)
        }
        #expect(failed == .unreadable, "a read that fails after the open must not pass for an empty file")
    }

    @Test("an export names the day it could not read and does not count it")
    func exportNamesUnreadableDays() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEventStore(root: root)

        let first = Date(timeIntervalSince1970: 1_758_500_000)
        let second = first.addingTimeInterval(86_400)
        try store.append(.breakBegin(at: first, origin: .accepted, cycle: CycleID.initial))
        try store.append(.breakBegin(at: second, origin: .accepted, cycle: CycleID.initial))
        let lost = CalendarDay.utc(of: first)

        let path = root.appendingPathComponent("events/\(lost.fileName)")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }

        let report = try store.export(to: root.appendingPathComponent("export.txt"))
        #expect(report.days == 1)
        #expect(report.events == 1)
        #expect(report.unreadable == [lost])
        #expect(report.userFacingSummary.contains("would not open: \(lost.description)"))
    }

    @Test("a summary with impossible numbers is ignored instead of crashing every launch")
    func impossibleSummaryIsIgnored() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEventStore(root: root)
        let day = CalendarDay(year: 2026, month: 8, day: 3)
        try store.writeSummary(DailySummary(day: day, breakCount: 4))
        try store.writeSummary(DailySummary(day: CalendarDay(year: 2026, month: 8, day: 4), breakCount: Int.max))

        let read = try store.readAllSummaries()
        #expect(read[day]?.breakCount == 4)
        #expect(read.count == 1, "a planted Int.max has to be dropped, not summed")
        let days = read.values.map { BadgeDay(summary: $0) }
        let evidence = BadgeEvaluator.evidence(for: days, calendar: Self.utc, policy: .default)
        #expect(evidence.breaksTaken == 4)
    }

    @Test("badge sums saturate rather than trap")
    func badgeSumsSaturate() {
        let days = (1...2).map { n in
            BadgeDay(summary: DailySummary(day: CalendarDay(year: 2026, month: 8, day: n), breakCount: Int.max))
        }
        let evidence = BadgeEvaluator.evidence(for: days, calendar: Self.utc, policy: .default)
        #expect(evidence.breaksTaken == .max)
    }

    @Test("counters with an impossible cycle number start fresh, and the cycle number wraps")
    func impossibleCountersStartFresh() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEventStore(root: root)
        try store.writeCounters(DailyCounters(nextCycle: CycleID(rawValue: .max)))
        #expect(try store.readCounters() == nil)
        #expect(CycleID(rawValue: .max).next() == CycleID(rawValue: 0))
    }

    @Test("counters and a summary the app really writes survive a relaunch unchanged")
    func realFilesRoundTrip() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEventStore(root: root)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let counters = DailyCounters(
            dayIndex: LocalDay.index(of: now, calendar: Self.utc, boundaryHour: 4),
            notificationsDelivered: 9,
            lastNotificationAt: now,
            consecutiveIgnoredCycles: 2,
            breakOpportunities: 5,
            honoredOpportunities: 3,
            excludedOpportunities: 1,
            nextCycle: CycleID(rawValue: 7)
        )
        try store.writeCounters(counters)
        #expect(try store.readCounters() == counters)

        let day = CalendarDay.utc(of: now)
        let summary = DailySummary(
            day: day, totalActiveWork: 6 * 3600, longestContinuousSession: 3000,
            breakCount: 4, breakOpportunities: 6, honoredOpportunities: 4, excludedOpportunities: 1
        )
        try store.writeSummary(summary)
        #expect(try store.readAllSummaries()[day] == summary)
    }

    @Test("a day file bigger than the cap is reported unreadable, not loaded into memory")
    func oversizedDayIsUnreadable() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEventStore(root: root)
        let at = Date(timeIntervalSince1970: 1_758_500_000)
        try store.append(.breakBegin(at: at, origin: .accepted, cycle: CycleID.initial))
        let day = CalendarDay.utc(of: at)
        let path = root.appendingPathComponent("events/\(day.fileName)")
        let handle = try FileHandle(forWritingTo: path)
        try handle.truncate(atOffset: UInt64(FileEventStore.largestDayFile + 1))
        try handle.close()

        let load = try store.load(day: day)
        #expect(load.unreadable)
        #expect(load.events.isEmpty)
    }

    @Test("a summaries file that will not decode is set aside, not overwritten")
    func corruptSummaryIsKept() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEventStore(root: root)

        let day = CalendarDay(year: 2026, month: 9, day: 22)
        let summary = DailySummary(day: day)
        try store.writeSummary(summary)

        let path = root.appendingPathComponent("summaries/2026-09.json")
        let original = try Data(contentsOf: path)
        #expect(!original.isEmpty)

        try Data("{\"v\":1,\"days\":{\"2026-09-21\":{\"totalActiveWork\":12}}}".utf8).write(to: path)

        try store.writeSummary(DailySummary(day: CalendarDay(year: 2026, month: 9, day: 23)))

        let aside = root.appendingPathComponent("summaries/2026-09.json.unreadable")
        #expect(FileManager.default.fileExists(atPath: aside.path),
                "the month that would not decode must still be on disk to recover by hand")

        let rewritten = try store.readSummaries(year: 2026, month: 9)
        #expect(rewritten.count == 1, "the new month starts from today, which is the only honest option")

        let first = try Data(contentsOf: aside)
        try Data("{\"v\":1,\"days\":{\"broken\":true}}".utf8).write(to: path)
        try store.writeSummary(DailySummary(day: CalendarDay(year: 2026, month: 9, day: 24)))
        let second = root.appendingPathComponent("summaries/2026-09.json.unreadable-2")
        #expect(try Data(contentsOf: aside) == first, "a second failure must not overwrite the first month set aside")
        #expect(FileManager.default.fileExists(atPath: second.path), "the second one goes beside it")
    }

    @Test("a summaries month that will not open is left alone, not replaced by a month of one day")
    func unopenableSummaryMonthIsKept() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEventStore(root: root)
        for n in 1...20 {
            try store.writeSummary(DailySummary(day: CalendarDay(year: 2026, month: 9, day: n), breakCount: n))
        }

        let path = root.appendingPathComponent("summaries/2026-09.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }

        #expect(throws: StoreError.self, "a month that will not open must refuse the write, not start over") {
            try store.writeSummary(DailySummary(day: CalendarDay(year: 2026, month: 9, day: 23)))
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let kept = try store.readSummaries(year: 2026, month: 9)
        #expect(kept.count == 20, "every earlier day of the month is still there")
        #expect(kept[CalendarDay(year: 2026, month: 9, day: 7)]?.breakCount == 7)
        let names = try FileManager.default.contentsOfDirectory(atPath: store.summariesDirectory.path)
        #expect(names == ["2026-09.json"], "nothing was set aside or written beside it")
    }

    @Test("a badge ledger or counters file that will not open is reported, and nothing is written over it")
    func unopenableLedgerAndCountersAreLeftAlone() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEventStore(root: root)

        #expect(try store.readBadges().isEmpty, "a ledger that is not there yet is an empty one")
        #expect(try store.readCounters() == nil, "counters that are not there yet start fresh")

        var ledger = BadgeLedger()
        ledger.record(.stoppedOnce, on: CalendarDay(year: 2026, month: 9, day: 1))
        try store.writeBadges(ledger)
        let counters = DailyCounters(dayIndex: 20_260_901, notificationsDelivered: 3, nextCycle: CycleID(rawValue: 4))
        try store.writeCounters(counters)
        let files = [store.badgesFile, store.countersFile]
        let before = try files.map { try Data(contentsOf: $0) }

        for file in files {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        }
        defer {
            for file in files {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }

        #expect(throws: StoreError.wouldNotOpen(path: store.badgesFile.path)) { _ = try store.readBadges() }
        #expect(throws: StoreError.wouldNotOpen(path: store.countersFile.path)) { _ = try store.readCounters() }
        #expect(throws: StoreError.self, "a ledger that will not open is not replaced by an empty one") {
            try store.writeBadges(.empty)
        }
        #expect(throws: StoreError.self, "counters that will not open are not replaced by fresh ones") {
            try store.writeCounters(DailyCounters())
        }

        for file in files {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        #expect(try files.map { try Data(contentsOf: $0) } == before)
        #expect(try store.readBadges() == ledger)
        #expect(try store.readCounters() == counters)
    }

    @Test("a badge ledger that opens but will not decode is left alone, not read as empty and replaced")
    func undecodableLedgerIsLeftAlone() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEventStore(root: root)

        let newer = Data("{\"v\":2,\"unlocked\":{\"stopped-1\":\"2026-09-01\"}}".utf8)
        let truncated = Data("{\"v\":1,\"unlocked\":{\"stopped-1\":\"2026-0".utf8)
        var derived = BadgeLedger()
        derived.record(.stoppedOnce, on: CalendarDay(year: 2026, month: 9, day: 20))

        for bytes in [newer, truncated] {
            try bytes.write(to: store.badgesFile)

            #expect(throws: StoreError.wouldNotDecode(path: store.badgesFile.path)) { _ = try store.readBadges() }
            #expect(throws: StoreError.self, "a ledger that will not decode is not replaced by a derived one") {
                try store.writeBadges(derived)
            }
            #expect(try Data(contentsOf: store.badgesFile) == bytes, "the file is exactly as it was")
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
            #expect(names == ["badges.json", "events", "summaries"], "nothing was set aside or written beside it")
        }
    }

    private func inode(_ url: URL) -> UInt64? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }

    @Test("deleting everything keeps the held lock file, the same one, and removes every other file")
    func deleteKeepsTheInstanceLock() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEventStore(root: root)

        let lockFile = root.appendingPathComponent(FileEventStore.lockFileName)
        let held = open(lockFile.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try #require(held >= 0)
        defer { close(held) }
        try #require(flock(held, LOCK_EX | LOCK_NB) == 0)
        let lockBefore = try #require(inode(lockFile))

        let at = Date(timeIntervalSince1970: 1_758_500_000)
        try store.append(.breakBegin(at: at, origin: .accepted, cycle: CycleID.initial))
        try store.writeSummary(DailySummary(day: CalendarDay.utc(of: at)))
        try store.writeBadges(BadgeLedger())
        try store.writeCounters(DailyCounters())
        try Data("{}".utf8).write(to: root.appendingPathComponent("settings.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("call-hold.json"))
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        try Data("keep".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"), withDestinationURL: outside
        )

        let report = try store.deleteEverything()

        #expect(inode(lockFile) == lockBefore, "the lock is the same file, so the flock on it still counts")
        let second = open(lockFile.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try #require(second >= 0)
        defer { close(second) }
        #expect(flock(second, LOCK_EX | LOCK_NB) != 0, "a second copy is still refused after the delete")

        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(left == [FileEventStore.lockFileName, "events", "summaries"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.eventsDirectory.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.summariesDirectory.path).isEmpty)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "keep", "a link is removed, not followed")
        #expect(report.removedFiles == 6, "the lock is not counted as removed")
        #expect(report.keptLock)
        #expect(report.userFacingSummary.contains("Kept: its .lock"))
    }
}
