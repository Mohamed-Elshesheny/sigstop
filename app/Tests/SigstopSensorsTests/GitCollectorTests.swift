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
    box.write("../..\n", to: "main1/.git/worktrees/wt/commondir")
    let tree = box.folder("wt")
    box.write("gitdir: \(real)/.git/worktrees/wt\n", to: "wt/.git")
    let signal = try! GitCollector.readRepository(at: tree, now: Date()).get()
    #expect(signal.branch == "feature/ticket-123")
}

@Test func aSubmoduleResolvesItsRelativeGitdir() {
    let box = Sandbox()
    _ = box.repository("super", head: "ref: refs/heads/main\n")
    box.write("ref: refs/heads/vendored\n", to: "super/.git/modules/vendor/HEAD")
    _ = box.folder("super/.git/modules/vendor/objects")
    _ = box.folder("super/vendor")
    box.write("gitdir: ../.git/modules/vendor\n", to: "super/vendor/.git")
    let signal = try! GitCollector.readRepository(
        at: box.root.appendingPathComponent("super/vendor").path, now: Date()
    ).get()
    #expect(signal.branch == "vendored")
}

@Test func aGitdirPointingOutsideTheFolderIsNotFollowed() {
    let box = Sandbox()
    box.write("ref: refs/heads/read-from-outside-the-folder\n", to: "outside/secret/HEAD")
    let absolute = box.folder("gitdir-abs")
    box.write("gitdir: \(box.root.path)/outside/secret\n", to: "gitdir-abs/.git")
    let relative = box.folder("gitdir-rel")
    box.write("gitdir: ../outside/secret\n", to: "gitdir-rel/.git")
    for folder in [absolute, relative] {
        if case .success(let signal) = GitCollector.readRepository(at: folder, now: Date()) {
            Issue.record("read \(signal.branch ?? "?") through a gitdir outside \(folder)")
        }
    }
}

@Test func aBareRepositoryWorktreeAndASeparateGitDirStillResolve() {
    let box = Sandbox()
    box.write("ref: refs/heads/main\n", to: "repo.git/HEAD")
    _ = box.folder("repo.git/objects")
    box.write("ref: refs/heads/from-bare\n", to: "repo.git/worktrees/wt/HEAD")
    box.write("../..\n", to: "repo.git/worktrees/wt/commondir")
    let worktree = box.folder("wt")
    box.write("gitdir: \(box.root.path)/repo.git/worktrees/wt\n", to: "wt/.git")
    #expect(try! GitCollector.readRepository(at: worktree, now: Date()).get().branch == "from-bare")

    box.write("ref: refs/heads/separate\n", to: "elsewhere/sepgit/HEAD")
    _ = box.folder("elsewhere/sepgit/objects")
    let separate = box.folder("separate")
    box.write("gitdir: \(box.root.path)/elsewhere/sepgit\n", to: "separate/.git")
    #expect(try! GitCollector.readRepository(at: separate, now: Date()).get().branch == "separate")
}

@Test func aGitdirLineEndingInCRLFIsReadAsGitReadsIt() {
    let box = Sandbox()
    box.write("ref: refs/heads/crlf-branch\n", to: "crlf/sepstore/HEAD")
    _ = box.folder("crlf/sepstore/objects")
    let relative = box.folder("crlf/work")
    box.write("gitdir: ../sepstore\r\n", to: "crlf/work/.git")
    #expect((try? GitCollector.readRepository(at: relative, now: Date()).get())?.branch == "crlf-branch")

    let absolute = box.folder("crlf/abs")
    box.write("gitdir: \(box.root.path)/crlf/sepstore\r\n", to: "crlf/abs/.git")
    #expect((try? GitCollector.readRepository(at: absolute, now: Date()).get())?.branch == "crlf-branch")
}

