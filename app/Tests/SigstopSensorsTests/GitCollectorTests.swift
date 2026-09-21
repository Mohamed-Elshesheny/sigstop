import Foundation
import Testing

@testable import SigstopCore
@testable import SigstopSensors

/// The git collector, against repository shapes built on disk in a temporary directory.
///
/// No `git` binary is invoked to build them either: every one of these is just the files
/// git would have written, which is the point. If the collector needed more than those
/// files it would fail here, and that is the test.
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

    /// Called at the end of every async test that reads from this sandbox.
    ///
    /// `Sandbox` is noncopyable, so it is destroyed after its **last use**, not at the
    /// end of the scope, and `deinit` deletes the directory the collector is being asked
    /// to read. In a test whose last use of the box is before an `await`, the delete
    /// raced the read: the collector found no `.git` and answered `noRepository`, and the
    /// test failed about one run in eight with a message about a branch rather than about
    /// a directory that was no longer there. This is the anchor that stops that, and it
    /// has to be a real use, which is why it touches `root`.
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

// MARK: - The deadline

/// A registered folder can be on an SMB share or an sshfs mount. When the server goes
/// away, `stat` on a hard mount does not fail, it waits, and before this the whole app
/// waited with it: the read never returned, `ContextEngine.sampleAndPublish` never
/// returned, and `AppModel.tick` left its re-entrancy flag set forever. Every later tick
/// returned at the guard, the work clock stopped, no break was ever prompted again, and
/// nothing on screen said why.
@Test func aFolderThatNeverAnswersDoesNotHoldUpTheCaller() async {
    /// Waited on with a timeout, so the fake slow read parks a worker thread for a
    /// bounded time instead of for the rest of the suite.
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

    /// Two misses, because one is allowed to be a busy machine rather than a dead mount.
    for _ in 0..<GitCollector.strikesBeforeSettingAside {
        let started = Date()
        let attempt = await collector.read(
            frontmost: editor, folders: ["/Users/x/dead"], documentURL: nil,
            windowTitle: "a.swift — dead", now: Date()
        )
        #expect(attempt == nil)
        let spent = Date().timeIntervalSince(started)
        #expect(spent < 2)
        /// Lower bound as well as upper: every attempt inside the strike count has to
        /// actually reach the filesystem and wait out the deadline. Without this the
        /// test passes just as happily if the folder is set aside on the first miss,
        /// which is the behaviour it exists to rule out.
        #expect(spent >= 0.1)
        #expect(collector.lastOutcome == .timedOut(folder: "dead"))
    }

    /// Now it is set aside and not asked again, so a dead mount costs a bounded number
    /// of parked threads rather than one per sample for as long as the app runs.
    let secondStarted = Date()
    let second = await collector.read(
        frontmost: editor, folders: ["/Users/x/dead"], documentURL: nil,
        windowTitle: "a.swift — dead", now: Date()
    )
    #expect(second == nil)
    #expect(Date().timeIntervalSince(secondStarted) < 0.05)
    #expect(collector.lastOutcome == .timedOut(folder: "dead"))

    /// Changing the registered folders is the user saying something new about what they
    /// want read, and a folder that answers is unaffected by one that did not.
    let live = await collector.read(
        frontmost: editor, folders: ["/Users/x/dead", "/Users/x/live"], documentURL: nil,
        windowTitle: "a.swift — live", now: Date()
    )
    #expect(live?.branch == "main")

    stuck.signal()
}

// MARK: - Reading HEAD

@Test func aNormalRepositoryYieldsItsBranch() {
    let box = Sandbox()
    let repo = box.repository("sigstop", head: "ref: refs/heads/fix/retry-loop\n")
    let result = GitCollector.readRepository(at: repo, now: Date())
    #expect(try! result.get().branch == "fix/retry-loop")
    #expect(try! result.get().repoState == .clean)
    #expect(try! result.get().repoName == "sigstop")
}

/// A detached HEAD is a commit id. Presenting forty hex characters as a branch name would
/// be a specific claim the file never made.
@Test func aDetachedHeadIsNotPresentedAsABranch() {
    let box = Sandbox()
    let repo = box.repository("proj", head: "1435bcf24e49d1e645dba8fb117c803f035aaab5\n")
    let signal = try! GitCollector.readRepository(at: repo, now: Date()).get()
    #expect(signal.branch == nil)
    #expect(signal.repoState == .detachedHead)
}

/// Mid-rebase HEAD is a detached sha and the branch you think you are on is in
/// `rebase-merge/head-name`, which is exactly when a break is worth naming properly.
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

/// In a worktree `.git` is a FILE holding an absolute `gitdir:` line. This repository uses
/// them, so a collector that only understood directories would be blank inside its own tree.
@Test func aWorktreeResolvesThroughItsGitdirFile() {
    let box = Sandbox()
    let real = box.repository("main1", head: "ref: refs/heads/main\n")
    box.write("ref: refs/heads/feature/ticket-123\n", to: "main1/.git/worktrees/wt/HEAD")
    let tree = box.folder("wt")
    box.write("gitdir: \(real)/.git/worktrees/wt\n", to: "wt/.git")
    let signal = try! GitCollector.readRepository(at: tree, now: Date()).get()
    #expect(signal.branch == "feature/ticket-123")
}

/// A submodule's `gitdir:` is RELATIVE and must resolve against the folder holding it, not
/// against the process's working directory.
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

// MARK: - Which folder

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

/// VS Code and Cursor return `kAXDocument` as `.success` with an empty string, so the title
/// is the only route that covers them. It is a match against the closed set the user typed
/// in themselves, never a path conjured from a name.
@Test func aTitleNamingARegisteredFolderPicksThatFolder() {
    let folders = ["/Users/x/code/sigstop", "/Users/x/code/other"]
    let match = GitCollector.match(
        folders: folders, documentURL: nil, title: "main.swift — sigstop"
    )
    #expect(match?.folder == "/Users/x/code/sigstop")
    #expect(match?.route == .windowTitle)
}

/// Two projects open means the app cannot tell which one you are looking at. §4.1 says that
/// must produce nothing, not a coin flip.
@Test func twoMatchingFoldersProduceNoBranchRatherThanAGuess() {
    let folders = ["/Users/x/a/sigstop", "/Users/x/b/sigstop"]
    #expect(GitCollector.match(folders: folders, documentURL: nil, title: "x — sigstop") == nil)
    #expect(GitCollector.match(
        folders: ["/Users/x/code", "/Users/x/code/inner"],
        documentURL: URL(fileURLWithPath: "/Users/x/code/inner/a.swift"),
        title: nil
    ) == nil)
}

/// `file://server/share/a.txt` survives `AccessibilityCollector.fileURL(from:)`. Nothing on
/// the development machine produced one, but a path on a network mount must not be treated
/// as a local path inside a registered folder.
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
    /// Two characters is too short to be evidence of anything, so it never matches.
    #expect(GitCollector.match(folders: ["/Users/x/ui"], documentURL: nil, title: "ui") == nil)
}

// MARK: - The opt-in and the gate

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

/// The outcome `--doctor` prints must carry a length and a route, and never the name.
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

// MARK: - What the providers do with it

/// A branch says which branch. It says nothing about which activity, and citing it as
/// evidence lifted the ceiling from 0.85 to 0.93 for 0.3 log-odds, which is confidence the
/// signal did not earn.
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

/// Being mid-rebase IS a claim about what you are doing, unlike the branch name, so it
/// stays cited and keeps carrying its tier with it.
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
