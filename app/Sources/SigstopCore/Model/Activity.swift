import Foundation

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

    public var parent: Activity? {
        switch self {
        case .debugging, .testing, .aiCoding, .documentation: return .coding
        case .codeReview:                                     return .browsing
        case .meeting:                                        return .communication
        case .terminalWork, .coding, .browsing,
             .communication, .idle, .unknown:                 return nil
        }
    }

    public var root: Activity {
        var node = self
        while let p = node.parent { node = p }
        return node
    }

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

public enum SignalTier: Int, Sendable, Codable, CaseIterable, Hashable {
    case tier0 = 0
    case tier1 = 1
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

    public static let certain = Confidence(0.99)

    public static let specificClaimThreshold = Confidence(0.6)

    public var isConfidentEnoughForSpecificClaim: Bool {
        self >= Self.specificClaimThreshold
    }
}

public struct EvidenceID: Sendable, Codable, Hashable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ s: String) { self.rawValue = s }
}

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
    public static func combine(_ evidence: [Evidence], prior: Double = 0) -> Confidence {
        let total = evidence.reduce(prior) { $0 + $1.logOdds }
        return Confidence(1.0 / (1.0 + exp(-total)))
    }
}