@Test func aGitdirFileGitRefusesIsRefusedToo() {
    let box = Sandbox()
    box.write("ref: refs/heads/should-not-be-read\n", to: "gd/sepstore/HEAD")
    _ = box.folder("gd/sepstore/objects")
    let refused: [(String, String)] = [
        ("vertical-tab", "gitdir: ../sepstore\u{0B}\n"),
        ("no-space", "gitdir:../sepstore\n"),
        ("trailing-spaces", "gitdir: ../sepstore  \n"),
        ("trailing-tab", "gitdir: ../sepstore\t\n"),
        ("two-spaces", "gitdir:  ../sepstore\n"),
        ("leading-space", " gitdir: ../sepstore\n"),
        ("upper-case", "GITDIR: ../sepstore\n"),
        ("second-line", "gitdir: ../sepstore\nsecond\n"),
        ("too-long", "gitdir: ../sepstore\n" + String(repeating: "x", count: 600) + "\n"),
    ]
    for (name, contents) in refused {
        let folder = box.folder("gd/\(name)")
        box.write(contents, to: "gd/\(name)/.git")
        switch GitCollector.readRepository(at: folder, now: Date()) {
        case .success(let signal):
            Issue.record("\(name): followed a .git file git refuses, read \(signal.branch ?? "?")")
        case .failure(let failure):
            #expect(failure == .noRepository, "\(name)")
        }
    }
}

@Test func aGitdirFileGitAcceptsIsFollowed() {
    let box = Sandbox()
    box.write("ref: refs/heads/accepted\n", to: "gd/sepstore/HEAD")
    _ = box.folder("gd/sepstore/objects")
    let accepted: [(String, String)] = [
        ("lf", "gitdir: ../sepstore\n"),
        ("crlf", "gitdir: ../sepstore\r\n"),
        ("no-newline", "gitdir: ../sepstore"),
        ("several", "gitdir: ../sepstore\r\r\n\n"),
        ("lf-cr-lf", "gitdir: ../sepstore\n\r\n"),
    ]
    for (name, contents) in accepted {
        let folder = box.folder("gd/\(name)")
        box.write(contents, to: "gd/\(name)/.git")
        let branch = (try? GitCollector.readRepository(at: folder, now: Date()).get())?.branch
        #expect(branch == "accepted", "\(name)")
    }
}

@Test func theGitdirTargetIsWhatFollowsTheExactPrefix() {
    func target(_ text: String) -> String? { GitCollector.gitdirTarget(Array(text.utf8)) }
    #expect(target("gitdir: /abs/path\n") == "/abs/path")
    #expect(target("gitdir: rel\r\n") == "rel")
    #expect(target("gitdir: a b\n") == "a b")
    #expect(target("gitdir:  rel\n") == " rel")
    #expect(target("gitdir: rel \n") == "rel ")
    #expect(target("gitdir: rel\nmore\n") == "rel\nmore")
    #expect(target("gitdir:rel\n") == nil)
    #expect(target("gitdir: \n") == nil)
    #expect(target("gitdir: \r\n") == nil)
    #expect(target("") == nil)
}

@Test func aLinkedDotGitIsNotFollowed() throws {
    let box = Sandbox()
    box.write("ref: refs/heads/read-from-outside-the-folder\n", to: "outside/secret/HEAD")
    let folder = box.folder("dotgit-link")
    try FileManager.default.createSymbolicLink(
        atPath: folder + "/.git", withDestinationPath: box.root.appendingPathComponent("outside/secret").path
    )
    if case .success(let signal) = GitCollector.readRepository(at: folder, now: Date()) {
        Issue.record("read \(signal.branch ?? "?") through a linked .git")
    }
}

