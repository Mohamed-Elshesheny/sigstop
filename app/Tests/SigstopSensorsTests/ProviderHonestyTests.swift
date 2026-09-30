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

    @Test("a Meet call is its own tab title, not a page that mentions Google Meet")
    func meetTitleIsTheCallNotTheWord() {
        for title in ["Meet - abc-defg-hij", "Meet \u{2013} abc-defg-hij", "Meet - Weekly sync"] {
            #expect(BrowserTitlePatterns.isMeeting(title), "\(title)")
        }
        for title in [
            "google meet - Google Search", "Google Meet", "Google Meet - Online video calls",
            "How to meet - Wikipedia", "meet - the team",
        ] {
            #expect(!BrowserTitlePatterns.isMeeting(title), "\(title)")
        }
    }

    @Test("every app in the fallback table reaches the fallback, so no entry is shadowed")
    func fallbackCategoriesAreReachable() {
        for bundleID in GenericProvider.categories.keys.sorted() {
            let first = ProviderRegistry().resolve(for: Self.app(bundleID, bundleID)).first
            #expect(first?.identifier == GenericProvider.identifier, "\(bundleID)")
        }
    }

    static func classify(
        _ app: AppIdentity,
        title: String?,
        matched: Set<ToolToken>,
        children: Set<ToolToken>,
        traced: Bool = false
    ) -> ActivityObservation {
        let signals = SignalContext(
            now: Date(timeIntervalSince1970: 1_700_000_000),
            available: [.tier0, .tier1, .tier2],
            frontmost: app,
            input: InputActivity(idleSeconds: 3, source: .hidSystemState),
            windowTitle: title,
            processes: ProcessSnapshot(
                matchedTools: matched,
                childrenOfFrontmost: children,
                tracedUnderFrontmost: traced,
                tracedElsewhere: false,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        let classified = ProviderRegistry().classify(signals)
        return ConfidenceEngine.observation(
            verdict: classified.verdict,
            providerID: classified.providerID,
            signals: signals,
            concurrent: ConcurrentStates()
        )
    }

    static let cursor = app(BundleIDs.cursor, "Cursor")
    static let terminal = app(BundleIDs.terminal, "Terminal")

    @Test("an AI CLI beside a debugger in Cursor is coding, not a guess between the two")
    func cursorDebuggerAndAIDegrade() {
        let seen = Self.classify(
            Self.cursor, title: "main.swift \u{2014} sigstop",
            matched: [.claudeCLI, .lldb], children: [.claudeCLI, .lldb], traced: true
        )
        #expect(seen.activity == .coding)
        #expect(seen.confidence.value <= ConfidenceEngine.degradedCeiling)
        #expect(seen.evidence.contains { $0.id.rawValue == "process.aiCLI" })
        #expect(seen.evidence.contains { $0.id.rawValue == "process.traced" })
    }

    @Test("an AI CLI beside a debugger in a terminal is coding, and both are cited")
    func terminalDebuggerAndAIDegrade() {
        let seen = Self.classify(
            Self.terminal, title: "zsh",
            matched: [.claudeCLI, .lldb], children: [.claudeCLI, .lldb], traced: true
        )
        #expect(seen.activity == .coding)
        #expect(seen.confidence.value <= ConfidenceEngine.degradedCeiling)
        #expect(seen.evidence.contains { $0.id.rawValue == "process.aiCLI" })
        #expect(seen.evidence.contains { $0.id.rawValue == "process.traced" })
    }

    @Test("an AI CLI while Cursor has a prose file open is coding, not AI coding")
    func cursorDocsAndAIDegrade() {
        let seen = Self.classify(
            Self.cursor, title: "README.md \u{2014} sigstop",
            matched: [.claudeCLI], children: [.claudeCLI]
        )
        #expect(seen.activity == .coding)
        #expect(seen.evidence.contains { $0.id.rawValue == "title.docExtension" })
        #expect(seen.evidence.contains { $0.id.rawValue == "process.aiCLI" })
    }

    @Test("an AI CLI with nothing rival beside it is still AI coding")
    func aiAloneIsStillAICoding() {
        let cursor = Self.classify(
            Self.cursor, title: "main.swift \u{2014} sigstop", matched: [.claudeCLI], children: [.claudeCLI]
        )
        #expect(cursor.activity == .aiCoding)
        let terminal = Self.classify(Self.terminal, title: "zsh", matched: [.claudeCLI], children: [.claudeCLI])
        #expect(terminal.activity == .aiCoding)
        let elsewhere = Self.classify(
            Self.terminal, title: "zsh", matched: [.claudeCLI, .lldb], children: [.claudeCLI]
        )
        #expect(elsewhere.activity == .aiCoding, "a debugger in some other app is not a rival in this one")
    }

    @Test("a notes app or a text editor is never shown as coding")
    func notesAppsAreNotCoding() {
        let apps = [
            Self.app(BundleIDs.notion, "Notion"), Self.app(BundleIDs.obsidian, "Obsidian"),
            Self.app("com.apple.Notes", "Notes"), Self.app("com.apple.TextEdit", "TextEdit"),
        ]
        for app in apps {
            for tiers: SignalTierSet in [[.tier0], [.tier0, .tier1, .tier2]] {
                let signals = Self.signals(app, title: "Groceries", tiers: tiers)
                let classified = ProviderRegistry().classify(signals)
                let observation = ConfidenceEngine.observation(
                    verdict: classified.verdict,
                    providerID: classified.providerID,
                    signals: signals,
                    concurrent: ConcurrentStates()
                )
                let shown = classified.verdict.labelOverride ?? observation.claimableActivity.displayName
                #expect(shown != Activity.coding.displayName, "\(app.localizedName) was shown as \(shown)")
            }
        }
    }
}
