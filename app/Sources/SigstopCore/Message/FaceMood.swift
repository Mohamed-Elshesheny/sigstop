import Foundation

public enum FaceMood: String, Sendable, Codable, CaseIterable, Hashable {
    case watching
    case eyebrow
    case level
    case wink
    case welcomeBack
    case resting

    public init(level: EscalationLevel, tone: Tone) {
        switch level {
        case .first: self = .watching
        case .second: self = .eyebrow
        case .third: self = tone == .friendly ? .eyebrow : .level
        case .incident: self = .wink
        }
    }

    public var spokenLabel: String {
        switch self {
        case .watching: return "sigstop, watching"
        case .eyebrow: return "sigstop, one eyebrow raised"
        case .level: return "sigstop, eyes level"
        case .wink: return "sigstop, winking"
        case .welcomeBack: return "sigstop, smiling with its eyes"
        case .resting: return "sigstop, eyes closed"
        }
    }
}
