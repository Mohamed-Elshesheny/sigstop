import AppKit
import SigstopCore

enum PromptSound {
    static func play(for level: EscalationLevel, enabled: Bool) {
        guard enabled, let sound = NSSound(named: name(for: level)) else { return }
        sound.volume = volume(for: level)
        sound.play()
    }

    private static func name(for level: EscalationLevel) -> NSSound.Name {
        switch level {
        case .first:    return NSSound.Name("Tink")
        case .second:   return NSSound.Name("Morse")
        case .third:    return NSSound.Name("Submarine")
        case .incident: return NSSound.Name("Sosumi")
        }
    }

    private static func volume(for level: EscalationLevel) -> Float {
        switch level {
        case .first:    return 0.35
        case .second:   return 0.6
        case .third:    return 0.8
        case .incident: return 1
        }
    }
}
