import Foundation
import Testing

@testable import SigstopCore

@Suite("the snooze cap holds across an ignored prompt")
struct SnoozeCapTests {

    @Test("letting a prompt time out does not hand back the snoozes already used")
    func capSurvivesAnIgnore() {
        let settings = EngineHarness.ownerSettings
        let cap = settings.maxSnoozesPerBreak
        var session = EngineHarness.Session(settings: settings)
        var acceptedPerCycle: [CycleID: Int] = [:]
        var offeredPastCap: [[TimeInterval]] = []

        for _ in 0..<8 {
            let delivered = session.stepToPrompt(limit: 4000)
            guard let request = delivered.compactMap({ effect -> PromptRequest? in
                if case .deliverPrompt(let r) = effect { return r } else { return nil }
            }).first else { break }
            if acceptedPerCycle[request.cycle, default: 0] >= cap {
                offeredPastCap.append(request.snoozeOffered)
            }

            session.step(untilLimit: 400) { effects in
                effects.contains { if case .recordIgnoredPrompt = $0 { return true } else { return false } }
            }
            session.step(action: .snooze)
            if session.driver.state.name == "snoozed", let cycle = session.driver.state.openCycle {
                acceptedPerCycle[cycle, default: 0] += 1
            }
        }

        #expect(!acceptedPerCycle.isEmpty, "no snooze was ever accepted, so nothing was tested")
        for (cycle, count) in acceptedPerCycle {
            #expect(count <= cap, "cycle \(cycle) accepted \(count) snoozes, the cap is \(cap)")
        }
        let allEmpty = offeredPastCap.allSatisfy { $0.isEmpty }
        #expect(allEmpty,
                "prompts past the cap still offered snooze: \(offeredPastCap)")
    }
}
