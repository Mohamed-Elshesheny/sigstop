import Foundation
import Testing

@testable import SigstopCore
@testable import SigstopSensors

/// Tier 1b keeps the host and nothing else.
///
/// The privacy claim is structural rather than a promise: `host(from:)` is the only place
/// a remote URL is ever parsed, `URL` is a local inside it, and only `host` is returned.
/// These assert the claim the Settings copy makes, in the function that has to keep it.
struct BrowserHostTests {

    @Test("the path, the query and the fragment never come back")
    func onlyTheHostSurvives() {
        let cases = [
            "https://github.com/Mohamed-Elshesheny/sigstop": "github.com",
            "https://github.com/org/private-repo/issues/42?token=abc#c1": "github.com",
            "https://meet.google.com/abc-defg-hij": "meet.google.com",
            "http://localhost:3000/admin?key=secret": "localhost",
            "https://WWW.GitHub.com/Foo": "github.com",
            "https://user:pw@internal.example.com/secret": "internal.example.com",
        ]
        for (raw, expected) in cases {
            let host = AccessibilityCollector.host(from: raw)
            #expect(host == expected, "\(raw) gave \(host ?? "nil")")
        }
    }

    @Test("nothing but http and https is understood")
    func refusesEverythingElse() {
        for raw in [
            "file:///Users/someone/Documents/taxes.pdf",
            "/Users/someone/Documents/taxes.pdf",
            "mailto:someone@example.com",
            "javascript:alert(1)",
            "data:text/html;base64,PHNjcmlwdD4=",
            "chrome://settings/passwords",
            "",
            "not a url at all",
        ] {
            #expect(AccessibilityCollector.host(from: raw) == nil, "\(raw) should be refused")
        }
    }

    @Test("a file document still reads as a file and carries no host")
    func fileAndHostDoNotOverlap() {
        let file = "file:///Users/someone/code/sigstop/README.md"
        #expect(AccessibilityCollector.fileURL(from: file) != nil)
        #expect(AccessibilityCollector.host(from: file) == nil)

        let page = "https://github.com/Mohamed-Elshesheny/sigstop"
        #expect(AccessibilityCollector.fileURL(from: page) == nil)
        #expect(AccessibilityCollector.host(from: page) == "github.com")
    }
}

// MARK: - The host survives to the published observation

/// The read is only half the feature. What the panel draws is
/// `ActivityObservation.context.browserHost`, and that is built by
/// `ConfidenceEngine.observation`, which strips Tier 1 context from any observation whose
/// evidence happens not to cite Tier 1. Plain browsing cites only "Chrome is frontmost",
/// a Tier 0 fact, so the host the collector read correctly was thrown away on the way to
/// the panel, and the panel said "Google Chrome" while `--doctor` said "theboring.name".
struct BrowserHostPublicationTests {

    private static let chrome = AppIdentity(bundleID: BundleIDs.chrome, localizedName: "Google Chrome", pid: 103)

    private static func signals(host: String?, title: String?, tiers: SignalTierSet) -> SignalContext {
        SignalContext(
            now: Date(timeIntervalSince1970: 1_700_000_000),
            available: tiers,
            frontmost: chrome,
            input: InputActivity(idleSeconds: 3, source: .hidSystemState),
            windowTitle: title,
            browserHost: host
        )
    }

    private static func observe(_ signals: SignalContext) -> ActivityObservation {
        let classified = ProviderRegistry().classify(signals)
        return ConfidenceEngine.observation(
            verdict: classified.verdict,
            providerID: classified.providerID,
            signals: signals,
            concurrent: ConcurrentStates()
        )
    }

    @Test("a plain page keeps its host even though nothing about it is evidence")
    func plainPageKeepsHost() {
        let observation = Self.observe(
            Self.signals(host: "theboring.name", title: "The Boring Name", tiers: [.tier0, .tier1])
        )
        #expect(observation.activity == .browsing)
        #expect(observation.context.browserHost == "theboring.name")
        #expect(observation.evidence.allSatisfy { $0.tier == .tier0 })
    }

    @Test("a forge keeps its host too, and this one is cited")
    func forgeKeepsHost() {
        let observation = Self.observe(
            Self.signals(host: "github.com", title: "sigstop README", tiers: [.tier0, .tier1])
        )
        #expect(observation.activity == .browsing)
        #expect(observation.context.browserHost == "github.com")
        #expect(observation.evidence.contains { $0.tier == .tier1 })
    }

    @Test("with Tier 1 revoked the host is gone, whatever the collector said")
    func revokedTierDropsHost() {
        let observation = Self.observe(
            Self.signals(host: "theboring.name", title: "The Boring Name", tiers: [.tier0])
        )
        #expect(observation.activity == .browsing)
        #expect(observation.context.browserHost == nil)
    }
}
