import Foundation

// MARK: - The app a call is attributed to

/// A call-capable app, folded to one canonical identifier and a name a human recognises.
///
/// Resolved in `SigstopSensors` (where the bundle-identifier catalog lives) and carried
/// across the layer boundary as a plain value, so `SigstopCore` never learns that macOS,
/// CoreAudio or bundle identifiers exist. CLAUDE.md §3.1.
public struct CallCapableApp: Sendable, Codable, Hashable {
    public let bundleID: String
    public let name: String
    /// True for Slack, Teams, Zoom, Discord. False for a browser, which is call-capable
    /// only in the sense that a tab might be a call.
    public let isConferencing: Bool

    public init(bundleID: String, name: String, isConferencing: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.isConferencing = isConferencing
    }
}

// MARK: - Input

/// One instant of the facts the call latch is allowed to see.
///
/// Every field is Tier 0 and permission-free. There is deliberately no `Confidence`, no
/// `Activity`, no `ConcurrentStates` and no window title in here: the latch must not be
/// able to inherit a guess, and the cheapest way to guarantee that is to make the guess
/// unrepresentable in its input.
public struct MeetingLatchInput: Sendable, Hashable {
    /// From `TimeSource.monotonicSeconds`. Every duration in the latch is a difference of
    /// two of these; the latch never reads a clock itself (CLAUDE.md §3.2).
    public var monotonic: Double
    /// From `TimeSource.now`. Used to notice an unobserved gap and for display. Never to
    /// measure a timeout.
    public var wall: Date
    /// `LocalDay.index`, computed by the caller with an injected `Calendar`.
    public var dayIndex: Int

    /// An audio input device is running, attributed where attribution was available.
    public var micLive: Bool
    /// A camera device is running. `kCMIODevicePropertyDeviceIsRunningSomewhere`.
    public var cameraLive: Bool

    /// Call-capable apps running right now. Membership is the anchor-present test.
    public var callCapableRunning: [CallCapableApp]
    /// The call-capable app CoreAudio's process table attributes microphone input to,
    /// when the table could be read and it named one.
    public var attributedCallCapable: CallCapableApp?
    /// The frontmost app, when it is call-capable.
    public var frontmostCallCapable: CallCapableApp?

    /// `SigstopSettings.holdBreaksDuringCalls`. Off disables the latch and nothing else:
    /// the live microphone and camera hard blocks are facts and predate it.
    public var enabled: Bool
    public var screenLocked: Bool
    public var sessionActive: Bool

    public init(
        monotonic: Double,
        wall: Date,
        dayIndex: Int = 0,
        micLive: Bool = false,
        cameraLive: Bool = false,
        callCapableRunning: [CallCapableApp] = [],
        attributedCallCapable: CallCapableApp? = nil,
        frontmostCallCapable: CallCapableApp? = nil,
        enabled: Bool = true,
        screenLocked: Bool = false,
        sessionActive: Bool = true
    ) {
        self.monotonic = monotonic
        self.wall = wall
        self.dayIndex = dayIndex
        self.micLive = micLive
        self.cameraLive = cameraLive
        self.callCapableRunning = callCapableRunning
        self.attributedCallCapable = attributedCallCapable
        self.frontmostCallCapable = frontmostCallCapable
        self.enabled = enabled
        self.screenLocked = screenLocked
        self.sessionActive = sessionActive
    }

    var captureLive: Bool { micLive || cameraLive }
}

// MARK: - The projection the policy sees

/// What `InterruptionPolicy` is handed. A plain value on `SystemSignals`, so the policy
/// stays stateless and pure and the latch's own bookkeeping stays out of it.
public struct MeetingLatchSignal: Sendable, Codable, Hashable {

    public enum Basis: String, Sendable, Codable, Hashable {
        case none
        case microphone
        case camera
        case both
        /// The user said so.
        case manual
    }

    /// Why the latch is not holding, when it could otherwise have been.
    public enum Inhibition: String, Sendable, Codable, Hashable {
        case disabled
        case userCleared
        case episodeCeiling
        case dailyCeiling
    }

