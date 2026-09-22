import Foundation
import SigstopCore

public struct AppClaim: Sendable, Hashable {
    public enum Match: Sendable, Hashable {
        case bundleID(String)
        case bundleIDPrefix(String)
        case executableName(String)
        case bundleIDRegex(String)
    }

    public let match: Match

    public init(_ match: Match) { self.match = match }

    public var specificity: Int {
        switch match {
        case .bundleID:              return 300
        case .bundleIDPrefix(let p): return 200 + p.count
        case .executableName:        return 150
        case .bundleIDRegex:         return 100
        }
    }

    public func matches(_ app: AppIdentity) -> Bool {
        switch match {
        case .bundleID(let id):
            return app.bundleID?.caseInsensitiveCompare(id) == .orderedSame
        case .bundleIDPrefix(let prefix):
            guard let id = app.bundleID else { return false }
            return id.lowercased().hasPrefix(prefix.lowercased())
        case .executableName(let name):
            return app.localizedName.caseInsensitiveCompare(name) == .orderedSame
        case .bundleIDRegex(let pattern):
            guard let id = app.bundleID else { return pattern == ".*" }
            return RegexCache.shared.matches(pattern, id)
        }
    }
}

final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()
    static let maxPatternLength = 200
    static let maxInputLength = 512

    private let lock = NSLock()
    private var cache: [String: NSRegularExpression?] = [:]

    func matches(_ pattern: String, _ input: String) -> Bool {
        guard pattern.utf16.count <= Self.maxPatternLength, input.utf16.count <= Self.maxInputLength else { return false }
        guard let regex = regex(for: pattern) else { return false }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.firstMatch(in: input, options: [], range: range) != nil
    }

    func regex(for pattern: String) -> NSRegularExpression? {
        lock.lock()
        if let cached = cache[pattern] { lock.unlock(); return cached }
        lock.unlock()
        let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        lock.lock()
        cache[pattern] = compiled
        lock.unlock()
        return compiled
    }
}

public struct ProviderVerdict: Sendable {
    public let activity: Activity
    public let evidence: [Evidence]
    public let context: ActivityContext
    public let degradedFromAmbiguity: Bool
    public let concurrentHints: ConcurrentHints
    public let labelOverride: String?
    public let maximumConfidence: Double?

    public init(
        activity: Activity,
        evidence: [Evidence],
        context: ActivityContext = .empty,
        degradedFromAmbiguity: Bool = false,
        concurrentHints: ConcurrentHints = .none,
        labelOverride: String? = nil,
        maximumConfidence: Double? = nil
    ) {
        self.activity = activity
        self.evidence = evidence
        self.context = context
        self.degradedFromAmbiguity = degradedFromAmbiguity
        self.concurrentHints = concurrentHints
        self.labelOverride = labelOverride
        self.maximumConfidence = maximumConfidence
    }
}

public struct ConcurrentHints: Sendable, Hashable {
    public var meetingEvidence: [Evidence]

    public init(meetingEvidence: [Evidence] = []) {
        self.meetingEvidence = meetingEvidence
    }

    public static let none = ConcurrentHints()
}

public protocol ActivityProvider: Sendable {
    static var identifier: ProviderID { get }
    var claims: [AppClaim] { get }
    var priority: Int { get }

    func observe(_ context: SignalContext) -> ProviderVerdict?
}

public extension ActivityProvider {
    var priority: Int { 0 }
    var identifier: ProviderID { Self.identifier }

    func matchSpecificity(for app: AppIdentity) -> Int? {
        claims.filter { $0.matches(app) }.map(\.specificity).max()
    }
}

public struct ProviderRegistry: Sendable {
    private var providers: [any ActivityProvider]
    private let fallback: any ActivityProvider

    public init(
        providers: [any ActivityProvider] = BuiltinProviders.all,
        fallback: any ActivityProvider = GenericProvider()
    ) {
        self.providers = providers
        self.fallback = fallback
    }

    public mutating func register(_ provider: any ActivityProvider) {
        providers.append(provider)
    }

    public func resolve(for app: AppIdentity) -> [any ActivityProvider] {
        let ranked = providers
            .compactMap { provider -> (provider: any ActivityProvider, specificity: Int)? in
                guard let specificity = provider.matchSpecificity(for: app) else { return nil }
                return (provider, specificity)
            }
            .sorted { lhs, rhs in
                if lhs.specificity != rhs.specificity { return lhs.specificity > rhs.specificity }
                if lhs.provider.priority != rhs.provider.priority {
                    return lhs.provider.priority > rhs.provider.priority
                }
                return lhs.provider.identifier.rawValue < rhs.provider.identifier.rawValue
            }
            .map(\.provider)
        return ranked + [fallback]
    }

