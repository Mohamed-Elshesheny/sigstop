import Foundation
import Testing

@testable import SigstopCore

@Suite("The face: one expression per rung, capped by the rendered tone")
struct FaceMoodTests {

    private static let pairs: [(EscalationLevel, Tone)] = EscalationLevel.allCases.flatMap { level in
        Tone.allCases.map { (level, $0) }
    }

    @Test("every rung maps to the mood the ladder names", arguments: EscalationLevel.allCases)
    func rung(_ level: EscalationLevel) {
        let expected: FaceMood
        switch level {
        case .first: expected = .watching
        case .second: expected = .eyebrow
        case .third: expected = .level
        case .incident: expected = .wink
        }
        for tone in Tone.allCases where !(level == .third && tone == .friendly) {
            #expect(FaceMood(level: level, tone: tone) == expected, "\(level) \(tone)")
        }
    }

    @Test("a friendly line at SIGTERM gets the eyebrow, never the lowered lids")
    func friendlyCapsTheThirdRung() {
        #expect(FaceMood(level: .third, tone: .friendly) == .eyebrow)
        for tone in Tone.allCases {
            #expect(FaceMood(level: .third, tone: tone) != .level || tone != .friendly)
        }
    }

    @Test("a friendly tone never yields the level face at any rung", arguments: EscalationLevel.allCases)
    func friendlyNeverLevel(_ level: EscalationLevel) {
        #expect(FaceMood(level: level, tone: .friendly) != .level)
    }

    @Test("the prompt never wears the break screen's face or the resting one")
    func promptFacesOnly() {
        for (level, tone) in Self.pairs {
            let mood = FaceMood(level: level, tone: tone)
            #expect(mood != .welcomeBack && mood != .resting, "\(level) \(tone) -> \(mood)")
        }
    }

    @Test("a harsher tone never softens the face and a softer one never hardens it")
    func toneOnlyEverSoftens() {
        for level in EscalationLevel.allCases {
            let capped = FaceMood(level: level, tone: .friendly)
            let full = FaceMood(level: level, tone: .nuclear)
            #expect(capped == full || (capped == .eyebrow && full == .level), "\(level)")
        }
    }

    @Test("spoken labels name the app, carry no em dash and describe no pain", arguments: FaceMood.allCases)
    func spokenLabel(_ mood: FaceMood) {
        let label = mood.spokenLabel
        #expect(label.hasPrefix("sigstop, "))
        #expect(!label.contains("\u{2014}"))
        for word in ["sad", "angry", "disappointed", "hurt", "cry", "tired", "sick"] {
            #expect(!label.lowercased().contains(word), "\(mood): \(label)")
        }
    }

    @Test("every mood has its own label")
    func labelsAreDistinct() {
        let labels = Set(FaceMood.allCases.map(\.spokenLabel))
        #expect(labels.count == FaceMood.allCases.count)
    }
}
