import Foundation
import Testing

@testable import SigstopCore

@Suite("text from outside the app is cleaned before it reaches a prompt")
struct OutsideTextTests {

    @Test("ordinary names pass through unchanged")
    func ordinaryNames() {
        for name in ["main", "feature/login-flow", "sigstop", "Visual Studio Code", "café-ü", "日本語ブランチ", "fix-🐛"] {
            #expect(SlotResolver.outsideText(name) == name)
        }
    }

    @Test("control, bidi, zero-width and line-separator characters are dropped")
    func invisibleCharactersAreDropped() {
        #expect(SlotResolver.outsideText("main\u{202E}gnp.exe") == "maingnp.exe")
        #expect(SlotResolver.outsideText("a\u{2028}b\u{2029}c") == "abc")
        #expect(SlotResolver.outsideText("zero\u{200B}width\u{FEFF}") == "zerowidth")
        #expect(SlotResolver.outsideText("esc\u{1B}[2Kcode") == "esc[2Kcode")
        #expect(SlotResolver.outsideText("tab\tand\nnewline") == "tabandnewline")
    }

    @Test("runs of whitespace become one space, and none is left at either end")
    func whitespaceCollapses() {
        #expect(SlotResolver.outsideText("  your\u{00A0}\u{00A0}session   expired  ") == "your session expired")
    }

    @Test("a long name is cut with an ellipsis, and nothing invisible survives as the whole name")
    func lengthAndEmptiness() {
        let long = String(repeating: "x", count: 500)
        let cut = SlotResolver.outsideText(long)
        #expect(cut?.count == SlotResolver.outsideTextLimit)
        #expect(cut?.hasSuffix("…") == true)
        #expect(SlotResolver.outsideText("\u{200B}\u{2028}\u{202E}") == nil)
        #expect(SlotResolver.outsideText("") == nil)
    }

    @Test("a flood of combining marks cannot make one character arbitrarily tall")
    func combiningFlood() {
        let flood = "a" + String(repeating: "\u{0301}", count: 100_000)
        let cleaned = SlotResolver.outsideText(flood)
        #expect((cleaned?.unicodeScalars.count ?? 0) <= SlotResolver.outsideTextLimit * 4)
    }

    @Test("a hostile branch reaches the slot table cleaned")
    func branchSlotIsCleaned() {
        let hostile = "ALERT\u{00A0}session\u{00A0}expired" + String(repeating: "\u{2028}x", count: 105) + "end"
        let developer = DeveloperContext(
            timestamp: Date(timeIntervalSince1970: 1_758_500_000),
            application: AppIdentity(bundleID: "com.microsoft.VSCode", localizedName: "Code", pid: 1),
            activity: .coding,
            confidence: Confidence(0.8),
            context: ActivityContext(projectName: "repo\u{202E}", branch: hostile),
            continuousWork: 3600
        )
        let table = SlotResolver().table(for: MessageContext(developer: developer, escalation: .first))
        let branch = table[.branch]?.text ?? ""
        #expect(!branch.unicodeScalars.contains { $0 == "\u{2028}" })
        #expect(branch.count <= SlotResolver.outsideTextLimit)
        #expect(table[.project]?.text == "repo")
    }
}