@Test func aFifoHeadReturnsAtOnceInsteadOfBlocking() {
    let box = Sandbox()
    let folder = box.folder("fifo-head")
    try? FileManager.default.createDirectory(atPath: folder + "/.git", withIntermediateDirectories: true)
    #expect(mkfifo(folder + "/.git/HEAD", 0o600) == 0)
    let started = Date()
    let result = GitCollector.readRepository(at: folder, now: Date())
    #expect(Date().timeIntervalSince(started) < 0.5, "a FIFO must not hold the read open")
    if case .success = result { Issue.record("a FIFO was read as a HEAD file") }
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

private extension Sandbox {
    @discardableResult
    func reftableRepository(_ name: String) -> String {
        let folder = repository(name, head: "ref: refs/heads/.invalid\n")
        write("this repository uses the reftable format\n", to: "\(name)/.git/refs/heads")
        write("0x000000000001-0x000000000002-00000000.ref\n", to: "\(name)/.git/reftable/tables.list")
        _ = self.folder("\(name)/.git/objects")
        return folder
    }
}

@Test func aReftableRepositoryNamesNoBranchAndIsNotCalledDetached() {
    let box = Sandbox()
    let repo = box.reftableRepository("rt")
    let signal = try! GitCollector.readRepository(at: repo, now: Date()).get()
    #expect(signal.branch == nil)
    #expect(signal.repoState == .clean)
    #expect(signal.headInReftable)
    #expect(signal.head == .reftable)
}

@Test func aReftableWorktreeNamesNoBranchEither() {
    let box = Sandbox()
    let real = box.reftableRepository("rt-main")
    box.write("ref: refs/heads/.invalid\n", to: "rt-main/.git/worktrees/wt/HEAD")
    box.write("../..\n", to: "rt-main/.git/worktrees/wt/commondir")
    let tree = box.folder("rt-wt")
    box.write("gitdir: \(real)/.git/worktrees/wt\n", to: "rt-wt/.git")
    let signal = try! GitCollector.readRepository(at: tree, now: Date()).get()
    #expect(signal.branch == nil)
    #expect(signal.head == .reftable)
}

@Test func aReftableRepositoryMidRebaseStillNamesTheBranchFromHeadName() {
    let box = Sandbox()
    let repo = box.reftableRepository("rt")
    box.write("refs/heads/topic\n", to: "rt/.git/rebase-merge/head-name")
    let signal = try! GitCollector.readRepository(at: repo, now: Date()).get()
    #expect(signal.branch == "topic")
    #expect(signal.head == .branch)
    #expect(signal.repoState == .rebaseInProgress)
}

@Test func theOutcomeForAReftableRepositoryIsNotADetachedHead() async {
    let box = Sandbox()
    let repo = box.reftableRepository("sigstop")
    let collector = collector(gitOn: true)
    let signal = await collector.read(
        frontmost: editor, folders: [repo], documentURL: nil,
        windowTitle: "main.swift — sigstop", now: Date()
    )
    #expect(signal != nil)
    #expect(signal?.branch == nil)
    #expect(collector.lastOutcome == .read(
        folder: "sigstop", branchLength: 0, head: .reftable, route: GitFolderRoute.windowTitle.rawValue
    ))
    box.keepAlive()
}

@Test func headParsingRejectsThingsThatAreNotBranches() {
    #expect(GitCollector.parseHEAD("ref: refs/heads/main").branch == "main")
    #expect(GitCollector.parseHEAD("ref: refs/heads/").branch == nil)
    #expect(GitCollector.parseHEAD("ref: refs/tags/v1").branch == nil)
    #expect(GitCollector.parseHEAD("").branch == nil)
    #expect(GitCollector.parseHEAD("zzz5bcf24e49d1e645dba8fb117c803f035aaab5").detached == false)
    let placeholder = GitCollector.parseHEAD("ref: refs/heads/.invalid")
    #expect(placeholder.branch == nil)
    #expect(!placeholder.detached)
    #expect(placeholder.reftable)
    #expect(!GitCollector.parseHEAD("ref: refs/heads/main").reftable)
}