    public func classify(_ signals: SignalContext) -> (verdict: ProviderVerdict, providerID: ProviderID) {
        for provider in resolve(for: signals.frontmost) {
            if let verdict = provider.observe(signals) {
                return (verdict, provider.identifier)
            }
        }
        return (
            ProviderVerdict(activity: .unknown, evidence: []),
            ProviderID("dev.sigstop.provider.none")
        )
    }
}

public enum ConfidenceEngine {
    public static let prior: Double = log(0.15 / 0.85)
    public static let logOddsClamp: Double = 2.0

    public static let tier0Ceiling = 0.55
    public static let tier1Ceiling = 0.85
    public static let tier2Ceiling = 0.93
    public static let degradedCeiling = 0.60
    public static let debuggingCeiling = 0.90
    public static let debuggerElsewhereCeiling = 0.80
    public static let meetingCeiling = 0.90
    public static let noEvidenceCeiling = 0.20

    public static func ceiling(for tiers: SignalTierSet, degraded: Bool) -> Double {
        var value: Double
        if tiers.contains(.tier2) { value = tier2Ceiling }
        else if tiers.contains(.tier1) { value = tier1Ceiling }
        else { value = tier0Ceiling }
        if degraded { value = min(value, degradedCeiling) }
        return value
    }

    public static func activityCeiling(_ activity: Activity) -> Double {
        switch activity {
        case .debugging: return debuggingCeiling
        case .meeting:   return meetingCeiling
        default:         return 1.0
        }
    }

    public static func confidence(
        evidence: [Evidence],
        tiers: SignalTierSet,
        activity: Activity,
        degradedFromAmbiguity: Bool,
        isOSFact: Bool = false
    ) -> Confidence {
        if isOSFact { return .certain }
        guard !evidence.isEmpty else { return Confidence(min(noEvidenceCeiling, tier0Ceiling)) }
        let clamped = evidence.map(clamp(_:))
        let raw = Probability.combine(clamped, prior: prior).value
        let cap = min(ceiling(for: tiers, degraded: degradedFromAmbiguity), activityCeiling(activity))
        return Confidence(min(raw, cap))
    }

    static func clamp(_ evidence: Evidence) -> Evidence {
        Evidence(
            id: evidence.id,
            tier: evidence.tier,
            logOdds: max(-logOddsClamp, min(logOddsClamp, evidence.logOdds)),
            summary: evidence.summary
        )
    }

    public static func observation(
        verdict: ProviderVerdict,
        providerID: ProviderID,
        signals: SignalContext,
        concurrent: ConcurrentStates,
        isOSFact: Bool = false
    ) -> ActivityObservation {
        let usable = verdict.evidence.filter { signals.available.contains(SignalTierSet($0.tier)) }

        guard !usable.isEmpty else {
            return ActivityObservation(
                timestamp: signals.now,
                activity: .unknown,
                confidence: Confidence(noEvidenceCeiling),
                evidence: [],
                app: signals.frontmost,
                context: .empty,
                concurrent: concurrent,
                providerID: providerID,
                tiersUsed: [.tier0]
            )
        }

        var tiers: SignalTierSet = [.tier0]
        for item in usable { tiers.insert(SignalTierSet(item.tier)) }

        var confidence = confidence(
            evidence: usable,
            tiers: tiers,
            activity: verdict.activity,
            degradedFromAmbiguity: verdict.degradedFromAmbiguity,
            isOSFact: isOSFact
        )
        if let bound = verdict.maximumConfidence, !isOSFact {
            confidence = Confidence(min(confidence.value, bound))
        }

        var context = verdict.context
        if !signals.available.contains(.tier1) {
            context.projectName = nil
            context.fileName = nil
            context.fileExtension = nil
            context.documentURL = nil
            context.browserHost = nil
        }
        if !signals.available.contains(.tier2) {
            context.branch = nil
            context.repoState = nil
        }

        return ActivityObservation(
            timestamp: signals.now,
            activity: verdict.activity,
            confidence: confidence,
            evidence: usable.map(clamp(_:)),
            app: signals.frontmost,
            context: context,
            concurrent: concurrent,
            providerID: providerID,
            tiersUsed: tiers
        )
    }

    public static func meetingConfidence(_ evidence: [Evidence], tiers: SignalTierSet) -> Confidence {
        guard !evidence.isEmpty else { return .none }
        let raw = Probability.combine(evidence.map(clamp(_:)), prior: prior).value
        return Confidence(min(raw, min(ceiling(for: tiers, degraded: false), meetingCeiling)))
    }
}
