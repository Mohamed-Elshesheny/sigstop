import Foundation
import Testing

@testable import SigstopCore

@Suite("One break answers one opportunity")
struct OpportunityScoringTests {

    private static let day = Date(timeIntervalSince1970: 1_758_400_000)

    private static func event(_ kind: EventKind, _ offset: TimeInterval, cycle: Int? = nil) -> LoggedEvent {
        LoggedEvent(at: day.addingTimeInterval(offset), kind: kind, cycle: cycle)
    }

    private static func score(_ events: [LoggedEvent]) -> DailyRollup.OpportunityTotals {
        let policy = RollupPolicy()
        let spans = DailyRollup.breakSpans(events, dayEnd: day.addingTimeInterval(24 * 3600), policy: policy)
        return DailyRollup.scoreOpportunities(events, spans: spans, policy: policy)
    }

    private static func twoOpportunitiesOneBreak() -> [LoggedEvent] {
        [
            event(.breakOpen, 0, cycle: 0),
            event(.breakPrompt, 0, cycle: 0),
            event(.breakOpen, 60, cycle: 1),
            event(.breakPrompt, 60, cycle: 1),
            event(.breakBegin, 120, cycle: 1),
            event(.breakEnd, 120 + 6 * 60, cycle: 1),
        ]
    }

    @Test("Two opportunities and one break is one honoured, not two")
    func oneBreakIsNotTwo() {
        let totals = Self.score(Self.twoOpportunitiesOneBreak())
        #expect(totals.total == 2)
        #expect(totals.honored == 1, "one break honoured \(totals.honored) opportunities")
    }

    @Test("Honoured never exceeds the breaks that actually happened")
    func honouredNeverExceedsBreaks() {
        let events = Self.twoOpportunitiesOneBreak()
        let totals = Self.score(events)
        let breaks = events.filter { $0.kind == .breakBegin }.count
        #expect(totals.honored <= breaks)
    }

    @Test("Two breaks for two opportunities still honour both")
    func twoBreaksHonourTwo() {
        let events: [LoggedEvent] = [
            Self.event(.breakOpen, 0, cycle: 0),
            Self.event(.breakPrompt, 0, cycle: 0),
            Self.event(.breakBegin, 30, cycle: 0),
            Self.event(.breakEnd, 30 + 6 * 60, cycle: 0),
            Self.event(.breakOpen, 3600, cycle: 1),
            Self.event(.breakPrompt, 3600, cycle: 1),
            Self.event(.breakBegin, 3630, cycle: 1),
            Self.event(.breakEnd, 3630 + 6 * 60, cycle: 1),
        ]
        let totals = Self.score(events)
        #expect(totals.total == 2)
        #expect(totals.honored == 2)
    }
}
