import Foundation
import Testing

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
