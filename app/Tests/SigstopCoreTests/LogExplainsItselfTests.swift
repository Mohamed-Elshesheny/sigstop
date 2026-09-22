import Foundation
import Testing

@testable import SigstopCore

struct LogExplainsItselfTests {

    @Test("break_end records the threshold it was judged against")
    func breakEndCarriesTheThreshold() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let lines = EventLogWriter.lines(
            for: .endBreak(
                cycle: CycleID(rawValue: 3), origin: .accepted,
                honored: false, elapsed: 60, threshold: 300
            ),
            at: now,
            context: EffectLogContext(confirmedPromptCycle: nil)
        )
        let end = lines.first { $0.kind == .breakEnd }
        #expect(end?.durationSeconds == 60)
        #expect(end?.thresholdSeconds == 300, "the reader must not have to guess this")

        let recomputed = (end?.durationSeconds ?? 0) >= (end?.thresholdSeconds ?? .max)
        #expect(recomputed == false, "60 < 300, which is exactly what the engine decided")
    }

    @Test("the threshold survives a round trip through the file")
    func survivesEncoding() throws {
        let line = LoggedEvent.breakEnd(
            at: Date(timeIntervalSince1970: 1_700_000_000), origin: .accepted,
            durationSeconds: 303, thresholdSeconds: 300, cycle: CycleID(rawValue: 1)
        )
        let text = try EventLogCodec.encodeLines([line])
        #expect(text.contains("\"plan_s\":300"), "got \(text)")

        let back = try EventLogCodec.decodeLines(text)
        #expect(back.events.first?.thresholdSeconds == 300)
    }

    @Test("every field on a log line has a gloss for the export header")
    func everyFieldIsDocumented() {
        for key in LoggedEvent.CodingKeys.allCases {
            #expect(!key.gloss.isEmpty, "\(key) has no gloss")
        }
    }
}
