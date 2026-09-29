import Foundation
import Testing

@testable import SigstopCore

@Suite("Skip needs a moment")
struct SkipGuardTests {

    @Test("skip arms a few seconds after the panel appears, long enough to stop a reflex")
    func armsAfterAMoment() {
        let policy = BreakPolicy()
        #expect(policy.skipArmsAfter >= 2)
        #expect(policy.skipArmsAfter <= 5)
    }

    @Test("a prompt can always be skipped long before it counts as ignored")
    func wellInsideThePromptTimeout() {
        let policy = BreakPolicy()
        #expect(policy.skipArmsAfter * 10 < policy.promptTimeout)
    }

    @Test("the guard is not a setting and survives every settings shape")
    func notASetting() {
        var settings = SigstopSettings.default
        settings.breakDurationMinutes = 1
        settings.snoozeMinutes = 20
        settings.maxNotificationsPerDay = 1
        let tuned = BreakPolicy(settings: settings)
        #expect(tuned.skipArmsAfter == BreakPolicy().skipArmsAfter)
    }
}
