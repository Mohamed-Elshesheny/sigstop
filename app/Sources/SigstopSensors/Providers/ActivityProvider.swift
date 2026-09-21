import Foundation
import SigstopCore

// MARK: - App claims

/// How a provider declares which apps it speaks for.
///
/// Specificity is a number rather than registration order so that adding a provider can
/// never silently steal an app from a more specific one. An exact bundle ID always beats
/// a prefix, which always beats an executable name, which always beats a catch-all regex.
public struct AppClaim: Sendable, Hashable {
    public enum Match: Sendable, Hashable {
        /// Exact bundle identifier, specificity 300.
        case bundleID(String)
        /// e.g. `"com.jetbrains."`, specificity 200 + prefix length, so a longer (more
        /// specific) prefix outranks a shorter one.
        case bundleIDPrefix(String)
        /// For bundle-less processes, specificity 150.
        case executableName(String)
        /// Last resort, specificity 100.
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

/// `NSRegularExpression` is not cheap to build, and claims are evaluated on every app
/// switch. Patterns are also length-capped: a manifest-supplied regex must not be able to
/// hang the app with catastrophic backtracking.
final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()
    static let maxPatternLength = 200
    static let maxInputLength = 512

    private let lock = NSLock()
    private var cache: [String: NSRegularExpression?] = [:]