    /// True only while the latch is holding a break back. It is deliberately false while
    /// capture is actually live, because the live microphone and camera hard blocks
    /// already cover that: `heldSeconds` then measures the latch's *own* footprint and
    /// nothing else, which is what makes the ceilings below mean anything.
    public var isHolding: Bool
    /// A capture fact exists but is not yet enough to block on, or the app has only just
    /// started next to a running conferencing app. A guess, so it may only defer.
    public var suspectsCall: Bool
    public var basis: Basis
    public var anchorName: String?
    /// Wall clock, for the menu and `--doctor`. Never used to measure anything.
    public var captureEndedAt: Date?
    public var closesAt: Date?
    public var heldSecondsThisEpisode: TimeInterval
    public var heldSecondsToday: TimeInterval
    public var inhibition: Inhibition?

    public init(
        isHolding: Bool = false,
        suspectsCall: Bool = false,
        basis: Basis = .none,
        anchorName: String? = nil,
        captureEndedAt: Date? = nil,
        closesAt: Date? = nil,
        heldSecondsThisEpisode: TimeInterval = 0,
        heldSecondsToday: TimeInterval = 0,
        inhibition: Inhibition? = nil
    ) {
        self.isHolding = isHolding
        self.suspectsCall = suspectsCall
        self.basis = basis
        self.anchorName = anchorName
        self.captureEndedAt = captureEndedAt
        self.closesAt = closesAt
        self.heldSecondsThisEpisode = heldSecondsThisEpisode
        self.heldSecondsToday = heldSecondsToday
        self.inhibition = inhibition
    }

    public static let closed = MeetingLatchSignal()

    /// The sentence the menu bar and `--doctor` print. It states what was observed and
    /// when; it never says "you are in a meeting", because the latch does not know that.
    public var summary: String? {
        guard isHolding else { return nil }
        if basis == .manual { return "You said you are in a meeting, so prompts are held." }
        let what = basis == .camera ? "A camera" : "A microphone"
        let who = anchorName.map { " (\($0))" } ?? ""
        return "Holding your break. \(what) was live until just now\(who), so this may still be a call."
    }
}

// MARK: - The latch

/// A bounded **trailing edge** on two hard blocks that already exist.
///
/// `audioInputInUse` and `cameraInUse` are facts, and today they end the instant the bit
/// drops, which is exactly what pressing mute does. The latch says something narrower
/// than "you are in a meeting":
///
/// > a capture device on this machine ran continuously for at least `latchArmDwell` and
/// > stopped less than `holdBudget` seconds ago.
///
/// Every clause is an OS property read plus arithmetic on the injected clock. That is why
/// `HardBlock.recentCallContinuing` is named after what it asserts rather than after what
/// a person might conclude from it, and why nothing in this file reads a `Confidence`.
///
/// It is a value with a pure reducer, and it lives in `SigstopCore` because that is the
/// only target with a test target attached: a suppression whose timeouts are untested is
/// a hope, and this is the one code path where a bug means the product silently stops
/// working.
public struct MeetingLatch: Sendable, Codable, Hashable {

    public enum Phase: String, Sendable, Codable, Hashable {
        case closed
        /// Capture is live but has not lasted long enough to be a call.
        case arming
        /// Capture is live and established. The live hard blocks are doing the work here.
        case live
        /// Capture has stopped and the latch is holding. This is the whole feature.
        case held
    }

    public enum CloseReason: String, Sendable, Codable, Hashable {
        case budgetSpent
        case anchorQuit
        case sessionEnded
        case discontinuity
        case episodeCeiling
        case dailyCeiling
        case userCleared
        case disabled
    }

    public private(set) var phase: Phase = .closed
    public private(set) var closeReason: CloseReason?

