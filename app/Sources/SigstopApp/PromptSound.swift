import AppKit
import SigstopCore

/// The sound that goes with a prompt, graded by escalation.
///
/// Level one is silent. The panel already covers the screen, and a sound on the very first
/// reminder of every cycle is how an app becomes something people mute; once muted it is
/// worth nothing at level four, which is the level that matters. Escalating instead means
/// the sound still carries information when it arrives: you have already ignored one.
enum PromptSound {
    static func play(for level: EscalationLevel, enabled: Bool) {
        guard enabled, let name = name(for: level) else { return }
        NSSound(named: name)?.play()
    }

    private static func name(for level: EscalationLevel) -> NSSound.Name? {
        switch level {
        case .first:    return nil
        case .second:   return NSSound.Name("Tink")
        case .third:    return NSSound.Name("Submarine")
        case .incident: return NSSound.Name("Sosumi")
        }
    }
}
