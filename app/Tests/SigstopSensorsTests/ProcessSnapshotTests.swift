import Foundation
import Testing

@testable import SigstopCore
@testable import SigstopSensors

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

@Test func allowlistMatchesOnlyWholeNames() {
    #expect("lldb".withCString { ToolAllowlist.token(comm: $0) } == .lldb)
    #expect("debugserver".withCString { ToolAllowlist.token(comm: $0) } == .debugserver)
    #expect("claude".withCString { ToolAllowlist.token(comm: $0) } == .claudeCLI)
    #expect("lldbx".withCString { ToolAllowlist.token(comm: $0) } == nil)
    #expect("lld".withCString { ToolAllowlist.token(comm: $0) } == nil)
    #expect("".withCString { ToolAllowlist.token(comm: $0) } == nil)
}

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

@Test func argvShapedTokensAreDeclaredUndetectable() {
    let allowed = Set(ToolAllowlist.entries.map(\.token))
    for token in ToolAllowlist.undetectable {
        #expect(!allowed.contains(token), "\(token) cannot be both detected and undetectable")
    }
    #expect(ToolAllowlist.undetectable.contains(.nodeInspect))
    #expect(ToolAllowlist.undetectable.contains(.debugpy))
    #expect(ToolAllowlist.undetectable.contains(.pytest))
}

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

@Test func tracingElsewhereDecidesWhetherANamedDebuggerIsAVerdict() {
    let bare = classify(context(processes: snapshot(matched: [.lldb])))
    let attached = classify(context(processes: snapshot(matched: [.lldb], tracedElsewhere: true)))
    #expect(bare.activity == .coding)
    #expect(attached.activity == .debugging)
    #expect(bare.evidence.contains { $0.id.rawValue == "process.debuggerElsewhere" })
    #expect(!bare.evidence.contains { $0.id.rawValue == "process.tracedElsewhere" })
    #expect(attached.evidence.contains { $0.id.rawValue == "process.tracedElsewhere" })
    #expect(attached.confidence.value <= ConfidenceEngine.debuggerElsewhereCeiling)
    #expect(ConfidenceEngine.debuggerElsewhereCeiling < ConfidenceEngine.debuggingCeiling)

    let nothingNamed = classify(context(processes: snapshot(tracedElsewhere: true)))
    #expect(nothingNamed.activity == .coding)
}

@Test func aDebuggerElsewhereDoesNotOverrideWhatTheTitleSays() {
    let docs = classify(context(
        processes: snapshot(matched: [.lldb]), title: "README.md — sigstop"
    ))
    #expect(docs.activity == .documentation)

    let tests = classify(context(
        processes: snapshot(matched: [.lldb]), title: "foo.test.ts — sigstop"
    ))
    #expect(tests.activity == .testing)
}

@Test func aDebuggerDescendingFromTheAppInFrontOutranksOneThatDoesNot() {
    let mine = classify(context(processes: snapshot(matched: [.lldb], children: [.lldb])))
    let theirs = classify(context(processes: snapshot(matched: [.lldb], tracedElsewhere: true)))
    #expect(mine.activity == .debugging)
    #expect(theirs.activity == .debugging)
    #expect(mine.confidence.value > theirs.confidence.value)
}

@Test func aTerminalWithADebuggerInItIsDebuggingNotTerminalWork() {
    let plain = classify(context(app: terminal, processes: snapshot(), title: "zsh"))
    #expect(plain.activity == .terminalWork)

    let debugging = classify(context(
        app: terminal, processes: snapshot(matched: [.lldb], children: [.lldb]), title: "zsh"
    ))
    #expect(debugging.activity == .debugging)
}

@Test func anAICLIInSomeOtherTerminalIsNotThisTerminalsWork() {
    let elsewhere = classify(context(
        app: terminal, processes: snapshot(matched: [.claudeCLI]), title: "zsh"
    ))
    #expect(elsewhere.activity == .terminalWork)
    #expect(elsewhere.evidence.contains { $0.id.rawValue == "process.aiCLIElsewhere" })
    #expect(!elsewhere.evidence.contains { $0.summary == "claude is running in this terminal" })

    let here = classify(context(
        app: terminal,
        processes: snapshot(matched: [.claudeCLI], children: [.claudeCLI]),
        title: "zsh"
    ))
    #expect(here.activity == .aiCoding)
    #expect(here.evidence.contains { $0.summary == "claude is running in this terminal" })
}

@Test func aTerminalEditorSomewhereElseDoesNotMakeThisWindowCoding() {
    let elsewhere = classify(context(
        app: terminal, processes: snapshot(matched: [.vim]), title: "zsh"
    ))
    #expect(elsewhere.activity == .terminalWork)
    #expect(elsewhere.evidence.contains { $0.id.rawValue == "process.terminalEditorElsewhere" })

    let here = classify(context(
        app: terminal, processes: snapshot(matched: [.vim], children: [.vim]), title: "zsh"
    ))
    #expect(here.activity == .coding)
}

@Test func anEditorWithNoDebuggerRunningIsStillCoding() {
    let observation = classify(context(processes: snapshot(matched: [.ssh])))
    #expect(observation.activity == .coding)
}

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
