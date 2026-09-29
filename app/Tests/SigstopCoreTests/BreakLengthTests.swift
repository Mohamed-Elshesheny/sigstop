import Foundation
import Testing

@testable import SigstopCore

@Suite("the summary keeps the seconds spent in the breaks it counts")
struct BreakLengthTests {

    private static let calendar = CalendarDay.utcCalendar
    private static let policy = RollupPolicy(qualifyingBreak: 5 * 60, dayBoundaryHour: 4)
    private static let day = CalendarDay(year: 2026, month: 9, day: 20)
    private static let xcode = "com.apple.dt.Xcode"

    private static func t(_ minutes: Double) throws -> Date {
        let nine = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 9)))
        return nine.addingTimeInterval(minutes * 60)
    }

    private static func roll(_ events: [LoggedEvent]) -> DailySummary {
        DailyRollup.compute(day: day, events: events, policy: policy, calendar: calendar)
    }

    @Test("two breaks that count add up, and the one that was abandoned does not")
    func qualifyingBreaksAddUp() throws {
        let events: [LoggedEvent] = [
            .start(at: try Self.t(0)),
            .focus(at: try Self.t(0), app: Self.xcode, activity: .coding),
            .breakBegin(at: try Self.t(45), origin: .accepted),
            .breakEnd(at: try Self.t(51), origin: .accepted, durationSeconds: 6 * 60),
            .focus(at: try Self.t(51), app: Self.xcode, activity: .coding),
            .breakBegin(at: try Self.t(100), origin: .userInitiated),
            .breakEnd(at: try Self.t(102), origin: .userInitiated, durationSeconds: 2 * 60),
            .focus(at: try Self.t(102), app: Self.xcode, activity: .coding),
            .breakBegin(at: try Self.t(150), origin: .idleInferred),
            .breakEnd(at: try Self.t(158), origin: .idleInferred, durationSeconds: 8 * 60),
            .stop(at: try Self.t(200)),
        ]
        let s = Self.roll(events)
        #expect(s.breakCount == 2)
        #expect(s.breaksAbandoned == 1)
        #expect(s.totalBreakTime == 14 * 60)
        #expect(s.averageBreakLength == TimeInterval(7 * 60))
    }

    @Test("a break is measured the way it is judged: the longer of its timestamps and dur_s")
    func measuredLikeTheVerdict() throws {
        let events: [LoggedEvent] = [
            .start(at: try Self.t(0)),
            .focus(at: try Self.t(0), app: Self.xcode, activity: .coding),
            .breakBegin(at: try Self.t(45), origin: .accepted),
            .breakEnd(at: try Self.t(50), origin: .accepted, durationSeconds: 9 * 60),
            .stop(at: try Self.t(60)),
        ]
        let s = Self.roll(events)
        #expect(s.breakCount == 1)
        #expect(s.totalBreakTime == 9 * 60)
    }

    @Test("a day without a break has no average, not a zero one")
    func noBreaksNoAverage() throws {
        let events: [LoggedEvent] = [
            .start(at: try Self.t(0)),
            .focus(at: try Self.t(0), app: Self.xcode, activity: .coding),
            .stop(at: try Self.t(30)),
        ]
        let s = Self.roll(events)
        #expect(s.breakCount == 0)
        #expect(s.totalBreakTime == 0)
        #expect(s.averageBreakLength == nil)
    }

    @Test("a summary written before the field existed still decodes, with the field at zero")
    func olderFileStillDecodes() throws {
        let older = """
        {"activeWorkByActivity":{"coding":5515},"applicationDistribution":{"com.example.editor":5515},
         "breakCount":1,"breakOpportunities":1,"breaksAbandoned":0,"breaksAccepted":1,
         "breaksIdleInferred":0,"breaksUserInitiated":0,"day":"2026-09-20","excludedOpportunities":0,
         "honoredOpportunities":1,"ignoredPromptCount":0,"longestContinuousSession":3000,
         "malformedLines":0,"notificationsDelivered":1,"sessionCount":1,"skippedBreakCount":0,
         "snoozeCount":1,"totalActiveWork":5515}
        """
        let decoded = try JSONDecoder().decode(DailySummary.self, from: Data(older.utf8))
        #expect(decoded.breakCount == 1)
        #expect(decoded.totalBreakTime == 0)
        #expect(decoded.averageBreakLength == 0)
        #expect(decoded.totalActiveWork == 5515)
        #expect(decoded.isPlausible)
    }

    @Test("the field round trips through the encoder")
    func roundTrips() throws {
        let summary = DailySummary(day: Self.day, totalActiveWork: 3600, breakCount: 2, totalBreakTime: 660)
        let data = try JSONEncoder().encode(summary)
        #expect(String(decoding: data, as: UTF8.self).contains("\"totalBreakTime\":660"))
        let back = try JSONDecoder().decode(DailySummary.self, from: data)
        #expect(back == summary)
        #expect(back.averageBreakLength == 330)
    }

    @Test("an impossible break total is implausible, like the other durations")
    func implausibleTotalIsRejected() {
        #expect(!DailySummary(day: Self.day, breakCount: 1, totalBreakTime: 200_000).isPlausible)
        #expect(!DailySummary(day: Self.day, breakCount: 1, totalBreakTime: -1).isPlausible)
        #expect(!DailySummary(day: Self.day, breakCount: 1, totalBreakTime: .nan).isPlausible)
        #expect(DailySummary(day: Self.day, breakCount: 1, totalBreakTime: 300).isPlausible)
    }
}
