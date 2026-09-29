import Foundation
import Testing

@testable import SigstopCore
@testable import SigstopSensors

@Suite("a watched tool that has just gone is a seam")
struct CommandWatchTests {

    private let terminal: pid_t = 102
    private let editor: pid_t = 101
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func scan(
        matched: Set<ToolToken> = [],
        children: Set<ToolToken> = [],
        traced: Bool = false,
        tracedElsewhere: Bool = false,
        after seconds: TimeInterval = 0
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            matchedTools: matched.union(children),
            childrenOfFrontmost: children,
            tracedUnderFrontmost: traced,
            tracedElsewhere: tracedElsewhere,
            capturedAt: start.addingTimeInterval(seconds)
        )
    }

    private func watching(
        _ children: Set<ToolToken>,
        traced: Bool = false,
        under pid: pid_t
    ) -> CommandWatch {
        var watch = CommandWatch()
        _ = watch.observe(scan(children: children, traced: traced), frontmostPID: pid)
        _ = watch.observe(scan(children: children, traced: traced, after: 5), frontmostPID: pid)
        return watch
    }

    @Test("a test runner started by the app in front that is gone at the next scan")
    func testRunnerGone() {
        var watch = watching([.xctest], under: terminal)
        let finished = watch.observe(scan(after: 10), frontmostPID: terminal)

        #expect(finished?.seam == .terminalCommandFinished)
        #expect(finished?.tool == .xctest)
        #expect(finished?.noticedAt == start.addingTimeInterval(10))
        #expect(
            finished?.summary
                == "a test run just finished, xctest was started by the app you are in and is gone"
        )
        #expect(finished?.evidence.allSatisfy { $0.tier == .tier2 } == true)
    }

    @Test("a tool seen in a single scan, like the ssh a git fetch spawns, is not your command")
    func aSingleSightingIsNotASeam() {
        var watch = CommandWatch()
        _ = watch.observe(scan(), frontmostPID: terminal)
        #expect(watch.observe(scan(children: [.ssh], after: 5), frontmostPID: terminal) == nil)
        #expect(watch.observe(scan(after: 10), frontmostPID: terminal) == nil)

        var settled = CommandWatch()
        _ = settled.observe(scan(children: [.ssh]), frontmostPID: terminal)
        #expect(settled.observe(scan(children: [.ssh], after: 5), frontmostPID: terminal) == nil)
        #expect(settled.observe(scan(after: 10), frontmostPID: terminal)?.tool == .ssh)
    }

    @Test("the confidence is honest: never certain, and never above the debugging ceiling")
    func confidenceIsCapped() throws {
        var watch = watching([.debugserver], traced: true, under: editor)
        let observed = watch.observe(scan(after: 10), frontmostPID: editor)
        let finished = try #require(observed)

        #expect(finished.evidence.count == 2)
        #expect(finished.confidence < Confidence.certain)
        #expect(finished.confidence.value <= CommandWatch.ceiling)
        #expect(finished.confidence.value >= 0.85)
        #expect(Probability.combine(finished.evidence).value > CommandWatch.ceiling)
    }

    @Test("each group of tools gets a sentence a person can read")
    func summariesReadAsSentences() {
        let expected: [(ToolToken, String)] = [
            (.debugserver, "a debug session just ended, debugserver"),
            (.lldb, "a debug session just ended, lldb"),
            (.vim, "you just left vim, vim"),
            (.claudeCLI, "claude just exited, claude"),
            (.ssh, "your ssh session just ended, ssh"),
        ]
        for (tool, prefix) in expected {
            var watch = watching([tool], under: terminal)
            let finished = watch.observe(scan(after: 10), frontmostPID: terminal)
            #expect(finished?.tool == tool)
            #expect(finished?.summary.hasPrefix(prefix) == true, "\(tool)")
            #expect(finished?.summary.contains("\u{2014}") == false)
        }
    }

    @Test("a tool that was never under the app in front is somebody else's command")
    func aNameElsewhereIsNotYourSeam() {
        var watch = CommandWatch()
        _ = watch.observe(scan(matched: [.lldb]), frontmostPID: editor)
        _ = watch.observe(scan(matched: [.lldb], after: 5), frontmostPID: editor)
        #expect(watch.observe(scan(after: 10), frontmostPID: editor) == nil)
    }

    @Test("the same tool still running elsewhere decides nothing once the app in front has changed")
    func stillRunningElsewhereAfterAnAppSwitch() {
        var watch = watching([.xctest], under: terminal)
        #expect(watch.observe(scan(matched: [.xctest], after: 10), frontmostPID: editor) == nil)

        var same = watching([.xctest], under: terminal)
        let finished = same.observe(scan(matched: [.xctest], after: 10), frontmostPID: terminal)
        #expect(finished?.tool == .xctest)
    }

    @Test("a tool gone from under the previous app is a seam even after switching apps")
    func goneAfterAnAppSwitch() {
        var watch = watching([.xctest], under: terminal)
        let finished = watch.observe(scan(after: 10), frontmostPID: editor)
        #expect(finished?.tool == .xctest)
    }

    @Test("the debugger flag clearing under the same app is a seam, under a different app it is not")
    func tracedFlagClearing() {
        var same = CommandWatch()
        _ = same.observe(scan(traced: true), frontmostPID: editor)
        let finished = same.observe(scan(after: 5), frontmostPID: editor)
        #expect(finished?.tool == nil)
        #expect(finished?.evidence.map(\.id.rawValue) == ["process.debugSessionEnded"])
        #expect(finished?.confidence.value ?? 1 < 0.95)

        var switched = CommandWatch()
        _ = switched.observe(scan(traced: true), frontmostPID: editor)
        #expect(switched.observe(scan(after: 5), frontmostPID: terminal) == nil)

        var elsewhere = CommandWatch()
        _ = elsewhere.observe(scan(tracedElsewhere: true), frontmostPID: editor)
        #expect(elsewhere.observe(scan(after: 5), frontmostPID: editor) == nil)
    }

    @Test("a tool appearing, or staying, is not a seam")
    func appearingIsNotASeam() {
        var watch = CommandWatch()
        _ = watch.observe(scan(), frontmostPID: terminal)
        #expect(watch.observe(scan(children: [.xctest], after: 5), frontmostPID: terminal) == nil)
        #expect(watch.observe(scan(children: [.xctest], after: 10), frontmostPID: terminal) == nil)
        #expect(watch.observe(scan(children: [.xctest], after: 15), frontmostPID: terminal) == nil)
    }

    @Test("a memoized scan handed back twice is one sighting, not two")
    func theMemoIsNotASecondSighting() {
        var watch = CommandWatch()
        let first = scan(children: [.xctest])
        _ = watch.observe(first, frontmostPID: terminal)
        #expect(watch.observe(first, frontmostPID: terminal) == nil)
        #expect(watch.observe(scan(after: 5), frontmostPID: terminal) == nil)

        var real = CommandWatch()
        _ = real.observe(first, frontmostPID: terminal)
        #expect(real.observe(first, frontmostPID: terminal) == nil)
        #expect(real.observe(scan(children: [.xctest], after: 5), frontmostPID: terminal) == nil)
        #expect(real.observe(first, frontmostPID: terminal) == nil)
        #expect(real.observe(scan(after: 10), frontmostPID: terminal)?.tool == .xctest)
    }

    @Test("a scan that was skipped in between means the next one has nothing to compare against")
    func aSkippedScanResetsTheWatch() {
        var watch = watching([.xctest], under: terminal)
        #expect(watch.observe(nil, frontmostPID: terminal) == nil)
        #expect(watch.observe(scan(after: 10), frontmostPID: terminal) == nil)

        var seenOnceAgain = watching([.xctest], under: terminal)
        _ = seenOnceAgain.observe(nil, frontmostPID: terminal)
        _ = seenOnceAgain.observe(scan(children: [.xctest], after: 10), frontmostPID: terminal)
        #expect(seenOnceAgain.observe(scan(after: 15), frontmostPID: terminal) == nil)
    }

    @Test("a scan older than the gap the tick loop can leave is stale, not a seam")
    func aStaleScanIsNotASeam() {
        var watch = watching([.xctest], under: terminal)
        #expect(
            watch.observe(scan(after: 5 + CommandWatch.maxGap + 1), frontmostPID: terminal) == nil
        )

        var fresh = watching([.xctest], under: terminal)
        #expect(fresh.observe(scan(after: 5 + CommandWatch.maxGap), frontmostPID: terminal) != nil)
    }

    @Test("the first tool by name is the one reported when two are gone at once")
    func twoGoneAtOnce() {
        var watch = watching([.xctest, .debugserver], under: editor)
        let finished = watch.observe(scan(after: 10), frontmostPID: editor)
        #expect(finished?.tool == .debugserver)
        #expect(finished?.evidence.count == 1)
    }
}
