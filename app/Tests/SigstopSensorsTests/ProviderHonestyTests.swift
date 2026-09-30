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

    static func citesAChannel(_ app: AppIdentity, _ title: String) -> Bool {
        let verdict = CommunicationProvider().observe(Self.signals(app, title: title))
        return verdict?.evidence.contains { $0.id.rawValue == "communication.title" } == true
    }

    @Test("a mail subject is never read as a channel or a conversation")
    func mailSubjectsAreNotChannels() {
        let mail = Self.app(BundleIDs.mail, "Mail")
        let messages = Self.app(BundleIDs.messages, "Messages")
        for title in ["Roadmap review", "Re: admin access", "Invoice #4411", "#general"] {
            #expect(!Self.citesAChannel(mail, title), "\(title)")
            #expect(!Self.citesAChannel(messages, title), "\(title)")
        }
        let slack = Self.app(BundleIDs.slack, "Slack")
        for title in ["Roadmap review - Acme - Slack", "admin tools - Acme - Slack", "Invoice #4411 - Slack"] {
            #expect(!Self.citesAChannel(slack, title), "\(title)")
        }
    }

    @Test("the forms Slack and Discord use for a channel or a DM are cited")
    func channelFormsAreCited() {
        let slack = Self.app(BundleIDs.slack, "Slack")
        #expect(Self.citesAChannel(slack, "general (Channel) - Acme - Slack"))
        #expect(Self.citesAChannel(slack, "Sam Lee (DM) - Acme - Slack"))
        let discord = Self.app(BundleIDs.discord, "Discord")
        #expect(Self.citesAChannel(discord, "#general | Rust Community - Discord"))
        #expect(!Self.citesAChannel(discord, "Friends - Discord"))
        #expect(!Self.citesAChannel(discord, "#4411 | Server - Discord"))
    }
}
