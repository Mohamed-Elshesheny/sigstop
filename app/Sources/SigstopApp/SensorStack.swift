import Foundation
import SigstopCore
import SigstopSensors

/// Every macOS-facing collector, built once and handed to the context engine.
///
/// The engine will happily construct its own collectors, but then nobody else can read
/// them. Two callers need the raw signals rather than the inference on top of them:
///
///   * `AppModel`, which must build `SystemSignals` for the decision engine, a hard
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
    let camera: CameraDeviceCollector
    let audioProcesses: AudioProcessCollector
    let accessibility: AccessibilityCollector
    let idle: IdleCollector
    let context: ContextEngine

    init(settings: SigstopSettings, time: any TimeSource = SystemTimeSource(), workClock: WorkClockBox? = nil) {
        let permissions = PermissionBroker(settings: settings)
        let frontmost = FrontmostAppCollector(time: time)
        let system = SystemStateCollector(time: time)
        let audio = AudioDeviceCollector(time: time)
        let camera = CameraDeviceCollector(time: time)
        let audioProcesses = AudioProcessCollector(time: time)
        let accessibility = AccessibilityCollector()
        let idle = IdleCollector()

        self.time = time
        self.permissions = permissions
        self.frontmost = frontmost
        self.system = system
        self.audio = audio
        self.camera = camera
        self.audioProcesses = audioProcesses
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

    /// The two collectors the context engine does not own. Both are permission-free and
    /// both are event-driven, so this is registration, not polling.
    func startExtraCollectors() {
        camera.start()
        audioProcesses.start()
    }

    func stopExtraCollectors() {
        camera.stop()
        audioProcesses.stop()
    }

    func refreshExtraCollectors() {
        camera.refresh()
        audioProcesses.refresh()
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
            camera: camera.state(),
            cameraCaveat: camera.unreliabilityExplanation(),
            cameraDevices: camera.devices(),
            audioProcesses: audioProcesses.snapshot(),
            input: idle.read(),
            frontmost: frontmost.snapshot(),
            systemAsleep: system.isSystemAsleep,
            tiers: permissions.currentTiers()
        )
    }
}

/// What an input device that is running means, once attribution has been consulted.
enum AudioDeviceHold: Sendable, Hashable {
    case notRunning
    /// Running, and either a process has it or the process table could not be read.
    case held
    /// Running, the table was read, and nothing at all has input open. A virtual device.
    case runningButUnheld
}

/// One instant of Tier 0, before anything interprets it.
struct RawSignals: Sendable {
    let session: SessionState
    let power: PowerState
    let audio: AudioInputState
    let audioCaveat: String?
    let camera: CameraInputState
    let cameraCaveat: String?
    /// Device names, for `--doctor`. Never anything a camera saw.
    let cameraDevices: [String]
    /// Which processes have the microphone, when CoreAudio's process table could be read.
    let audioProcesses: AudioProcessSnapshot
    let input: InputActivity
    let frontmost: FrontmostSnapshot
    let systemAsleep: Bool
    let tiers: SignalTierSet

    /// The facts, and only the facts, the interruption policy is allowed to block on.
    ///
    /// The fields left at their defaults are not "false", they are *unobservable without
    /// a permission this app refuses to request* (docs/PRIVACY.md §3.3). Each one is
    /// named in `--doctor` with the reason, rather than being quietly reported as absent:
    ///
    ///   * `displayCaptured`, would need ScreenCaptureKit and the Screen Recording grant.
    ///     `CGDisplayIsCaptured`, which docs/BREAK-DECISION.md used to name as the
    ///     source, has been deprecated since macOS 10.9 and no longer compiles, and
    ///     CoreMediaIO enumerates no display-capture device. Consequence, said out loud
    ///     in `--doctor`: `HardBlock.screenBeingShared` cannot fire.
    ///   * `focusModeActive`, `nil`, which the policy already distinguishes from `false`:
    ///     the only public route is the Focus status Shortcuts action, not an API.
    ///   * `frontmostIsPresentationApp`, depends on a window title (Tier 1) we may not
    ///     have, so it is never asserted from app identity alone.
    ///   * `batteryFraction`, `nil` rather than invented; `isCharging` comes from the
    ///     real power source flag, which is permission-free.
    ///
    /// `frontmostIsFullscreen` is left false here and filled in by the caller from the
    /// window-geometry hint the context engine already computed, so the geometry API is
    /// asked once per sample rather than twice.
    /// Call-capable apps running right now, folded to canonical apps.
    var callCapableRunning: [CallCapableApp] {
        CallCapableApps.resolve(frontmost.runningBundleIDs)
    }

