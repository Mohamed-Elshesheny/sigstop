import Foundation
import Testing

@testable import SigstopCore
@testable import SigstopSensors

private let editor = AppIdentity(bundleID: BundleIDs.vscode, localizedName: "Code", pid: 101)
private let browser = AppIdentity(bundleID: BundleIDs.chrome, localizedName: "Chrome", pid: 103)

private struct Sandbox: ~Copyable {
    let root: URL

    init() {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sigstop-git-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func keepAlive() { _ = root.path }

    @discardableResult
    func repository(_ name: String, head: String) -> String {
        let folder = root.appendingPathComponent(name)
        let dot = folder.appendingPathComponent(".git")
        try? FileManager.default.createDirectory(at: dot, withIntermediateDirectories: true)
        try? head.write(to: dot.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        return folder.path
    }

    func write(_ contents: String, to relativePath: String) {
        let url = root.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func folder(_ name: String) -> String {
        let url = root.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}

private func collector(gitOn: Bool) -> GitCollector {
    var settings = SigstopSettings.default
    settings.gitContextEnabled = gitOn
    return GitCollector(permissions: PermissionBroker(settings: settings, trustCheck: { false }))
}

@Test func aFolderThatNeverAnswersDoesNotHoldUpTheCaller() async {
    let stuck = DispatchSemaphore(value: 0)
    var settings = SigstopSettings.default
    settings.gitContextEnabled = true
    let collector = GitCollector(
        permissions: PermissionBroker(settings: settings, trustCheck: { false }),
        memoWindow: 0,
        deadline: 0.1,
        reader: { folder, now in
            if folder.hasSuffix("dead") { _ = stuck.wait(timeout: .now() + 2) }
            return .success(GitSignal(
                branch: "main", repoState: .clean,
                repoName: (folder as NSString).lastPathComponent, readAt: now
            ))
        }
    )

    for _ in 0..<GitCollector.strikesBeforeSettingAside {
        let started = Date()
        let attempt = await collector.read(
            frontmost: editor, folders: ["/Users/x/dead"], documentURL: nil,
            windowTitle: "a.swift — dead", now: Date()
        )
        #expect(attempt == nil)
        let spent = Date().timeIntervalSince(started)
        #expect(spent < 2)
        #expect(spent >= 0.1)
        #expect(collector.lastOutcome == .timedOut(folder: "dead"))
    }

    let secondStarted = Date()
    let second = await collector.read(
        frontmost: editor, folders: ["/Users/x/dead"], documentURL: nil,
        windowTitle: "a.swift — dead", now: Date()
    )
    #expect(second == nil)
    #expect(Date().timeIntervalSince(secondStarted) < 0.05)
    #expect(collector.lastOutcome == .timedOut(folder: "dead"))

    let live = await collector.read(
        frontmost: editor, folders: ["/Users/x/dead", "/Users/x/live"], documentURL: nil,
        windowTitle: "a.swift — live", now: Date()
    )
    #expect(live?.branch == "main")

    stuck.signal()
}

@Test func aNormalRepositoryYieldsItsBranch() {
    let box = Sandbox()
    let repo = box.repository("sigstop", head: "ref: refs/heads/fix/retry-loop\n")
    let result = GitCollector.readRepository(at: repo, now: Date())
    #expect(try! result.get().branch == "fix/retry-loop")
    #expect(try! result.get().repoState == .clean)
    #expect(try! result.get().repoName == "sigstop")
}

@Test func aDetachedHeadIsNotPresentedAsABranch() {
    let box = Sandbox()
    let repo = box.repository("proj", head: "1435bcf24e49d1e645dba8fb117c803f035aaab5\n")
    let signal = try! GitCollector.readRepository(at: repo, now: Date()).get()
    #expect(signal.branch == nil)
    #expect(signal.repoState == .detachedHead)
}

@Test func midRebaseTheBranchComesFromHeadName() {
    let box = Sandbox()
    let repo = box.repository("proj", head: "3bcce1f7a0c0e1b2d3f4a5b6c7d8e9f0a1b2c3d4\n")
    box.write("refs/heads/main\n", to: "proj/.git/rebase-merge/head-name")
    let signal = try! GitCollector.readRepository(at: repo, now: Date()).get()
    #expect(signal.branch == "main")
    #expect(signal.repoState == .rebaseInProgress)
}

@Test func aConflictedMergeIsReportedAsOne() {
    let box = Sandbox()
    let repo = box.repository("proj", head: "ref: refs/heads/main\n")
    box.write("abc\n", to: "proj/.git/MERGE_HEAD")
    let signal = try! GitCollector.readRepository(at: repo, now: Date()).get()
    #expect(signal.branch == "main")
    #expect(signal.repoState == .mergeInProgress)
}

@Test func aWorktreeResolvesThroughItsGitdirFile() {
    let box = Sandbox()
    let real = box.repository("main1", head: "ref: refs/heads/main\n")
    box.write("ref: refs/heads/feature/ticket-123\n", to: "main1/.git/worktrees/wt/HEAD")
    let tree = box.folder("wt")
    box.write("gitdir: \(real)/.git/worktrees/wt\n", to: "wt/.git")
    let signal = try! GitCollector.readRepository(at: tree, now: Date()).get()
    #expect(signal.branch == "feature/ticket-123")
}

@Test func aSubmoduleResolvesItsRelativeGitdir() {
    let box = Sandbox()
    _ = box.repository("super", head: "ref: refs/heads/main\n")
    box.write("ref: refs/heads/vendored\n", to: "super/.git/modules/vendor/HEAD")
    _ = box.folder("super/vendor")
    box.write("gitdir: ../.git/modules/vendor\n", to: "super/vendor/.git")
    let signal = try! GitCollector.readRepository(
        at: box.root.appendingPathComponent("super/vendor").path, now: Date()
    ).get()
    #expect(signal.branch == "vendored")
}

@Test func aFolderWithNoRepositoryIsReportedAsSuchAndNotWalkedOutOf() {
    let box = Sandbox()
    _ = box.repository("outer", head: "ref: refs/heads/outer-branch\n")
    let inner = box.folder("outer/src")
    switch GitCollector.readRepository(at: inner, now: Date()) {
    case .success(let signal):
        Issue.record("walked up out of the registered folder and found \(signal.branch ?? "?")")
    case .failure(let failure):
        #expect(failure == .noRepository)
    }
}

@Test func headParsingRejectsThingsThatAreNotBranches() {
    #expect(GitCollector.parseHEAD("ref: refs/heads/main").branch == "main")
    #expect(GitCollector.parseHEAD("ref: refs/heads/").branch == nil)
    #expect(GitCollector.parseHEAD("ref: refs/tags/v1").branch == nil)
    #expect(GitCollector.parseHEAD("").branch == nil)
    #expect(GitCollector.parseHEAD("zzz5bcf24e49d1e645dba8fb117c803f035aaab5").detached == false)
}

@Test func aDocumentPathInsideARegisteredFolderPicksThatFolder() {
    let folders = ["/Users/x/code/sigstop", "/Users/x/code/other"]
    let match = GitCollector.match(
        folders: folders,
        documentURL: URL(fileURLWithPath: "/Users/x/code/sigstop/app/main.swift"),
        title: nil
    )
    #expect(match?.folder == "/Users/x/code/sigstop")
    #expect(match?.route == .documentPath)
}

@Test func aTitleNamingARegisteredFolderPicksThatFolder() {
    let folders = ["/Users/x/code/sigstop", "/Users/x/code/other"]
    let match = GitCollector.match(
        folders: folders, documentURL: nil, title: "main.swift — sigstop"
    )
    #expect(match?.folder == "/Users/x/code/sigstop")
    #expect(match?.route == .windowTitle)
}

@Test func twoMatchingFoldersProduceNoBranchRatherThanAGuess() {
    let folders = ["/Users/x/a/sigstop", "/Users/x/b/sigstop"]
    #expect(GitCollector.match(folders: folders, documentURL: nil, title: "x — sigstop") == nil)
    #expect(GitCollector.match(
        folders: ["/Users/x/code", "/Users/x/code/inner"],
        documentURL: URL(fileURLWithPath: "/Users/x/code/inner/a.swift"),
        title: nil
    ) == nil)
}

@Test func aFileURLWithAHostIsNotAPath() {
    #expect(GitCollector.match(
        folders: ["/share"],
        documentURL: URL(string: "file://server/share/a.txt"),
        title: nil
    ) == nil)
}

