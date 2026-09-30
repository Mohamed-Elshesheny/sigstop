import Foundation
import Testing

@testable import SigstopCore
@testable import SigstopSensors

struct ProviderHonestyTests {

    static func app(_ bundleID: String, _ name: String) -> AppIdentity {
        AppIdentity(bundleID: bundleID, localizedName: name, pid: 201)
    }

    static func signals(
        _ app: AppIdentity,
        title: String? = nil,
        tiers: SignalTierSet = [.tier0, .tier1]
    ) -> SignalContext {
        SignalContext(
            now: Date(timeIntervalSince1970: 1_700_000_000),
            available: tiers,
            frontmost: app,
            input: InputActivity(idleSeconds: 3, source: .hidSystemState),
            windowTitle: title
        )
    }

    @Test("Mail and Messages are communication, not a conferencing app in front")
    func mailIsNotAConferencingApp() {
        for app in [Self.app(BundleIDs.mail, "Mail"), Self.app(BundleIDs.messages, "Messages")] {
            let verdict = CommunicationProvider().observe(Self.signals(app, title: "Inbox"))
            #expect(verdict?.activity == .communication)
            #expect(verdict?.concurrentHints.meetingEvidence.contains { $0.id.rawValue == "meeting.appFrontmost" } == false)
        }
        let subject = CommunicationProvider().observe(
            Self.signals(Self.app(BundleIDs.mail, "Mail"), title: "Zoom Meeting")
        )
        #expect(subject?.concurrentHints.meetingEvidence.isEmpty == true, "a mail subject is not a call")
        let slack = CommunicationProvider().observe(Self.signals(Self.app(BundleIDs.slack, "Slack")))
        #expect(slack?.concurrentHints.meetingEvidence.contains { $0.id.rawValue == "meeting.appFrontmost" } == true)
    }
}
