import Foundation
import Testing

@testable import SigstopCore

@Suite("a short sleep is an absence, not time spent ignoring a prompt")
struct ShortSleepTests {

    typealias Bench = TrackerEngineBench

    @Test("three minutes asleep with a prompt up is not an ignored prompt")
    func promptUpThroughAShortSleep() {
        var bench = Bench()
        let prompt = bench.workUntilPrompt()
        #expect(prompt != nil)

        var produced = bench.sleep(for: 3 * 60)
        produced += bench.tick()
        #expect(Bench.ignoredPrompts(produced) == 0, "the lid was shut for the whole timeout")
        #expect(bench.state.openCycle != nil, "a short sleep keeps the cycle")
    }

    @Test("four and a half minutes asleep does not climb the ladder")
    func ladderThroughAShortSleep() throws {
        var bench = Bench()
        let prompt = bench.workUntilPrompt()
        #expect(prompt != nil)
        let ignored = bench.workUntil(limitMinutes: 5) { Bench.ignoredPrompts($0) > 0 }
        _ = try #require(ignored)

        var produced = bench.sleep(for: 4.5 * 60)
        produced += bench.work(minutes: 1)
        #expect(Bench.prompts(produced).isEmpty, "got \(Bench.prompts(produced).map(\.signal))")
        guard case .ignored(let e) = bench.state else {
            Issue.record("expected the ladder to resume, got \(bench.state.name)"); return
        }
        #expect(e.ladderElapsed < 2 * 60, "the sleep was charged to the ladder: \(e.ladderElapsed)")
    }
}
