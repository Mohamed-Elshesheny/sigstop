import Foundation
import Testing

@testable import SigstopCore

@Suite("retention drops only days past the window, and nothing for a slow or reset clock or a day dated ahead")
struct RetentionTests {
    static let now = Date(timeIntervalSince1970: 1_758_500_000)
    static var today: CalendarDay { CalendarDay.utc(of: now) }
    static var cutoff: CalendarDay? { PruneMath.cutoffDay(retentionDays: 7, asOf: now) }

    private func scratch() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sigstop-ret-\(UUID().uuidString)")
    }

    private func store(days: [CalendarDay]) throws -> (FileEventStore, URL) {
        let root = scratch()
        let store = try FileEventStore(root: root)
        for day in days {
            let at = try #require(day.interval(boundaryHour: 12, calendar: Self.utcCalendar)?.start)
            try store.append(.breakBegin(at: at, origin: .accepted, cycle: CycleID.initial))
        }
        return (store, root)
    }

    private static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return c
    }

    @Test("a day inside the window survives, a day past it is dropped")
    func window() {
        #expect(!PruneMath.shouldDrop(Self.today, cutoff: Self.cutoff))
        #expect(!PruneMath.shouldDrop(Self.today.adding(days: -6), cutoff: Self.cutoff))
        #expect(PruneMath.shouldDrop(Self.today.adding(days: -7), cutoff: Self.cutoff))
    }

    @Test("a clock three days behind at launch deletes nothing")
    func clockBehindDeletesNothing() throws {
        let days = (0..<5).map { Self.today.adding(days: -$0) }
        let (store, root) = try store(days: days)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try store.prune(retentionDays: 7, asOf: Self.now.addingTimeInterval(-3 * 86_400))
        #expect(report.removedDays.isEmpty, "a slow clock deleted \(report.removedDays)")
        #expect(try store.availableDays().count == 5)
    }

    @Test("a clock reset to 2001 deletes nothing")
    func clockResetDeletesNothing() throws {
        let days = (0..<5).map { Self.today.adding(days: -$0) }
        let (store, root) = try store(days: days)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try store.prune(retentionDays: 7, asOf: Date(timeIntervalSince1970: 978_307_200))
        #expect(report.removedDays.isEmpty, "a reset clock deleted \(report.removedDays)")
    }

    @Test("a day dated ahead is kept and reported, not deleted")
    func futureIsReported() throws {
        let stray = CalendarDay(year: 2030, month: 1, day: 14)
        let (store, root) = try store(days: [Self.today, stray])
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.prune(retentionDays: 7, asOf: Self.now)
        #expect(try store.availableDays().contains(stray))
        #expect(PruneMath.futureDated(try store.availableDays(), asOf: Self.now) == [stray])
    }
}
