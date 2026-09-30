import Foundation
import Testing

@testable import SigstopCore
@testable import SigstopSensors

struct MeetingEvidenceTests {

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let vscode = AppIdentity(bundleID: BundleIDs.vscode, localizedName: "Code", pid: 201)
    private static let slack = AppIdentity(bundleID: BundleIDs.slack, localizedName: "Slack", pid: 202)
    private static let mail = AppIdentity(bundleID: BundleIDs.mail, localizedName: "Mail", pid: 203)

    private static func states(
        front: AppIdentity,
        running: Set<String>,
        mic: AudioInputState = .notRunning,
        title: String? = nil,
        tiers: SignalTierSet = [.tier0, .tier1]
    ) -> (ConcurrentStates, [Evidence]) {
        let signals = SignalContext(
            now: now,
            available: tiers,
            frontmost: front,
            runningBundleIDs: running.union([front.bundleID].compactMap { $0 }),
            input: InputActivity(idleSeconds: 2, source: .hidSystemState),
            audioInput: mic,
            windowTitle: title
        )
        let hints = ProviderRegistry().classify(signals).verdict.concurrentHints
        let evidence = ContextEngine.meetingEvidence(signals, hints: hints)
        let (states, _) = ContextEngine.concurrentStates(signals, hints: hints, tiers: tiers)
        return (states, evidence)
    }

    @Test("three conferencing apps open in the background are not a meeting")
    func backgroundAppsAreNotAMeeting() {
        let (states, evidence) = Self.states(
            front: Self.vscode,
            running: [BundleIDs.slack, BundleIDs.zoom, BundleIDs.teams]
        )
        #expect(!states.inMeeting, "at \(states.meetingConfidence.value) with no microphone")
        #expect(evidence.filter { $0.id.rawValue == "meeting.appRunning" }.count == 1)
    }

    @Test("a chat channel in front with Zoom open is not a meeting")
    func chatChannelIsNotAMeeting() {
        let (states, _) = Self.states(
            front: Self.slack,
            running: [BundleIDs.zoom],
            title: "general (Channel) - Acme - Slack"
        )
        #expect(!states.inMeeting, "at \(states.meetingConfidence.value) with no microphone")
    }

    @Test("reading mail with Slack and Zoom open is not a meeting")
    func mailIsNotAMeeting() {
        let (states, _) = Self.states(front: Self.mail, running: [BundleIDs.slack, BundleIDs.zoom])
        #expect(!states.inMeeting, "at \(states.meetingConfidence.value) with no microphone")
    }

    @Test("a live microphone with a conferencing app open still reads as a meeting")
    func micAndAppIsStillAMeeting() {
        let (states, _) = Self.states(
            front: Self.vscode,
            running: [BundleIDs.zoom, BundleIDs.slack, BundleIDs.teams],
            mic: .running
        )
        #expect(states.inMeeting)
        #expect(states.meetingConfidence.value < 0.8, "the band for this is 0.75, not more")
    }

    @Test("one line names every conferencing app that is open")
    func oneLineNamesThemAll() {
        let (_, evidence) = Self.states(
            front: Self.vscode,
            running: [BundleIDs.slack, BundleIDs.zoom, BundleIDs.teams]
        )
        let line = evidence.first { $0.id.rawValue == "meeting.appRunning" }
        #expect(line?.summary == "Microsoft Teams, Slack and Zoom are running")

        let (_, alone) = Self.states(front: Self.vscode, running: [BundleIDs.zoom])
        #expect(alone.first { $0.id.rawValue == "meeting.appRunning" }?.summary == "Zoom is running")
    }
}