    /// The call-capable app CoreAudio attributes microphone input to, when the process
    /// table could be read and it named one. This is the latch's best anchor, and the
    /// only route by which a browser can anchor a call without being frontmost.
    var attributedCallCapable: CallCapableApp? {
        guard let holders = audioProcesses.inputBundleIDs else { return nil }
        return CallCapableApps.resolve(holders).first
    }

    var frontmostCallCapable: CallCapableApp? {
        frontmost.frontmost.bundleID.flatMap(CallCapableApps.match)
    }

    /// Is a microphone live *for the purposes of the call latch*?
    ///
    /// Deliberately not the same question as `SystemSignals.audioInputRunning`, which is
    /// left exactly as it was. Attribution is used here in three narrow ways and nowhere
    /// else:
    ///
    ///  * a call-capable app holding input counts even when the device signal has been
    ///    downgraded to `.unreliable`. On a Krisp or Loopback Mac that downgrade
    ///    currently switches meeting detection off completely, mic live or not, which is
    ///    the worst gap in the whole feature;
    ///  * a readable-and-empty process table is evidence of *absence*, so a device left
    ///    open by nobody does not arm the latch;
    ///  * a table in which the only holders are Siri and dictation does not arm it either.
    ///
    /// When the table cannot be read at all, this falls back to the unattributed device
    /// bit, which is what the app has always used.
    var micLiveForLatch: Bool {
        guard let holders = audioProcesses.inputBundleIDs else {
            return audio.contributesToMeeting
        }
        if !CallCapableApps.resolve(holders).isEmpty { return true }
        guard audio.contributesToMeeting else { return false }
        if audioProcesses.unnamedInputHolders > 0 { return true }
        return holders.contains { !CallCapableApps.isNeverAMeeting($0) }
    }

    /// The device bit the interruption policy is allowed to hard-block on.
    ///
    /// This used to be the bare device bit, while `micLiveForLatch` one method above asked
    /// the attributed question and was handed only to the call latch. On a Mac where a
    /// driver holds the input open and no process has it, the two therefore disagreed in
    /// the same instant, from the same signal: the latch correctly declined to arm and the
    /// hard block fired anyway, for an hour, until the collector's calibration rescued it.
    ///
    /// Three answers, in the order they are trusted:
    ///
    ///  * device bit false, nothing is running, false;
    ///  * process table unreadable, no better evidence exists, so the bare bit, exactly as
    ///    before;
    ///  * table read and nobody at all has input, named or not, evidence of absence.
    ///
    /// The dwell that guards the third one lives in `AppModel`, which is the only place
    /// with a clock: the per-object `IsRunningInput` listener's latency against the device
    /// bit is unmeasured, and a transient disagreement at the start of every real call
    /// would be worse than the bug this fixes.
    var audioDeviceHold: AudioDeviceHold {
        guard audio.contributesToMeeting else { return .notRunning }
        guard let any = audioProcesses.anyInputRunning else { return .held }
        return any ? .held : .runningButUnheld
    }

    /// Are the two live hard blocks the interruption policy already owns covering this
    /// instant? Exactly `systemSignals.audioInputRunning || .cameraRunning`, named here
    /// so the latch can be told the one thing `micLiveForLatch` deliberately hides: on a
    /// Krisp / Loopback / BlackHole Mac the device signal is `.unreliable`, so both of
    /// those are false for the whole of a real call while attribution says the mic is
    /// live. The latch has to block during the call itself on that Mac, because nothing
    /// else will.
    var liveCaptureAlreadyBlocks: Bool {
        audio.contributesToMeeting || camera.contributesToMeeting
    }

    var systemSignals: SystemSignals {
        SystemSignals(
            audioInputRunning: audio.contributesToMeeting,
            cameraRunning: camera.contributesToMeeting,
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