    var lastAdvanceMono: Double = 0
    var lastAdvanceWall: Date = .distantPast
    var constructedMono: Double = 0
    var armedSinceMono: Double?
    var lastLiveMono: Double?
    var anchor: CallCapableApp?
    var anchorPresent: Bool = false
    var basis: MeetingLatchSignal.Basis = .none
    var captureEndedWall: Date?
    var quietSinceMono: Double?
    var inhibitUntilMono: Double?
    var manualHoldUntilMono: Double?
    var inhibition: MeetingLatchSignal.Inhibition?
    var callCapablePresent: Bool = false

    public private(set) var heldSecondsThisEpisode: TimeInterval = 0
    /// Survives a relaunch, unlike the latch itself: see `restoringDailyHold`.
    public private(set) var heldSecondsToday: TimeInterval = 0
    public private(set) var dayIndex: Int = 0

    public init() {}

    /// A latch that knows when it started, which is what the cold-start grace needs.
    public static func started(at monotonic: Double, wall: Date, dayIndex: Int) -> MeetingLatch {
        var l = MeetingLatch()
        l.lastAdvanceMono = monotonic
        l.lastAdvanceWall = wall
        l.constructedMono = monotonic
        l.dayIndex = dayIndex
        return l
    }

    /// Restore only the day's accumulated hold, never the latch itself.
    ///
    /// A latch restored from disk is a suppression that can outlive the bug that created
    /// it, invisibly, across launches; `EngineState` is rebuilt `.initial` at every launch
    /// for the same reason and the latch follows it. A *counter* is the opposite: it can
    /// only ever make the app noisier, so persisting it carries none of that risk, and
    /// without it the three-hour daily ceiling is defeated by quitting and reopening.
    public func restoringDailyHold(seconds: TimeInterval, dayIndex: Int) -> MeetingLatch {
        var l = self
        guard dayIndex == l.dayIndex else { return l }
        l.heldSecondsToday = max(0, seconds)
        if l.heldSecondsToday >= BreakPolicy.default.latchDailyCeiling {
            l.inhibition = .dailyCeiling
        }
        return l
    }

    // MARK: Derived

    public var isHolding: Bool { phase == .held }

    /// How long the latch will hold after capture stops.
    ///
    /// The base is unconditional on the capture fact. The anchor can only ever *add* the
    /// extension while it is still running, or collapse the hold once an anchor that was
    /// actually adopted has quit. So the app-identity term is monotone in the safe
    /// direction: delete every line of it and an eight-minute fact hold remains.
    func holdBudget(_ policy: BreakPolicy) -> TimeInterval {
        guard anchor != nil else { return policy.latchFactHold }
        guard anchorPresent else { return policy.latchAnchorQuitHold }
        return policy.latchFactHold + policy.latchAnchorExtension
    }

    public func signal(at monotonic: Double, wall: Date, policy: BreakPolicy) -> MeetingLatchSignal {
        let manual = manualHoldUntilMono.map { monotonic < $0 } ?? false
        let holding = manual || phase == .held
        let coldStart = monotonic - constructedMono < policy.latchColdStartGrace && callCapablePresent
        var closes: Date?
        if manual, let until = manualHoldUntilMono {
            closes = wall.addingTimeInterval(until - monotonic)
        } else if phase == .held, let live = lastLiveMono {
            closes = wall.addingTimeInterval(max(0, holdBudget(policy) - (monotonic - live)))
        }
        return MeetingLatchSignal(
            isHolding: holding,
            suspectsCall: !holding && (phase == .arming || phase == .live || coldStart),
            basis: manual ? .manual : basis,
            anchorName: anchor?.name,
            captureEndedAt: captureEndedWall,
            closesAt: closes,
            heldSecondsThisEpisode: heldSecondsThisEpisode,
            heldSecondsToday: heldSecondsToday,
            inhibition: inhibition
        )
    }

    // MARK: User actions

