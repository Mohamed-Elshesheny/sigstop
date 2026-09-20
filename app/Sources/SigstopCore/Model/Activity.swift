import Foundation

// MARK: - Activity taxonomy

/// A high-level inference about what the developer is doing.
///
/// The taxonomy is a shallow tree. When the available signals cannot distinguish two
/// siblings, callers MUST degrade to the shared `parent` rather than pick one. Guessing
/// wrong and announcing "you've been debugging for 61 minutes" to someone who was writing
/// documentation destroys the only thing this product has: the sense that it actually knows.
public enum Activity: String, Sendable, Codable, CaseIterable, Hashable {
    case coding
    case debugging
    case testing
    case codeReview
    case terminalWork
    case aiCoding
    case documentation
    case browsing
    case communication
    case meeting
    case idle
    case unknown

    /// The class to fall back to when a child cannot be distinguished from its siblings.
    public var parent: Activity? {
        switch self {
        case .debugging, .testing, .aiCoding, .documentation: return .coding
        case .codeReview:                                     return .browsing
        case .meeting:                                        return .communication
        case .terminalWork, .coding, .browsing,
             .communication, .idle, .unknown:                 return nil
        }
    }

    /// Walks up to the least specific ancestor. `debugging -> coding`, `coding -> coding`.
    public var root: Activity {
        var node = self
        while let p = node.parent { node = p }
        return node
    }

    /// True when this activity represents the developer actively working.
    /// Drives the continuous-work clock. `.unknown` counts as work: the app must not
    /// reward its own ignorance by quietly pausing the clock.
    public var countsAsWork: Bool {
        self != .idle
    }

    /// Human-readable, lowercase, used inside message templates.
    public var displayName: String {
        switch self {
        case .coding:        return "coding"
        case .debugging:     return "debugging"
        case .testing:       return "running tests"
        case .codeReview:    return "reviewing code"
        case .terminalWork:  return "in the terminal"
        case .aiCoding:      return "pair-programming with an AI"
        case .documentation: return "writing docs"
        case .browsing:      return "browsing"
        case .communication: return "in chat"
        case .meeting:       return "in a meeting"
        case .idle:          return "away"
        case .unknown:       return "working"
        }
    }
}

// MARK: - Signal tiers

/// What the app is allowed to observe, as a function of what the user has granted.
///
/// The app is fully functional at `tier0` alone. Higher tiers are upgrades, never gates.
public enum SignalTier: Int, Sendable, Codable, CaseIterable, Hashable {
    /// Zero permission, zero prompts, always available.
    /// Frontmost app, idle seconds, mic-in-use, screen lock, thermal state.
    case tier0 = 0
    /// Accessibility (`AXUIElement`), user-granted. Window titles only.
    case tier1 = 1
    /// Explicit opt-in: local git context read from `.git/HEAD`.
    case tier2 = 2
}

public struct SignalTierSet: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let tier0 = SignalTierSet(rawValue: 1 << 0)
    public static let tier1 = SignalTierSet(rawValue: 1 << 1)
    public static let tier2 = SignalTierSet(rawValue: 1 << 2)

    public init(_ tier: SignalTier) {
        self.init(rawValue: 1 << tier.rawValue)
    }
}

// MARK: - Confidence

/// A probability in `0...1` that cannot be constructed out of range, including when
/// decoded from a hand-edited state file.
public struct Confidence: Sendable, Codable, Hashable, Comparable {
    public let value: Double

    public init(_ v: Double) {
        self.value = v.isFinite ? min(max(v, 0.0), 1.0) : 0.0
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.init(try c.decode(Double.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }

    public static func < (a: Self, b: Self) -> Bool { a.value < b.value }

    public static let none = Confidence(0.0)

    /// Reserved for OS facts only, screen locked, session inactive. Nothing *inferred*
    /// may reach this. See CLAUDE.md §4.1.
    public static let certain = Confidence(0.99)

    /// Below this, the message engine must not make a specific claim about the activity.
    public static let specificClaimThreshold = Confidence(0.6)

    public var isConfidentEnoughForSpecificClaim: Bool {
        self >= Self.specificClaimThreshold
    }
}

// MARK: - Evidence

public struct EvidenceID: Sendable, Codable, Hashable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ s: String) { self.rawValue = s }
}

/// A single reason the app believes something.
///
/// Expressed in **log-odds** so that independent reasons compose by addition rather than
/// by an ad-hoc weighted average. `summary` is user-facing and mandatory: the app must
/// always be able to answer "why do you think that?", `sigstop --doctor` prints these.
public struct Evidence: Sendable, Codable, Hashable {
    public let id: EvidenceID
    public let tier: SignalTier
    public let logOdds: Double
    public let summary: String

    public init(id: EvidenceID, tier: SignalTier, logOdds: Double, summary: String) {
        self.id = id
        self.tier = tier
        self.logOdds = logOdds.isFinite ? logOdds : 0
        self.summary = summary
    }
}

public enum Probability {
    /// Combine independent evidence into a confidence. Addition in log-odds space is
    /// the whole reason `Evidence.logOdds` exists.
    public static func combine(_ evidence: [Evidence], prior: Double = 0) -> Confidence {
        let total = evidence.reduce(prior) { $0 + $1.logOdds }
        return Confidence(1.0 / (1.0 + exp(-total)))
    }
}
