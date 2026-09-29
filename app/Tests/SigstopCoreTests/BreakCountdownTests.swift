import Foundation
import Testing

@testable import SigstopCore

@Suite("The break countdown: whole minutes, then seconds in the last minute")
struct BreakCountdownTests {

    private static let start = Date(timeIntervalSince1970: 1_758_500_000)

    @Test("whole minutes above the last minute, rounded up so a fresh break shows its full length")
    func minutes() {
        #expect(BreakCountdown.reading(remaining: 300).text == "5 min")
        #expect(BreakCountdown.reading(remaining: 299).text == "5 min")
        #expect(BreakCountdown.reading(remaining: 241).text == "5 min")
        #expect(BreakCountdown.reading(remaining: 240).text == "4 min")
        #expect(BreakCountdown.reading(remaining: 61).text == "2 min")
    }

    @Test("seconds inside the last minute, and never below zero")
    func seconds() {
        #expect(BreakCountdown.reading(remaining: 60).text == "60 s")
        #expect(BreakCountdown.reading(remaining: 59).text == "59 s")
        #expect(BreakCountdown.reading(remaining: 1).text == "1 s")
        #expect(BreakCountdown.reading(remaining: 0).text == "0 s")
        #expect(BreakCountdown.reading(remaining: -4).text == "0 s")
    }

    @Test("a boundary reached a few milliseconds late, or with float noise, reads the same")
    func boundariesTolerateNoise() {
        #expect(BreakCountdown.reading(remaining: 240.0000001).unit == .minutes)
        #expect(BreakCountdown.reading(remaining: 240.0000001).value == 4)
        #expect(BreakCountdown.reading(remaining: 239.98).value == 4)
        #expect(BreakCountdown.reading(remaining: 60.0000001).unit == .seconds)
        #expect(BreakCountdown.reading(remaining: 59.98).value == 60)
    }

    @Test("the break's length reads in minutes")
    func length() {
        #expect(BreakCountdown.length(300).text == "5 min")
        #expect(BreakCountdown.length(60).text == "1 min")
        #expect(BreakCountdown.length(3600).text == "60 min")
    }

    @Test("a five minute break redraws 64 times, not 300")
    func redrawCount() {
        let end = Self.start.addingTimeInterval(300)
        let dates = BreakCountdown.redraws(from: Self.start, until: end)
        #expect(dates.count == 64)
        #expect(dates.first == Self.start.addingTimeInterval(60))
        #expect(dates.last == end)
    }

    @Test("every redraw changes the reading and nothing changes between redraws", arguments: [60, 300, 900, 3600, 277])
    func redrawsAreExactlyTheChanges(_ total: Int) {
        let end = Self.start.addingTimeInterval(TimeInterval(total))
        let scheduled = Set(
            BreakCountdown.redraws(from: Self.start, until: end)
                .map { Int($0.timeIntervalSince(Self.start).rounded()) }
        )
        var changes = Set<Int>()
        var previous = BreakCountdown.reading(remaining: TimeInterval(total))
        for elapsed in 1...total {
            let now = BreakCountdown.reading(remaining: TimeInterval(total - elapsed))
            if now != previous { changes.insert(elapsed) }
            previous = now
        }
        #expect(scheduled == changes, "total \(total): scheduled \(scheduled.sorted()) vs changes \(changes.sorted())")
    }

    @Test("redraws are ascending, strictly after now and never past the end")
    func redrawsAreOrdered() {
        let now = Self.start.addingTimeInterval(0.37)
        let end = Self.start.addingTimeInterval(277.9)
        let dates = BreakCountdown.redraws(from: now, until: end)
        #expect(dates == dates.sorted())
        #expect(dates.allSatisfy { $0 > now && $0 <= end })
        #expect(Set(dates).count == dates.count)
    }

    @Test("a break that has ended schedules nothing")
    func nothingAfterTheEnd() {
        #expect(BreakCountdown.redraws(from: Self.start, until: Self.start).isEmpty)
        #expect(BreakCountdown.redraws(from: Self.start, until: Self.start.addingTimeInterval(-5)).isEmpty)
    }
}
