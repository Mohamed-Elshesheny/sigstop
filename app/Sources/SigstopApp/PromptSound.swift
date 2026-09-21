import AppKit
import SigstopCore

/// The sound that goes with a prompt, graded by escalation.
///
/// Level one used to be silent, on the argument that a sound on the very first reminder of
/// every cycle is how an app becomes something people mute, and that once muted it is worth
/// nothing at level four, which is the level that matters.
///
/// The argument was fine and the result was not. Almost every prompt anyone sees is level
/// one, because they answer it, so the switch labelled "play a sound" had never once made a
/// sound on the owner's machine. A setting that does nothing is worse than no setting: it
/// spends the user's trust to buy nothing.
///
/// So every rung sounds, and the escalation is carried by **volume** instead of by silence.
/// Level one is quiet enough to sit under a conversation and still tells you the panel
/// arrived if you were looking away. Level four is the one that should make you flinch.
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

    /// `NSSound.volume` is a fraction of the system volume, so this never plays louder than
    /// the machine is already set to.
    private static func volume(for level: EscalationLevel) -> Float {
        switch level {
        case .first:    return 0.35
        case .second:   return 0.6
        case .third:    return 0.8
        case .incident: return 1
        }
    }
}
