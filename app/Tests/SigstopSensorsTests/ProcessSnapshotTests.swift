import Foundation
import Testing

@testable import SigstopCore
@testable import SigstopSensors

/// The Tier 2 process snapshot, tested the way §3.3 says providers must be: by building a
/// `SignalContext` literal and calling a pure function. Nothing here starts a run loop,
/// opens a window, or reads the real process table.
private let editor = AppIdentity(bundleID: BundleIDs.vscode, localizedName: "Code", pid: 101)
private let terminal = AppIdentity(bundleID: BundleIDs.terminal, localizedName: "Terminal", pid: 102)
private let browser = AppIdentity(bundleID: BundleIDs.chrome, localizedName: "Google Chrome", pid: 103)

private func context(
    app: AppIdentity = editor,
    tiers: SignalTierSet = [.tier0, .tier1, .tier2],
    processes: ProcessSnapshot? = nil,
    title: String? = "main.swift — sigstop"
) -> SignalContext {
    SignalContext(
        now: Date(timeIntervalSince1970: 1_700_000_000),
        available: tiers,
        frontmost: app,
        input: InputActivity(idleSeconds: 3, source: .hidSystemState),
        windowTitle: title,
        processes: processes
    )
}

private func snapshot(
    matched: Set<ToolToken> = [],
    children: Set<ToolToken> = [],
    tracedUnderFrontmost: Bool = false,
    tracedElsewhere: Bool = false
) -> ProcessSnapshot {
    ProcessSnapshot(
        matchedTools: matched,
        childrenOfFrontmost: children,
        tracedUnderFrontmost: tracedUnderFrontmost,
        tracedElsewhere: tracedElsewhere,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func classify(_ signals: SignalContext) -> ActivityObservation {
    let registry = ProviderRegistry()
    let classified = registry.classify(signals)
    return ConfidenceEngine.observation(
        verdict: classified.verdict,
        providerID: classified.providerID,
        signals: signals,
        concurrent: ConcurrentStates()
    )
}

// MARK: - The allowlist

@Test func allowlistMatchesOnlyWholeNames() {
    #expect("lldb".withCString { ToolAllowlist.token(comm: $0) } == .lldb)
    #expect("debugserver".withCString { ToolAllowlist.token(comm: $0) } == .debugserver)
    #expect("claude".withCString { ToolAllowlist.token(comm: $0) } == .claudeCLI)
    #expect("lldbx".withCString { ToolAllowlist.token(comm: $0) } == nil)
    #expect("lld".withCString { ToolAllowlist.token(comm: $0) } == nil)
    #expect("".withCString { ToolAllowlist.token(comm: $0) } == nil)
}

/// `node` and `python3` are on nobody's allowlist on purpose: eleven `node` processes were
/// running on the development machine and every one of them was an editor helper. Matching
/// bare `node` would fire constantly in any editor that ships an extension host.
@Test func interpretersAreNotOnTheAllowlist() {
    #expect("node".withCString { ToolAllowlist.token(comm: $0) } == nil)
    #expect("python3".withCString { ToolAllowlist.token(comm: $0) } == nil)
    #expect("Python".withCString { ToolAllowlist.token(comm: $0) } == nil)
}

@Test func everyAllowlistNameFitsInPComm() {
    for entry in ToolAllowlist.entries {
        #expect(entry.comm.utf8.count <= 15, "\(entry.comm) would be truncated by MAXCOMLEN")
    }
}

/// The tokens that need argv are named as undetectable rather than quietly reported absent.
@Test func argvShapedTokensAreDeclaredUndetectable() {
    let allowed = Set(ToolAllowlist.entries.map(\.token))
    for token in ToolAllowlist.undetectable {
        #expect(!allowed.contains(token), "\(token) cannot be both detected and undetectable")
    }
    #expect(ToolAllowlist.undetectable.contains(.nodeInspect))
    #expect(ToolAllowlist.undetectable.contains(.debugpy))
    #expect(ToolAllowlist.undetectable.contains(.pytest))
}

// MARK: - Ancestry

/// A terminal's shell sits under a root-owned `login`, so the walk must not stop at a
/// process whose own details are unreadable. Only the parent link is needed, and the
/// kernel supplies it for every process regardless of owner.
@Test func ancestryWalksThroughAnIntermediateProcess() {
    let parents: [pid_t: pid_t] = [900: 800, 800: 102, 102: 1]
    #expect(ProcessCollector.descends(900, from: 102, parents: parents))
    #expect(ProcessCollector.descends(800, from: 102, parents: parents))
    #expect(!ProcessCollector.descends(102, from: 900, parents: parents))
}

@Test func ancestryStopsAtLaunchdAndSurvivesACycle() {
    #expect(!ProcessCollector.descends(900, from: 102, parents: [900: 1]))
    #expect(!ProcessCollector.descends(900, from: 102, parents: [900: 901, 901: 900]))
    #expect(!ProcessCollector.descends(102, from: 102, parents: [102: 1]))
    #expect(!ProcessCollector.descends(900, from: 0, parents: [900: 0]))
}

// MARK: - The opt-in

@Test func theCollectorReadsNothingWhenTheSwitchIsOff() {
    let broker = PermissionBroker(settings: .default, trustCheck: { false })
    let collector = ProcessCollector(permissions: broker)
    let result = collector.snapshot(
        frontmost: editor,
        input: InputActivity(idleSeconds: 1, source: .hidSystemState),
        power: .plugged,
        now: Date()
    )
    #expect(result == nil)
    #expect(collector.lastOutcome == .optedOut)
}

/// The two Tier 2 switches are independent. Opting into a branch name must not enumerate
/// the process table, which is the whole reason `processContextPermitted()` exists.
@Test func theGitOptInDoesNotTurnOnProcessScanning() {
    var settings = SigstopSettings.default
    settings.gitContextEnabled = true
    let broker = PermissionBroker(settings: settings, trustCheck: { false })
    #expect(broker.currentTiers().contains(.tier2))
    #expect(broker.gitContextPermitted())
    #expect(!broker.processContextPermitted())

    let collector = ProcessCollector(permissions: broker)
    #expect(collector.snapshot(
        frontmost: editor,
        input: InputActivity(idleSeconds: 1, source: .hidSystemState),
        power: .plugged,
        now: Date()
    ) == nil)
    #expect(collector.lastOutcome == .optedOut)
}

