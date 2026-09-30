import Foundation
import Testing

@testable import SigstopCore

@Suite("a time zone change without a relaunch")
struct ZoneChangeTests {

    private static func calendar(hoursFromGMT: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: hoursFromGMT * 3600) ?? .gmt
        return calendar
    }

    private static let start: Date = {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        return utc.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 7)) ?? .distantPast
    }()

    private func sample(_ calendar: Calendar) -> TickSample {
        TickSample(
            idleSeconds: 0,
            application: AppIdentity(bundleID: "com.apple.dt.Xcode", localizedName: "Xcode", pid: 1),
            activity: .coding,
            confidence: Confidence(0.9),
            calendar: calendar
        )
    }

    private func dayResets(_ events: [SessionEvent]) -> Int {
        events.filter { if case .clockReset(.dayBoundary) = $0 { return true } else { return false } }.count
    }

    @Test("the day rolls over at 04:00 in the zone the Mac is in now, and not on the tick the zone changed")
    func boundaryFollowsTheNewZone() {
        let time = MutableTimeSource(now: Self.start, monotonic: 0)
        var policy = BreakPolicy()
        policy.tickInterval = 5
        policy.tickTolerance = 5
        let before = Self.calendar(hoursFromGMT: 3)
        let after = Self.calendar(hoursFromGMT: -7)
        var tracker = SessionTracker(time: time, policy: policy, calendar: before)

        time.advance(by: 5)
        #expect(dayResets(tracker.tick(sample(after))) == 0, "a new zone is not a new day")

        var resetAt: [Date] = []
        for _ in 0..<(5 * 3600 / 5) {
            time.advance(by: 5)
            if dayResets(tracker.tick(sample(after))) > 0 { resetAt.append(time.now) }
        }

        let boundary = Self.start.addingTimeInterval(4 * 3600)
        #expect(resetAt.count == 1)
        #expect(resetAt.first.map { $0 >= boundary && $0 < boundary.addingTimeInterval(5.001) } == true)
    }

    @Test("a sample without a calendar keeps the one the tracker was built with")
    func noCalendarKeepsTheOriginal() {
        let time = MutableTimeSource(now: Self.start, monotonic: 0)
        var policy = BreakPolicy()
        policy.tickInterval = 5
        policy.tickTolerance = 5
        var tracker = SessionTracker(time: time, policy: policy, calendar: Self.calendar(hoursFromGMT: 3))
        var resets = 0
        for _ in 0..<(5 * 3600 / 5) {
            time.advance(by: 5)
            resets += dayResets(tracker.tick(TickSample(idleSeconds: 0, activity: .coding)))
        }
        #expect(resets == 0, "04:00 at GMT+3 is eighteen hours away")
    }
}