    func matches(_ pattern: String, _ input: String) -> Bool {
        guard pattern.count <= Self.maxPatternLength, input.count <= Self.maxInputLength else { return false }
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

// MARK: - Verdict

/// What a provider proposes.
///
/// A provider does **not** compute the final confidence. `ConfidenceEngine` does, so that
/// tier ceilings and calibration live in exactly one place and cannot be bypassed, by a
/// third-party provider, by a declarative manifest, or by a future built-in that gets
/// enthusiastic.
public struct ProviderVerdict: Sendable {
    public let activity: Activity
    public let evidence: [Evidence]
    public let context: ActivityContext
    /// Set when the provider knows it cannot distinguish between sibling activities and
    /// has deliberately named the parent. Caps confidence at 0.60 so "coding, might be
    /// debugging" never looks confident.
    public let degradedFromAmbiguity: Bool
    /// Meeting corroboration and other non-exclusive state the provider can contribute.
    public let concurrentHints: ConcurrentHints
    /// When the honest label differs from the activity's own name, e.g. a desktop AI app
    /// with no corroboration is "AI assistant", not "AI coding". The *label* degrades, not
    /// just the number.
    public let labelOverride: String?
    /// A provider may state an honest upper bound on its own claim, e.g. "a test-file
    /// name in a title means you are *editing* a test, which is not *running* one, so this
    /// tops out at 0.72". The engine takes the minimum of this and the tier ceiling, so a
    /// provider can only ever LOWER confidence, never raise it.
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

/// Evidence a provider can contribute to the *concurrent* meeting axis, which is separate
/// from the primary activity because a meeting overlaps other work. Forcing a choice
/// between "in a meeting" and "coding" produces wrong answers for anyone who codes during
/// a standup.
public struct ConcurrentHints: Sendable, Hashable {
    public var meetingEvidence: [Evidence]

    public init(meetingEvidence: [Evidence] = []) {
        self.meetingEvidence = meetingEvidence
    }

    public static let none = ConcurrentHints()
}

// MARK: - Provider

/// A pure function from signals to a proposed activity.
///
/// Owns no state, performs no I/O, is `Sendable`. All I/O happened upstream in the
/// collectors; a provider only *interprets*. That is what makes every classification rule
/// in docs/ACTIVITY-DETECTION.md §7 testable by writing a `SignalContext` literal, which
/// matters a great deal here, because there is no Xcode and therefore no UI test harness.
public protocol ActivityProvider: Sendable {
    static var identifier: ProviderID { get }
    var claims: [AppClaim] { get }
    /// Tiebreaker when two providers claim at equal specificity. Higher wins. Built-ins
    /// use 0; a third-party override uses 100 so it wins by default.
    var priority: Int { get }

    /// Return `nil` to decline, e.g. a provider that only recognises a specific window
    /// title shape and sees none. Declining passes the app to the next ranked provider,
    /// and ultimately to `GenericProvider`, which never declines.
    func observe(_ context: SignalContext) -> ProviderVerdict?
}

public extension ActivityProvider {
    var priority: Int { 0 }
    var identifier: ProviderID { Self.identifier }

    /// The highest specificity among this provider's matching claims, or `nil` if none match.
    func matchSpecificity(for app: AppIdentity) -> Int? {
        claims.filter { $0.matches(app) }.map(\.specificity).max()
    }
}

// MARK: - Registry

/// Ranks providers for an app and runs resolution.
///
/// Deliberately a value type rather than the actor the design doc sketches: resolution is
/// pure, and making it an actor would force an `await` on a function that does no I/O and
/// owns no mutable state at call time. Isolation is provided by `ContextEngine`, which
/// owns the registry.
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

    public mutating func registerAll(_ newProviders: [any ActivityProvider]) {
        providers.append(contentsOf: newProviders)
    }

    /// Ordered best-first. Never empty, the fallback is always appended last.
    ///
    /// Ranking: highest matching claim specificity, then priority, then identifier. The
    /// last key exists for determinism: tests must be reproducible, and two equally-good
    /// candidates must not flap between samples.
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

    /// Calls providers in rank order; the **first non-nil verdict wins**.
    ///
    /// Verdicts are never merged. Blending two interpretations produces a claim neither
    /// provider would endorse and an evidence list that cannot be read back to the user as
    /// a reason. One provider owns the verdict; everything else is evidence fed into it.
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

// MARK: - Confidence

/// Turns a verdict into an `ActivityObservation`, applying every confidence rule in
/// exactly one place.
public enum ConfidenceEngine {
    /// We start sceptical: 0.15 prior for any inferred activity, before any evidence.
    public static let prior: Double = log(0.15 / 0.85)   // ≈ -1.735
    /// Each individual piece of evidence is clamped, so no single signal, or hostile
    /// manifest, can manufacture certainty by itself.
    public static let logOddsClamp: Double = 2.0

    public static let tier0Ceiling = 0.55
    public static let tier1Ceiling = 0.85
    public static let tier2Ceiling = 0.93
    public static let degradedCeiling = 0.60
    /// Even with every tier, a debugger can be attached and idle.
    public static let debuggingCeiling = 0.90
    /// A debugger this app can name but cannot tie to the app in front, corroborated only
    /// by something under `ptrace` elsewhere. It is DEBUGGING, and it is a weaker claim
    /// than a debugger descending from the app you are actually looking at, so it is
    /// capped lower. Without this the corroboration was decorative: both routes landed on
    /// 0.90 and `tracedElsewhere` changed no number anyone could see.
    public static let debuggerElsewhereCeiling = 0.80
    /// A waiting room, a lingering device hold and a dictation session all look identical
    /// to the best signal we have.
    public static let meetingCeiling = 0.90
    /// `evidence.isEmpty` ⇒ `unknown`, and this is as high as it may go.
    public static let noEvidenceCeiling = 0.20

    public static func ceiling(for tiers: SignalTierSet, degraded: Bool) -> Double {
        var value: Double
        if tiers.contains(.tier2) { value = tier2Ceiling }
        else if tiers.contains(.tier1) { value = tier1Ceiling }
        else { value = tier0Ceiling }
        if degraded { value = min(value, degradedCeiling) }
        return value
    }

    /// Per-activity hard ceilings that apply on top of the tier ceiling.
    public static func activityCeiling(_ activity: Activity) -> Double {
        switch activity {
        case .debugging: return debuggingCeiling
        case .meeting:   return meetingCeiling
        default:         return 1.0
        }
    }

    /// Composes evidence and applies the ceilings.
    ///
    /// `isOSFact` is the *only* route to `Confidence.certain`, and it is reserved for
    /// things the kernel told us, screen locked, displays asleep, session inactive.
    /// Nothing inferred may pass `true` here.
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

    /// Builds the published observation.
    ///
    /// Enforces the invariants that CLAUDE.md §4.1 calls product promises:
    ///
    /// * Evidence citing a tier that is not currently available is **dropped**. An
    ///   observation must never be justified by a signal we did not have, that is exactly
    ///   how a revoked Accessibility grant turns into a stale confident lie.
    /// * `tiersUsed` is *derived* from the surviving evidence, never asserted.
    /// * No evidence ⇒ `unknown` at ≤ 0.2, whatever the provider proposed.
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

        /// Context is gated on what the app was PERMITTED to read, not on which tiers the
        /// surviving evidence happens to cite. The two questions are different and only
        /// look the same while every value is also cited as evidence. Two are not, on
        /// purpose: the branch, which Tier 2 exists to fill, and the browser host, which
        /// is only cited when it is a known forge. A plain page cites nothing above Tier
        /// 0, so deriving this from `tiers` threw the host away between the collector and
        /// the panel: the panel said "Google Chrome" while `--doctor`, one layer down,
        /// said "theboring.name". `tiersUsed` stays derived from the evidence, because it
        /// is the confidence ceiling's input and the host is not evidence.
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

    /// Meeting lives on its own axis and gets its own composition, capped at 0.90.
    ///
    /// `.unreliable` audio contributes nothing, see `AudioInputState`. On a Mac whose mic
    /// never turns off, meeting detection is switched off entirely rather than left on and
    /// permanently wrong.
    public static func meetingConfidence(_ evidence: [Evidence], tiers: SignalTierSet) -> Confidence {
        guard !evidence.isEmpty else { return .none }
        let raw = Probability.combine(evidence.map(clamp(_:)), prior: prior).value
        return Confidence(min(raw, min(ceiling(for: tiers, degraded: false), meetingCeiling)))
    }
}