@Test func theProcessOptInAloneRaisesTierTwo() {
    var settings = SigstopSettings.default
    settings.processContextEnabled = true
    let broker = PermissionBroker(settings: settings, trustCheck: { false })
    #expect(broker.currentTiers().contains(.tier2))
    #expect(broker.processContextPermitted())
    #expect(!broker.gitContextPermitted())
}

// MARK: - The gate

@Test func theGateDeclinesWhenTheFrontmostAppIsNotAnEditorOrTerminal() {
    var settings = SigstopSettings.default
    settings.processContextEnabled = true
    let collector = ProcessCollector(
        permissions: PermissionBroker(settings: settings, trustCheck: { false })
    )
    let result = collector.snapshot(
        frontmost: browser,
        input: InputActivity(idleSeconds: 1, source: .hidSystemState),
        power: .plugged,
        now: Date()
    )
    #expect(result == nil)
    guard case .skipped = collector.lastOutcome else {
        Issue.record("expected a skipped outcome, got \(collector.lastOutcome)")
        return
    }
}

@Test func theGateDeclinesWhenIdleOrThrottledOrSavingPower() {
    var settings = SigstopSettings.default
    settings.processContextEnabled = true
    let broker = PermissionBroker(settings: settings, trustCheck: { false })

    let idle = ProcessCollector(permissions: broker)
    #expect(idle.snapshot(
        frontmost: editor,
        input: InputActivity(idleSeconds: 400, source: .hidSystemState),
        power: .plugged,
        now: Date()
    ) == nil)

    let hot = ProcessCollector(permissions: broker)
    #expect(hot.snapshot(
        frontmost: editor,
        input: InputActivity(idleSeconds: 1, source: .hidSystemState),
        power: PowerState(onBattery: false, lowPowerMode: false, thermal: .serious),
        now: Date()
    ) == nil)

    let saving = ProcessCollector(permissions: broker)
    #expect(saving.snapshot(
        frontmost: editor,
        input: InputActivity(idleSeconds: 1, source: .hidSystemState),
        power: PowerState(onBattery: true, lowPowerMode: true, thermal: .nominal),
        now: Date()
    ) == nil)
}

// MARK: - What the providers do with it

/// The state before this change, and it must remain the answer when the snapshot is
/// absent: CODING, never DEBUGGING, because guessing between siblings is what §4.1 forbids.
@Test func withoutAProcessSnapshotAnEditorStaysCoding() {
    let observation = classify(context(processes: nil))
    #expect(observation.activity == .coding)
}

@Test func tierTwoEvidenceIsDroppedWhenTierTwoIsNotAvailable() {
    let signals = context(
        tiers: [.tier0, .tier1],
        processes: snapshot(matched: [.debugserver], tracedUnderFrontmost: true)
    )
    let observation = classify(signals)
    #expect(observation.activity == .coding)
    #expect(!observation.tiersUsed.contains(.tier2))
}

