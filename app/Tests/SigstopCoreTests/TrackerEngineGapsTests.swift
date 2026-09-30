import Foundation
import Testing

@testable import SigstopCore

@Suite("the session model and the engine, wired as the app wires them")
struct TrackerEngineGapsTests {

    typealias Bench = TrackerEngineBench

    @Test("a silent call that ends in plain idle is neither work nor a break")
    func silentCallThenIdle() {
        var bench = Bench()
        bench.work(minutes: 10)
        let before = bench.continuousWork
        bench.mic = true
        bench.away(minutes: 8)
        bench.mic = false
        var idle: TimeInterval = 8 * 60
        for _ in 0..<12 {
            idle += Bench.tick
            bench.tick(idle: idle)
        }
        bench.work(minutes: 1)

        #expect(bench.tracker.session.breakCount == 0)
        #expect(!bench.events.contains { if case .breakRecorded = $0 { return true } else { return false } })
        #expect(bench.continuousWork >= before, "the call reset the clock: \(bench.continuousWork)")
        #expect(bench.continuousWork <= before + 2 * 60, "the call was credited as work: \(bench.continuousWork)")
    }

    @Test("the wall clock jumping either way credits nothing, ends nothing and fires nothing", arguments: [
        3600.0, -3600.0, 20 * 3600.0, -20 * 3600.0,
    ])
    func wallClockJumps(jump: TimeInterval) {
        var bench = Bench()
        let prompt = bench.workUntilPrompt()
        #expect(prompt != nil)
        let cycle = bench.state.openCycle
        let work = bench.continuousWork

        bench.time.setWallClock(by: jump)
        let produced = bench.tick()
        #expect(bench.events.contains(.wallClockSkewIgnored(seconds: jump)))
        #expect(Bench.prompts(produced).isEmpty)
        #expect(Bench.closes(produced).isEmpty)
        #expect(bench.state.openCycle == cycle)
        #expect(bench.tracker.sessionCount == 1)
        #expect(abs(bench.continuousWork - work) <= Bench.tick, "a wall jump moved the work clock")
    }
}