@Test func aDetachedHeadIsRecognisedInEitherObjectFormat() {
    let sha1 = String(repeating: "a1", count: 20)
    let sha256 = String(repeating: "b2", count: 32)
    #expect(GitCollector.parseHEAD(sha1).detached)
    #expect(GitCollector.parseHEAD(sha256 + "\n").detached)
    #expect(GitCollector.parseHEAD(sha256).branch == nil)
    #expect(!GitCollector.parseHEAD(String(repeating: "c", count: 50)).detached)
    #expect(!GitCollector.parseHEAD(String(repeating: "d", count: 65)).detached)
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
    guard case .read(let folder, let length, let head, _) = collector.lastOutcome else {
        Issue.record("expected a read, got \(collector.lastOutcome)")
        return
    }
    #expect(folder == "sigstop")
    #expect(length == "fix/retry-loop".count)
    #expect(head == .branch)
    box.keepAlive()
}

@Test func theLastScanPairsEachOutcomeWithTheReadThatMadeIt() async {
    let box = Sandbox()
    let alpha = box.repository("alpha", head: "ref: refs/heads/feature/a\n")
    box.write("abc\n", to: "alpha/.git/MERGE_HEAD")
    let beta = box.repository("beta", head: String(repeating: "c3", count: 20) + "\n")
    let collector = collector(gitOn: true)
    let start = Date()

    _ = await collector.read(
        frontmost: editor, folders: [alpha, beta], documentURL: nil,
        windowTitle: "main.swift — alpha", now: start
    )
    var scan = collector.lastScan
    #expect(scan.outcome == .read(
        folder: "alpha", branchLength: 9, head: .branch, route: GitFolderRoute.windowTitle.rawValue
    ))
    #expect(scan.signal?.branch == "feature/a")
    #expect(scan.signal?.repoState == .mergeInProgress)

    _ = await collector.read(
        frontmost: editor, folders: [alpha, beta], documentURL: nil,
        windowTitle: "main.swift — alpha", now: start.addingTimeInterval(1)
    )
    #expect(collector.lastScan.signal?.branch == "feature/a")

    _ = await collector.read(
        frontmost: browser, folders: [alpha, beta], documentURL: nil,
        windowTitle: "main.swift — alpha", now: start.addingTimeInterval(2)
    )
    scan = collector.lastScan
    if case .skipped = scan.outcome {} else { Issue.record("expected skipped, got \(scan.outcome)") }
    #expect(scan.signal == nil)

    _ = await collector.read(
        frontmost: editor, folders: [alpha, beta], documentURL: nil,
        windowTitle: "lib.rs — beta", now: start.addingTimeInterval(3)
    )
    scan = collector.lastScan
    #expect(scan.outcome == .read(
        folder: "beta", branchLength: 0, head: .detached, route: GitFolderRoute.windowTitle.rawValue
    ))
    #expect(scan.signal?.branch == nil)
    #expect(scan.signal?.head == .detached)
    #expect(scan.signal?.repoState == .detachedHead)
    #expect(scan.signal?.repoName == "beta")
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

@Test func aRepositoryStateIsNamedInWordsNotAsAnEnumCase() {
    let expected: [(RepoState, String)] = [
        (.rebaseInProgress, "the repository is mid-rebase"),
        (.mergeInProgress, "the repository is mid-merge"),
        (.bisecting, "the repository is mid-bisect"),
        (.detachedHead, "the repository is on a detached HEAD"),
    ]
    for (state, words) in expected {
        let signals = SignalContext(
            now: Date(timeIntervalSince1970: 1_700_000_000),
            available: [.tier0, .tier1, .tier2],
            frontmost: editor,
            input: InputActivity(idleSeconds: 3, source: .hidSystemState),
            windowTitle: "main.swift — sigstop",
            git: GitSignal(
                branch: state == .detachedHead ? nil : "main",
                repoState: state, repoName: "sigstop", readAt: Date()
            )
        )
        let summaries = ProviderRegistry().classify(signals).verdict.evidence
            .filter { $0.id.rawValue == "git.repoState" }
            .map(\.summary)
        #expect(summaries == [words], "\(state)")
        #expect(!summaries.contains { $0.contains(state.rawValue) }, "\(state)")
    }
}
