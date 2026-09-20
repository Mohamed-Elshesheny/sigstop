import Foundation
import SigstopCore
import SigstopSensors

/// Every macOS-facing collector, built once and handed to the context engine.
///
/// The engine will happily construct its own collectors, but then nobody else can read
/// them. Two callers need the raw signals rather than the inference on top of them:
///
///   * `AppModel`, which must build `SystemSignals` for the decision engine — a hard
///     block is a *fact* (`InterruptionPolicy.hardBlock`), and facts come from the
///     collectors, not from a classification;
///   * `Doctor`, whose whole job is to print each signal separately, including the ones
///     that are unavailable.
///
/// So the stack is constructed here and injected, and there is exactly one of each
/// collector in the process.
@MainActor
struct SensorStack {
    let time: any TimeSource
    let permissions: PermissionBroker
    let frontmost: FrontmostAppCollector
    let system: SystemStateCollector
    let audio: AudioDeviceCollector
    let accessibility: AccessibilityCollector
    let idle: IdleCollector
    let context: ContextEngine

    init(settings: SigstopSettings, time: any TimeSource = SystemTimeSource(), workClock: WorkClockBox? = nil) {
        let permissions = PermissionBroker(settings: settings)
        let frontmost = FrontmostAppCollector(time: time)
        let system = SystemStateCollector(time: time)
        let audio = AudioDeviceCollector(time: time)
        let accessibility = AccessibilityCollector()
        let idle = IdleCollector()

        self.time = time
        self.permissions = permissions
        self.frontmost = frontmost
        self.system = system
        self.audio = audio
        self.accessibility = accessibility
        self.idle = idle
        self.context = ContextEngine(
            time: time,
            permissions: permissions,
            frontmost: frontmost,
            system: system,
            audio: audio,
            accessibility: accessibility,
            idle: idle,
            workClock: { [workClock] in workClock?.read() ?? .zero }
        )
    }

    /// Read every Tier 0 collector at one instant.
    ///
    /// Grouped into a value so the model and the doctor cannot drift into asking the
    /// collectors slightly different questions in slightly different orders.
    func readSignals() -> RawSignals {
        RawSignals(
            session: system.sessionState(),
            power: system.powerState(),
            audio: audio.state(),
            audioCaveat: audio.unreliabilityExplanation(),
            input: idle.read(),
            frontmost: frontmost.snapshot(),
            systemAsleep: system.isSystemAsleep,
            tiers: permissions.currentTiers()
        )
    }
}

/// One instant of Tier 0, before anything interprets it.
struct RawSignals: Sendable {
    let session: SessionState
    let power: PowerState
    let audio: AudioInputState
    let audioCaveat: String?
    let input: InputActivity
    let frontmost: FrontmostSnapshot
    let systemAsleep: Bool
    let tiers: SignalTierSet

    /// The facts — and only the facts — the interruption policy is allowed to block on.
    ///
    /// The fields left at their defaults are not "false", they are *unobservable without
    /// a permission this app refuses to request* (docs/PRIVACY.md §3.3). Each one is
    /// named in `--doctor` with the reason, rather than being quietly reported as absent:
    ///
    ///   * `cameraRunning` — no permission-free API; the camera-in-use bit requires
    ///     either a capture session or a private symbol.
    ///   * `displayCaptured` — would need ScreenCaptureKit and the Screen Recording grant.
    ///   * `focusModeActive` — `nil`, which the policy already distinguishes from `false`:
    ///     the only public route is the Focus status Shortcuts action, not an API.
    ///   * `frontmostIsPresentationApp` — depends on a window title (Tier 1) we may not
    ///     have, so it is never asserted from app identity alone.
    ///   * `batteryFraction` — `nil` rather than invented; `isCharging` comes from the
    ///     real power source flag, which is permission-free.
    ///
    /// `frontmostIsFullscreen` is left false here and filled in by the caller from the
    /// window-geometry hint the context engine already computed, so the geometry API is
    /// asked once per sample rather than twice.
    var systemSignals: SystemSignals {
        SystemSignals(
            audioInputRunning: audio.contributesToMeeting,
            cameraRunning: false,
            displayCaptured: false,
            screenLocked: session.screenLocked,
            systemSleeping: systemAsleep || session.displaysAsleep,
            fastUserSwitched: !session.sessionActive,
            focusModeActive: nil,
            frontmostIsFullscreen: false,
            frontmostIsPresentationApp: false,
            batteryFraction: nil,
            isCharging: !power.onBattery,
            lowPowerMode: power.lowPowerMode
        )
    }
}
