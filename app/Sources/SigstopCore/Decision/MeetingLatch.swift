import Foundation

public struct CallCapableApp: Sendable, Codable, Hashable {
    public let bundleID: String
    public let name: String
    public let isConferencing: Bool

    public init(bundleID: String, name: String, isConferencing: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.isConferencing = isConferencing
    }
}

public struct MeetingLatchInput: Sendable, Hashable {
    public var monotonic: Double
    public var wall: Date
    public var dayIndex: Int

    public var micLive: Bool
    public var cameraLive: Bool
    public var liveCaptureAlreadyBlocks: Bool

    public var callCapableRunning: [CallCapableApp]
    public var attributedCallCapable: CallCapableApp?
    public var frontmostCallCapable: CallCapableApp?

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

public struct MeetingLatchSignal: Sendable, Codable, Hashable {

    public enum Basis: String, Sendable, Codable, Hashable {
        case none
        case microphone
        case camera
        case both
        case manual
    }

    public enum Inhibition: String, Sendable, Codable, Hashable {
        case disabled
        case userCleared
        case episodeCeiling
        case dailyCeiling
    }

    public var isHolding: Bool
    public var captureLive: Bool
    public var suspectsCall: Bool
    public var basis: Basis
    public var anchorName: String?
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

public struct MeetingLatch: Sendable, Codable, Hashable {

    public enum Phase: String, Sendable, Codable, Hashable {
        case closed
        case arming
        case live
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
    var liveNeedsLatch: Bool = false
    var unobservedHeldThisEpisode: TimeInterval = 0

    public private(set) var heldSecondsThisEpisode: TimeInterval = 0
    public private(set) var heldSecondsToday: TimeInterval = 0
    public private(set) var dayIndex: Int = 0

    public init() {}

    public static func started(at monotonic: Double, wall: Date, dayIndex: Int) -> MeetingLatch {
        var l = MeetingLatch()
        l.lastAdvanceMono = monotonic
        l.lastAdvanceWall = wall
        l.constructedMono = monotonic
        l.dayIndex = dayIndex
        return l
    }

    public func restoringDailyHold(seconds: TimeInterval, dayIndex: Int) -> MeetingLatch {
        var l = self
        guard dayIndex == l.dayIndex else { return l }
        l.heldSecondsToday = max(0, seconds)
        if l.heldSecondsToday >= BreakPolicy.default.latchDailyCeiling {
            l.inhibition = .dailyCeiling
        }
        return l
    }

    public func resettingDailyHold() -> MeetingLatch {
        var l = self
        l.heldSecondsToday = 0
        if l.inhibition == .dailyCeiling { l.inhibition = nil }
        return l
    }

    public var isHolding: Bool { phase == .held || (phase == .live && liveNeedsLatch) }

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

    public func assertedByUser(at monotonic: Double, policy: BreakPolicy) -> MeetingLatch {
        var l = self
        l.manualHoldUntilMono = monotonic + policy.latchManualHold
        l.inhibitUntilMono = nil
        l.inhibition = nil
        return l
    }

    public func clearedByUser(at monotonic: Double, policy: BreakPolicy) -> MeetingLatch {
        var l = self
        l.manualHoldUntilMono = nil
        l.inhibitUntilMono = monotonic + policy.latchManualInhibit
        return l.closing(.userCleared, at: monotonic, inhibition: .userCleared)
    }

    public func advanced(_ input: MeetingLatchInput, policy: BreakPolicy) -> MeetingLatch {
        var l = self
        let monoDelta = max(0, input.monotonic - l.lastAdvanceMono)
        let wallDelta = input.wall.timeIntervalSince(l.lastAdvanceWall)
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
            var off = l
            off.manualHoldUntilMono = nil
            let ceiling = l.inhibition == .episodeCeiling || l.inhibition == .dailyCeiling
            return off.closing(
                .disabled, at: input.monotonic, inhibition: ceiling ? l.inhibition : .disabled
            )
        }
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

        if unobserved {
            switch l.phase {
            case .arming:
                l.phase = .closed
                l.armedSinceMono = nil

            case .live:
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
        let credited = unobserved ? (l.phase == .held ? observedGap : 0) : monoDelta

        switch l.phase {
        case .closed:
            guard input.captureLive else {
                if l.quietSinceMono == nil { l.quietSinceMono = input.monotonic }
                return l
            }
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