@Test func aTracedProcessUnderTheFrontmostAppReachesDebugging() {
    let observation = classify(context(processes: snapshot(tracedUnderFrontmost: true)))
    #expect(observation.activity == .debugging)
    #expect(observation.evidence.contains { $0.id.rawValue == "process.traced" })
    #expect(observation.confidence.value <= ConfidenceEngine.debuggingCeiling)
}

@Test func aNamedDebuggerReachesDebuggingAndClearsTheCorpusFloor() {
    let observation = classify(context(processes: snapshot(
        matched: [.debugserver], children: [.debugserver]
    )))
    #expect(observation.activity == .debugging)
    #expect(observation.confidence.value >= 0.85)
    #expect(observation.confidence.value <= ConfidenceEngine.debuggingCeiling)
}

/// A debugger sitting at a prompt with no target looks exactly like one attached, which is
/// the failure docs/ACTIVITY-DETECTION.md §7.2 names. `P_TRACED` elsewhere is the thing
/// that tells them apart, so it must add confidence rather than replace the verdict.
@Test func tracingElsewhereCorroboratesANamedDebuggerWithoutBeingAVerdict() {
    let bare = classify(context(processes: snapshot(matched: [.lldb])))
    let attached = classify(context(processes: snapshot(matched: [.lldb], tracedElsewhere: true)))
    #expect(bare.activity == .debugging)
    #expect(attached.activity == .debugging)
    #expect(!bare.evidence.contains { $0.id.rawValue == "process.tracedElsewhere" })
    #expect(attached.evidence.contains { $0.id.rawValue == "process.tracedElsewhere" })
    /// Both land on the 0.90 activity ceiling, which is the point: corroboration is cited
    /// in the reasoning a user can read, and it does not buy a number the ceiling forbids.
    #expect(attached.confidence.value == ConfidenceEngine.debuggingCeiling)
    #expect(bare.confidence.value == ConfidenceEngine.debuggingCeiling)

    let nothingNamed = classify(context(processes: snapshot(tracedElsewhere: true)))
    #expect(nothingNamed.activity == .coding)
}

@Test func aTerminalWithADebuggerInItIsDebuggingNotTerminalWork() {
    let plain = classify(context(app: terminal, processes: snapshot(), title: "zsh"))
    #expect(plain.activity == .terminalWork)

    let debugging = classify(context(
        app: terminal, processes: snapshot(matched: [.lldb], children: [.lldb]), title: "zsh"
    ))
    #expect(debugging.activity == .debugging)
}

@Test func anEditorWithNoDebuggerRunningIsStillCoding() {
    let observation = classify(context(processes: snapshot(matched: [.ssh])))
    #expect(observation.activity == .coding)
}

// MARK: - The real table

/// The one test here that touches the machine it runs on, because nothing else proves the
/// syscall path works at all. It asserts only what is true of every Mac: there is at least
/// one process, and the table can be read without a permission.
///
/// A failure here is worth having. `sysctl` returning nothing is exactly what a sandbox
/// profile without `sysctl-read` produces, silently, and the collector's contract is that
/// such a result is reported as unknown rather than as "no debugger is running".
@Test func theRealProcessTableCanBeReadWithNoPermission() {
    var settings = SigstopSettings.default
    settings.processContextEnabled = true
    let collector = ProcessCollector(
        permissions: PermissionBroker(settings: settings, trustCheck: { false })
    )
    let me = AppIdentity(
        bundleID: BundleIDs.terminal, localizedName: "Terminal", pid: ProcessInfo.processInfo.processIdentifier
    )
    let result = collector.snapshot(
        frontmost: me,
        input: InputActivity(idleSeconds: 1, source: .hidSystemState),
        power: .plugged,
        now: Date()
    )
    #expect(result != nil)
    guard case .scanned(let count) = collector.lastOutcome else {
        Issue.record("expected a scan, got \(collector.lastOutcome)")
        return
    }
    #expect(count > 0)
}

/// The memo, so that a burst of samples in one second is one scan and not five.
@Test func aSecondSampleInsideTheMemoWindowDoesNotRescan() {
    var settings = SigstopSettings.default
    settings.processContextEnabled = true
    let collector = ProcessCollector(
        permissions: PermissionBroker(settings: settings, trustCheck: { false }), memoWindow: 60
    )
    let me = AppIdentity(
        bundleID: BundleIDs.terminal, localizedName: "Terminal", pid: ProcessInfo.processInfo.processIdentifier
    )
    let start = Date()
    let first = collector.snapshot(
        frontmost: me, input: InputActivity(idleSeconds: 1, source: .hidSystemState),
        power: .plugged, now: start
    )
    let second = collector.snapshot(
        frontmost: me, input: InputActivity(idleSeconds: 1, source: .hidSystemState),
        power: .plugged, now: start.addingTimeInterval(1)
    )
    #expect(first != nil)
    #expect(first?.capturedAt == second?.capturedAt)
}
