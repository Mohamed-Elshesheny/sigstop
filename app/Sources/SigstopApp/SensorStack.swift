import Foundation
import SigstopCore
import SigstopSensors

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
    let processes: ProcessCollector
    let git: GitCollector
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
        let processes = ProcessCollector(permissions: permissions)
        let git = GitCollector(permissions: permissions)

        self.time = time
        self.permissions = permissions
        self.frontmost = frontmost
        self.system = system
        self.audio = audio
        self.camera = camera
        self.audioProcesses = audioProcesses
        self.accessibility = accessibility
        self.idle = idle
        self.processes = processes
        self.git = git
        self.context = ContextEngine(
            time: time,
            permissions: permissions,
            frontmost: frontmost,
            system: system,
            audio: audio,
            accessibility: accessibility,
            idle: idle,
            processes: processes,
            git: git,
            settings: settings,
            workClock: { [workClock] in workClock?.read() ?? .zero }
        )
    }

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

enum AudioDeviceHold: Sendable, Hashable {
    case notRunning
    case held
    case runningButUnheld
}

struct RawSignals: Sendable {
    let session: SessionState
    let power: PowerState
    let audio: AudioInputState
    let audioCaveat: String?
    let camera: CameraInputState
    let cameraCaveat: String?
    let cameraDevices: [String]
    let audioProcesses: AudioProcessSnapshot
    let input: InputActivity
    let frontmost: FrontmostSnapshot
    let systemAsleep: Bool
    let tiers: SignalTierSet

    var callCapableRunning: [CallCapableApp] {
        CallCapableApps.resolve(frontmost.runningBundleIDs)
    }

    var attributedCallCapable: CallCapableApp? {
        guard let holders = audioProcesses.inputBundleIDs else { return nil }
        return CallCapableApps.resolve(holders).first
    }

    var frontmostCallCapable: CallCapableApp? {
        frontmost.frontmost.bundleID.flatMap(CallCapableApps.match)
    }

    var micLiveForLatch: Bool {
        guard let holders = audioProcesses.inputBundleIDs else {
            return audio.contributesToMeeting
        }
        if !CallCapableApps.resolve(holders).isEmpty { return true }
        guard audio.contributesToMeeting else { return false }
        if audioProcesses.unnamedInputHolders > 0 { return true }
        return holders.contains { !CallCapableApps.isNeverAMeeting($0) }
    }

    var audioDeviceHold: AudioDeviceHold {
        guard audio.contributesToMeeting else { return .notRunning }
        guard let any = audioProcesses.anyInputRunning else { return .held }
        return any ? .held : .runningButUnheld
    }

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