    /// "I am in a meeting." The only answer available for the three states no Tier 0
    /// signal can reach: Meet in Safari, a screen share with the microphone muted, and a
    /// phone dial-in. It expires, because a manual hold that never expires is a mute
    /// button and a forgotten mute button is how this product dies silently.
    public func assertedByUser(at monotonic: Double, policy: BreakPolicy) -> MeetingLatch {
        var l = self
        l.manualHoldUntilMono = monotonic + policy.latchManualHold
        l.inhibitUntilMono = nil
        l.inhibition = nil
        return l
    }

    /// "I am not in a meeting." Closes the latch and stops it re-opening from the same
    /// still-running app for `latchManualInhibit`. The user's "no" is their statement, so
    /// unlike the latch it survives an unobserved gap.
    public func clearedByUser(at monotonic: Double, policy: BreakPolicy) -> MeetingLatch {
        var l = self
        l.manualHoldUntilMono = nil
        l.inhibitUntilMono = monotonic + policy.latchManualInhibit
        return l.closing(.userCleared, at: monotonic, inhibition: .userCleared)
    }

    // MARK: The step

    /// Pure. No clock, no I/O, no allocation of anything the caller cannot see.
    public func advanced(_ input: MeetingLatchInput, policy: BreakPolicy) -> MeetingLatch {
        var l = self
        let monoDelta = max(0, input.monotonic - l.lastAdvanceMono)
        let wallDelta = input.wall.timeIntervalSince(l.lastAdvanceWall)
        /// The larger of the two is how much time actually passed. A system sleep moves
        /// the wall clock and not the monotonic one; a throttled process moves both.
        let observedGap = max(monoDelta, wallDelta)
        let unobserved = observedGap > policy.latchGapTolerance
        l.lastAdvanceMono = input.monotonic
        l.lastAdvanceWall = input.wall
        l.callCapablePresent = !input.callCapableRunning.isEmpty

        if input.dayIndex != l.dayIndex {
            l.dayIndex = input.dayIndex
            l.heldSecondsToday = 0
            if l.inhibition == .dailyCeiling { l.inhibition = nil }
        }

        if let until = l.manualHoldUntilMono, input.monotonic >= until {
            l.manualHoldUntilMono = nil
        }

        guard input.enabled else {
            return l.closing(.disabled, at: input.monotonic, inhibition: .disabled)
        }

        if let until = l.inhibitUntilMono {
            if input.monotonic < until {
                return l.closing(.userCleared, at: input.monotonic, inhibition: .userCleared)
            }
            l.inhibitUntilMono = nil
            if l.inhibition == .userCleared { l.inhibition = nil }
        }

        if input.screenLocked || !input.sessionActive {
            guard l.phase != .closed else { return l }
            return l.closing(.sessionEnded, at: input.monotonic)
        }

        l.anchorPresent = l.anchor.map { a in
            input.callCapableRunning.contains { $0.bundleID == a.bundleID }
        } ?? false

        /// A gap nobody watched is credited in neither direction. If it is longer than
        /// what was left of the hold the latch closes, because a call can end while the
        /// lid is shut. If it is shorter, the hold is not spent on time nobody observed,
        /// which is what stops a two-minute lid-close ending a call the user is walking
        /// down the corridor to continue.
        if unobserved {
            switch l.phase {
            case .arming:
                l.phase = .closed
                l.armedSinceMono = nil
            case .held:
                let spent = input.monotonic - (l.lastLiveMono ?? input.monotonic)
                if observedGap >= l.holdBudget(policy) - spent {
                    return l.closing(.discontinuity, at: input.monotonic)
                }
                l.lastLiveMono = (l.lastLiveMono ?? input.monotonic) + monoDelta
            case .live, .closed:
                break
            }
        }
        let credited = unobserved ? 0 : monoDelta

        switch l.phase {
        case .closed:
            guard input.captureLive else {
                if l.quietSinceMono == nil { l.quietSinceMono = input.monotonic }
                return l
            }
            /// Asked before the quiet run is cleared, because the quiet that earns a
            /// re-arm is the quiet that came *before* this capture started. Clearing
            /// first would mean the counter could never be satisfied.
            let mayArm = l.canArm(input, policy)
            l.quietSinceMono = nil
            guard mayArm else { return l }
            l.inhibition = nil
            l.phase = .arming
            l.armedSinceMono = input.monotonic

        case .arming:
            guard input.captureLive else {
                l.phase = .closed
                l.armedSinceMono = nil
                l.quietSinceMono = input.monotonic
                return l
            }
            guard input.monotonic - (l.armedSinceMono ?? input.monotonic) >= policy.latchArmDwell else {
                return l
            }
            l.phase = .live
            l.lastLiveMono = input.monotonic
            l.heldSecondsThisEpisode = 0
            l.captureEndedWall = nil
            l.closeReason = nil
            l.adoptAnchor(input)
            l.basis = Self.basis(for: input)

        case .live:
            if input.captureLive {
                l.lastLiveMono = input.monotonic
                l.basis = Self.basis(for: input)
            } else {
                l.phase = .held
                l.captureEndedWall = input.wall
            }

        case .held:
            if input.captureLive {
                l.phase = .live
                l.lastLiveMono = input.monotonic
                l.basis = Self.basis(for: input)
                return l
            }
            l.heldSecondsThisEpisode += credited
            l.heldSecondsToday += credited
            if l.heldSecondsThisEpisode >= policy.latchEpisodeCeiling {
                return l.closing(.episodeCeiling, at: input.monotonic, inhibition: .episodeCeiling)
            }
            if l.heldSecondsToday >= policy.latchDailyCeiling {
                return l.closing(.dailyCeiling, at: input.monotonic, inhibition: .dailyCeiling)
            }
            if l.anchor != nil, !l.anchorPresent,
               input.monotonic - (l.lastLiveMono ?? input.monotonic) >= policy.latchAnchorQuitHold {
                return l.closing(.anchorQuit, at: input.monotonic)
            }
            if input.monotonic - (l.lastLiveMono ?? input.monotonic) >= l.holdBudget(policy) {
                return l.closing(.budgetSpent, at: input.monotonic)
            }
        }
        return l
    }

