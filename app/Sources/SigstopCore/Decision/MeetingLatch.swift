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
    /// From `TimeSource.continuousSeconds`. Every duration in the latch is a difference of
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
    /// Is the live capture the *policy* already hard-blocks on covering this instant —
    /// `SystemSignals.audioInputRunning || cameraRunning`?
    ///
    /// It is deliberately not implied by `micLive`. On a Mac with Krisp, Loopback or
    /// BlackHole installed the device signal is downgraded to `.unreliable`, so
    /// `audioInputRunning` is false for the whole of a real call, while `micLive` is true
    /// from CoreAudio's process table alone. The latch has to be able to tell those two
    /// apart, because in the second case nothing else in the app is blocking and the
    /// latch is the only thing standing between the user and a prompt in a meeting.
    ///
    /// Defaults to `true`, the reliable-device case: a caller that does not pass it is
    /// saying "the existing blocks cover the live call", which is what every Mac without
    /// a virtual audio driver does.
    public var liveCaptureAlreadyBlocks: Bool

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
        liveCaptureAlreadyBlocks: Bool = true,
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
        self.liveCaptureAlreadyBlocks = liveCaptureAlreadyBlocks
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

    /// True only while the latch is holding a break back. It is normally false while
    /// capture is actually live, because the live microphone and camera hard blocks
    /// already cover that, and `heldSeconds` then measures the latch's *own* footprint
    /// and nothing else, which is what makes the ceilings below mean anything.
    ///
    /// The one exception is the `.unreliable` Mac, where those blocks are false for the
    /// whole call: there the latch blocks during the live call too, and charges itself
    /// for it. `captureLive` says which of the two this is.
    public var isHolding: Bool
    /// Set when the hold is over capture that is running *right now* rather than over
    /// capture that has stopped. Only ever true on a Mac where nothing else blocks it.
    public var captureLive: Bool
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
        captureLive: Bool = false,
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
        self.captureLive = captureLive
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
        if captureLive {
            return "Holding your break. \(what) is live right now\(who)."
        }
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
    /// Capture is live and the policy's own live blocks are not covering it, so the latch
    /// is the thing doing the blocking. The `.unreliable` Mac, and nothing else.
    var liveNeedsLatch: Bool = false
    /// Unobserved seconds this episode has already been forgiven in `.held`. Bounded, or
    /// a permanently throttled process holds a break back for ever: see `advanced`.
    var unobservedHeldThisEpisode: TimeInterval = 0

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

    public var isHolding: Bool { phase == .held || (phase == .live && liveNeedsLatch) }

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
        let holding = manual || isHolding
        let coldStart = monotonic - constructedMono < policy.latchColdStartGrace && callCapablePresent
        var closes: Date?
        if manual, let until = manualHoldUntilMono {
            closes = wall.addingTimeInterval(until - monotonic)
        } else if phase == .held, let live = lastLiveMono {
            closes = wall.addingTimeInterval(max(0, holdBudget(policy) - (monotonic - live)))
        }
        return MeetingLatchSignal(
            isHolding: holding,
            captureLive: !manual && phase == .live && liveNeedsLatch,
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

        /// The switch ends every kind of hold this file can produce, including the one
        /// the user asserted by hand. The Settings row says this controls holding; if it
        /// left a manual hold running for its remaining two hours it would be lying, and
        /// the only escape would be a second button the user has no reason to look for.
        guard input.enabled else {
            var off = l
            off.manualHoldUntilMono = nil
            /// A ceiling that has already tripped outlives the switch. Overwriting it
            /// with `.disabled`, which the line below then clears, would make flicking
            /// the switch off and on a way to buy a fresh three hours of holding.
            let ceiling = l.inhibition == .episodeCeiling || l.inhibition == .dailyCeiling
            return off.closing(
                .disabled, at: input.monotonic, inhibition: ceiling ? l.inhibition : .disabled
            )
        }
        /// `.disabled` is the switch's own footprint, not a ceiling, so it clears the
        /// moment the switch comes back — exactly as the `inhibitUntilMono` expiry below
        /// clears `.userCleared`. Left in place it is the one inhibition nothing ever
        /// resets (`canArm` refuses it, and the reset in the `.closed` branch sits behind
        /// `guard mayArm`), so turning the feature off and on again would silently kill
        /// it for the lifetime of the process.
        if l.inhibition == .disabled { l.inhibition = nil }

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

            case .live:
                /// Capture was live when the machine was last looked at, and then nobody
                /// was looking. If it is live again now it is the same call and nothing
                /// is owed. If it is not, there is no way to know *when* in the gap it
                /// stopped, so the gap is charged as though it stopped at the start of
                /// it — and a gap longer than the whole hold cannot leave a call still
                /// running, which is the rule this section already states for `.held`.
                ///
                /// Without this a lid closed mid-call turned into a fresh twenty-minute
                /// hold on wake the next morning, explained with a sentence that was
                /// fifteen hours out of date.
                if input.captureLive { break }
                if observedGap >= l.holdBudget(policy) {
                    return l.closing(.discontinuity, at: input.monotonic)
                }
                l.phase = .held
                l.liveNeedsLatch = false
                l.lastLiveMono = input.monotonic - observedGap
                l.captureEndedWall = input.wall.addingTimeInterval(-observedGap)
                l.unobservedHeldThisEpisode += observedGap

            case .held:
                let spent = input.monotonic - (l.lastLiveMono ?? input.monotonic)
                /// Two bounds, and both are needed. The first is the single long gap: a
                /// four-hour sleep ends the call. The second is the accumulation: a
                /// process throttled to 12 s samples produces gaps that are each far
                /// shorter than the remaining hold, and refunding every one of them into
                /// `lastLiveMono` held the break back for ever while `heldSeconds` stayed
                /// at zero, so no ceiling could ever trip either. CLAUDE.md §3.4 names
                /// this exact case; a hold has to survive a throttle, not outlive one.
                if observedGap >= l.holdBudget(policy) - spent
                    || l.unobservedHeldThisEpisode + observedGap >= l.holdBudget(policy) {
                    return l.closing(.discontinuity, at: input.monotonic)
                }
                l.unobservedHeldThisEpisode += observedGap
                l.lastLiveMono = (l.lastLiveMono ?? input.monotonic) + monoDelta

            case .closed:
                break
            }
        }
        /// Unobserved time that was forgiven above is still time the latch spent holding,
        /// so it is charged to the ceilings even though it is not charged to the hold.
        /// It is bounded by the budget check above, which is what stops one long sleep
        /// from spending the whole day's ceiling on a call that ended before it.
        let credited = unobserved ? (l.phase == .held ? observedGap : 0) : monoDelta

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
            l.unobservedHeldThisEpisode = 0
            l.captureEndedWall = nil
            l.closeReason = nil
            l.adoptAnchor(input)
            l.basis = Self.basis(for: input)
            l.liveNeedsLatch = !input.liveCaptureAlreadyBlocks

        case .live:
            if input.captureLive {
                l.lastLiveMono = input.monotonic
                l.basis = Self.basis(for: input)
                /// The `.unreliable` Mac. `audioInputRunning` and `cameraRunning` are
                /// both false for the whole of a real call there, so the two live hard
                /// blocks never fire and the only thing left is this latch — which used
                /// to be deliberately silent in `.live`, leaving that Mac with the
                /// protection inverted: absent during the call, present after it. When
                /// the latch is the one blocking it charges itself for the time, exactly
                /// as it does for the trailing edge, so the ceilings keep meaning
                /// something on precisely the machines that lean on them hardest.
                l.liveNeedsLatch = !input.liveCaptureAlreadyBlocks
                if l.liveNeedsLatch {
                    l.heldSecondsThisEpisode += credited
                    l.heldSecondsToday += credited
                    if let stopped = l.ceilingTripped(policy, at: input.monotonic) { return stopped }
                }
            } else {
                l.phase = .held
                l.liveNeedsLatch = false
                l.captureEndedWall = input.wall
            }

        case .held:
            if input.captureLive {
                l.phase = .live
                l.lastLiveMono = input.monotonic
                l.basis = Self.basis(for: input)
                l.liveNeedsLatch = !input.liveCaptureAlreadyBlocks
                return l
            }
            l.heldSecondsThisEpisode += credited
            l.heldSecondsToday += credited
            if let stopped = l.ceilingTripped(policy, at: input.monotonic) { return stopped }
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

    /// The two circuit breakers, checked wherever the latch charges itself for time.
    private func ceilingTripped(_ policy: BreakPolicy, at monotonic: Double) -> MeetingLatch? {
        if heldSecondsThisEpisode >= policy.latchEpisodeCeiling {
            return closing(.episodeCeiling, at: monotonic, inhibition: .episodeCeiling)
        }
        if heldSecondsToday >= policy.latchDailyCeiling {
            return closing(.dailyCeiling, at: monotonic, inhibition: .dailyCeiling)
        }
        return nil
    }

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
        l.liveNeedsLatch = false
        l.quietSinceMono = monotonic
        if let newInhibition { l.inhibition = newInhibition }
        return l
    }
}
