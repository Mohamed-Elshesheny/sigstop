import Foundation
import Testing

@testable import SigstopCore

/// A `break_end` has to carry the number it was judged against.
///
/// `dur_s` alone is only half a verdict: whether 60 seconds counted depends on
/// `min(qualifyingBreak, plannedDuration)`, and both come from settings that can change
/// under a running app. A reader holding the file had the measurement and no threshold, so
/// answering "why does today say 0 kept" meant opening the settings file, deriving the
/// floor by hand, and hoping it had not moved since the line was written.
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

        // And the verdict is recomputable from the line, with nothing else in hand.
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
        // The gloss switch is exhaustive with no default on purpose, so this is really a
        // compile-time guarantee; the assertion is here so the reason is written down.
        for key in LoggedEvent.CodingKeys.allCases {
            #expect(!key.gloss.isEmpty, "\(key) has no gloss")
        }
    }
}