    // MARK: Helpers

    private func canArm(_ input: MeetingLatchInput, _ policy: BreakPolicy) -> Bool {
        switch inhibition {
        case .dailyCeiling, .disabled, .userCleared:
            return false
        case .episodeCeiling:
            guard let quiet = quietSinceMono else { return false }
            return input.monotonic - quiet >= policy.latchRearmQuiet
        case .none:
            return true
        }
    }

    /// Prefer attribution: "CoreAudio says this bundle has the microphone" beats "this
    /// window is in front", which beats "a conferencing app is running somewhere".
    /// A browser can only anchor through one of the first two, because a browser is
    /// running on every developer's Mac all day and its presence means nothing.
    private mutating func adoptAnchor(_ input: MeetingLatchInput) {
        if let attributed = input.attributedCallCapable {
            anchor = attributed
        } else if let frontmost = input.frontmostCallCapable {
            anchor = frontmost
        } else {
            anchor = input.callCapableRunning.first { $0.isConferencing }
        }
        anchorPresent = anchor.map { a in
            input.callCapableRunning.contains { $0.bundleID == a.bundleID }
        } ?? false
    }

    private static func basis(for input: MeetingLatchInput) -> MeetingLatchSignal.Basis {
        switch (input.micLive, input.cameraLive) {
        case (true, true):  return .both
        case (true, false): return .microphone
        case (false, true): return .camera
        case (false, false): return .none
        }
    }

    private func closing(
        _ reason: CloseReason,
        at monotonic: Double,
        inhibition newInhibition: MeetingLatchSignal.Inhibition? = nil
    ) -> MeetingLatch {
        var l = self
        l.phase = .closed
        l.closeReason = reason
        l.armedSinceMono = nil
        l.lastLiveMono = nil
        l.anchor = nil
        l.anchorPresent = false
        l.basis = .none
        l.quietSinceMono = monotonic
        if let newInhibition { l.inhibition = newInhibition }
        return l
    }
}
