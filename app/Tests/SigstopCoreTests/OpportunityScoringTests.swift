import Foundation
import Testing

@testable import SigstopCore

/// One break answers one opportunity, and never two.
///
/// Reported from the owner's own stored summaries: `breakCount: 1` beside
/// `honoredOpportunities: 2`, and on the day before, six breaks beside seven honoured.
/// The panel read the inflated number under "kept", and the badge for a day where every
/// break offered was taken unlocked on a day where they were not, because that badge asks
/// whether honoured equals asked.
///
/// The cause was that each opportunity asked whether *any* qualifying break started inside
/// its compliance window, so two opportunities opened close together were both answered by
/// the same single break.
@Suite("One break answers one opportunity")
struct OpportunityScoringTests {

    private static let day = Date(timeIntervalSince1970: 1_758_400_000)

    private static func event(_ kind: EventKind, _ offset: TimeInterval, cycle: Int? = nil) -> LoggedEvent {
        LoggedEvent(at: day.addingTimeInterval(offset), kind: kind, cycle: cycle)
    }

    /// Two opportunities a minute apart, and one break long enough to qualify. The break
    /// falls inside both compliance windows.
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
        let totals = DailyRollup.scoreOpportunities(
            Self.twoOpportunitiesOneBreak(),
            dayEnd: Self.day.addingTimeInterval(24 * 3600),
            policy: RollupPolicy()
        )
        #expect(totals.total == 2)
        #expect(totals.honored == 1, "one break honoured \(totals.honored) opportunities")
    }

    @Test("Honoured never exceeds the breaks that actually happened")
    func honouredNeverExceedsBreaks() {
        let events = Self.twoOpportunitiesOneBreak()
        let totals = DailyRollup.scoreOpportunities(
            events, dayEnd: Self.day.addingTimeInterval(24 * 3600), policy: RollupPolicy()
        )
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
        let totals = DailyRollup.scoreOpportunities(
            events, dayEnd: Self.day.addingTimeInterval(24 * 3600), policy: RollupPolicy()
        )
        #expect(totals.total == 2)
        #expect(totals.honored == 2)
    }
}