@Test func aFolderNameMustStandAsItsOwnWordInTheTitle() {
    #expect(GitCollector.containsWholeToken("sigstop", in: "main.swift — sigstop"))
    #expect(GitCollector.containsWholeToken("sigstop", in: "sigstop – Main.java"))
    #expect(GitCollector.containsWholeToken("api", in: "handler.go (api)"))
    #expect(!GitCollector.containsWholeToken("api", in: "rapidly.md — notes"))
    #expect(!GitCollector.containsWholeToken("app", in: "happy.swift — elsewhere"))
    #expect(GitCollector.match(folders: ["/Users/x/ui"], documentURL: nil, title: "ui") == nil)
}

@Test func theGitCollectorReadsNothingWhenTheSwitchIsOff() async {
    let box = Sandbox()
    let repo = box.repository("sigstop", head: "ref: refs/heads/main\n")
    let collector = collector(gitOn: false)
    let signal = await collector.read(
        frontmost: editor, folders: [repo], documentURL: nil, windowTitle: "x — sigstop", now: Date()
    )
    #expect(signal == nil)
    #expect(collector.lastOutcome == .optedOut)
    box.keepAlive()
}

@Test func withNoRegisteredFolderTheSwitchSaysSoRatherThanGoingLooking() async {
    let collector = collector(gitOn: true)
    let signal = await collector.read(
        frontmost: editor, folders: [], documentURL: nil, windowTitle: "x — sigstop", now: Date()
    )
    #expect(signal == nil)
    #expect(collector.lastOutcome == .noFoldersRegistered)
}

@Test func nothingIsReadWhenTheAppInFrontIsNotAnEditorOrTerminal() async {
    let box = Sandbox()
    let repo = box.repository("sigstop", head: "ref: refs/heads/main\n")
    let collector = collector(gitOn: true)
    let signal = await collector.read(
        frontmost: browser, folders: [repo], documentURL: nil, windowTitle: "x — sigstop", now: Date()
    )
    #expect(signal == nil)
    guard case .skipped = collector.lastOutcome else {
        Issue.record("expected skipped, got \(collector.lastOutcome)")
        return
    }
    box.keepAlive()
}

@Test func aMatchedFolderIsReadEndToEnd() async {
    let box = Sandbox()
    let repo = box.repository("sigstop", head: "ref: refs/heads/fix/retry-loop\n")
    let collector = collector(gitOn: true)
    let signal = await collector.read(
        frontmost: editor, folders: [repo], documentURL: nil,
        windowTitle: "main.swift — sigstop", now: Date()
    )
    #expect(signal?.branch == "fix/retry-loop")
    guard case .read(let folder, let length, let detached, _) = collector.lastOutcome else {
        Issue.record("expected a read, got \(collector.lastOutcome)")
        return
    }
    #expect(folder == "sigstop")
    #expect(length == "fix/retry-loop".count)
    #expect(!detached)
    box.keepAlive()
}

@Test func theOutcomeDoctorPrintsDoesNotCarryTheBranchName() async {
    let box = Sandbox()
    let repo = box.repository("sigstop", head: "ref: refs/heads/acme-4417-billing\n")
    let collector = collector(gitOn: true)
    _ = await collector.read(
        frontmost: editor, folders: [repo], documentURL: nil,
        windowTitle: "main.swift — sigstop", now: Date()
    )
    #expect(!"\(collector.lastOutcome)".contains("acme-4417-billing"))
    box.keepAlive()
}

@Test func knowingTheBranchDoesNotRaiseTheConfidenceCeiling() {
    func observe(_ git: GitSignal?) -> ActivityObservation {
        let signals = SignalContext(
            now: Date(timeIntervalSince1970: 1_700_000_000),
            available: [.tier0, .tier1, .tier2],
            frontmost: editor,
            input: InputActivity(idleSeconds: 3, source: .hidSystemState),
            windowTitle: "main.swift — sigstop",
            git: git
        )
        let classified = ProviderRegistry().classify(signals)
        return ConfidenceEngine.observation(
            verdict: classified.verdict, providerID: classified.providerID,
            signals: signals, concurrent: ConcurrentStates()
        )
    }
    let without = observe(nil)
    let with = observe(GitSignal(
        branch: "fix/retry-loop", repoState: .clean, repoName: "sigstop", readAt: Date()
    ))
    #expect(with.context.branch == "fix/retry-loop")
    #expect(with.confidence.value == without.confidence.value)
    #expect(!with.evidence.contains { $0.id.rawValue == "git.branch" })
    #expect(with.confidence.value <= ConfidenceEngine.tier1Ceiling)
}

@Test func theBranchIsClearedWhenTierTwoIsNotAvailable() {
    let signals = SignalContext(
        now: Date(timeIntervalSince1970: 1_700_000_000),
        available: [.tier0, .tier1],
        frontmost: editor,
        input: InputActivity(idleSeconds: 3, source: .hidSystemState),
        windowTitle: "main.swift — sigstop",
        git: GitSignal(branch: "secret", repoState: .clean, repoName: "sigstop", readAt: Date())
    )
    let classified = ProviderRegistry().classify(signals)
    let observation = ConfidenceEngine.observation(
        verdict: classified.verdict, providerID: classified.providerID,
        signals: signals, concurrent: ConcurrentStates()
    )
    #expect(observation.context.branch == nil)
}

@Test func aRepositoryMidRebaseIsStillCitedAsEvidence() {
    let signals = SignalContext(
        now: Date(timeIntervalSince1970: 1_700_000_000),
        available: [.tier0, .tier1, .tier2],
        frontmost: editor,
        input: InputActivity(idleSeconds: 3, source: .hidSystemState),
        windowTitle: "main.swift — sigstop",
        git: GitSignal(
            branch: "main", repoState: .rebaseInProgress, repoName: "sigstop", readAt: Date()
        )
    )
    let classified = ProviderRegistry().classify(signals)
    let observation = ConfidenceEngine.observation(
        verdict: classified.verdict, providerID: classified.providerID,
        signals: signals, concurrent: ConcurrentStates()
    )
    #expect(observation.evidence.contains { $0.id.rawValue == "git.repoState" })
}
