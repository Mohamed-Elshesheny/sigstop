import Darwin
import Foundation
import SigstopCore

// MARK: - Outcome

/// What the last read did, for `--doctor`.
///
/// The branch itself is deliberately not in here. `--doctor` is the command this project
/// hands to sceptics and the bug report form asks for the whole of it, and a branch name
/// routinely carries a ticket id, a customer or an unreleased product. So the outcome
/// carries a length and a route, and the name stays in memory (docs/PRIVACY.md §8.12).
public enum GitScanOutcome: Sendable, Hashable {
    case optedOut
    /// On, and the gate declined this sample. Carries why.
    case skipped(String)
    /// On, and no project folder has been added yet. The switch buys nothing until one is.
    case noFoldersRegistered
    /// On, folders are registered, and nothing said which of them you are in.
    case noFolderMatched(String)
    /// A folder matched and macOS refused the read. Not the same as "no repository".
    case notPermitted(folder: String)
    /// A folder matched and there is no repository at its root.
    case noRepository(folder: String)
    /// A folder matched and the filesystem did not answer inside the deadline. A network
    /// mount whose server went away does this, and it does it for as long as the mount
    /// is hard. Kept separate from every other failure because the user can act on it.
    case timedOut(folder: String)
    case read(folder: String, branchLength: Int, detached: Bool, route: String)
}

/// How the app decided which registered folder you are in. Printed, because the answer to
/// "why is it blank" has to be visible.
public enum GitFolderRoute: String, Sendable, Hashable {
    /// The focused window reported a document path inside a registered folder. A fact.
    case documentPath = "the document path your editor reported"
    /// The window title names a registered folder. A match against a closed set the user
    /// typed in themselves, which is not the same as inventing a path from a name.
    case windowTitle = "the project named in the window title"
}

// MARK: - Collector

/// Tier 2. The branch you are on, read from one line of one file, in a folder you added.
///
/// **Where the path comes from.** Only from a folder the user registered through an
/// `NSOpenPanel`. Nothing here infers a path from a project name, because inventing a path
/// from a name is the guess CLAUDE.md §4.1 forbids, and because the open panel is the only
/// route that carries a Files-and-Folders grant for a repository under `~/Desktop`,
/// `~/Documents` or `~/Downloads`. What Tier 1 contributes is not a path but an answer to
/// *which* registered folder is in front, and two registered folders that both answer means
/// the app does not know, so it reports nothing rather than pick.
///
/// **What it reads.** `HEAD`, capped at 512 bytes, which is one line. Then four `access`
/// calls for the repository state, which return a `Bool` and open nothing. Never a diff,
/// never a commit message, never `.git/config`, never a file in the working tree. `git` is
/// never spawned, and cannot be: `Process` and `posix_spawn` are forbidden symbols.
///
/// **What it costs.** About 50 microseconds warm, measured over 2000 walk-and-parse
/// iterations. The design doc used to prescribe a `DispatchSource` watch on `HEAD`
/// instead; git renames a lockfile over that file, so the watched inode is orphaned and
/// the source fires exactly once. Measured: one event across four checkouts, then silence.
/// The read is cheap enough to do on demand behind a memo, which is what this does.
///
/// **Why it is not on the main actor, and why that was not enough.** Not for CPU. A `stat`
/// on a sleeping external disk, an SMB share or an sshfs mount blocks for as long as the
/// filesystem takes, and a registered folder can be on any of those. Moving it off the
/// main actor only decided which thread waits. The caller still awaited it, and the tick
/// loop still awaited the caller, so a hard mount whose server went away stopped the whole
/// product: no work clock, no prompt, nothing on screen saying why. So the read has a
/// deadline, the way the Accessibility path already has
/// `AXUIElementSetMessagingTimeout`, and a folder that misses it is set aside instead of
/// being asked again every few seconds.
public final class GitCollector: @unchecked Sendable {
    /// `HEAD` is one line. This is the whole read, and it is the bound that makes "never
    /// a file's contents" a property of the code rather than a promise.
    private static let headReadLimit = 512

    /// The same 0.25s the Accessibility collector gives an app to answer. The read is 50
    /// microseconds warm, so anything near this is a filesystem that is not going to
    /// answer at all.
    public static let defaultDeadline: TimeInterval = 0.25

    /// Concurrent on purpose. On a serial queue one blocked `stat` holds every later
    /// read behind it, so a dead mount would take the other registered folders with it
    /// even after the deadline let the caller go.
    private let queue = DispatchQueue(
        label: "dev.sigstop.git", qos: .utility, attributes: .concurrent
    )
    private let lock = NSLock()
    private let permissions: PermissionBroker
    private let memoWindow: TimeInterval
    private let deadline: TimeInterval
    private let reader: @Sendable (String, Date) -> Result<GitSignal, GitReadFailure>

    private var memo: (signal: GitSignal, folder: String, takenAt: Date)?
    private var outcome: GitScanOutcome = .optedOut
    /// Folders that missed the deadline. Nothing is asked of them again until the list of
    /// registered folders changes, which is the user's next statement about what they
    /// want read. Without this, a dead mount leaves one blocked thread per sample.
    private var unresponsive: Set<String> = []
    private var lastFolders: [String] = []

    public convenience init(
        permissions: PermissionBroker,
        memoWindow: TimeInterval = 4,
        deadline: TimeInterval = GitCollector.defaultDeadline
    ) {
        self.init(
            permissions: permissions,
            memoWindow: memoWindow,
            deadline: deadline,
            reader: { GitCollector.readRepository(at: $0, now: $1) }
        )
    }

    /// The reader is injectable so the deadline can be tested against a read that does
    /// not come back, which is the whole point of it and is not something a real
    /// filesystem will do on demand. `GitReadFailure` is internal, so this init is too.
    init(
        permissions: PermissionBroker,
        memoWindow: TimeInterval = 4,
        deadline: TimeInterval = GitCollector.defaultDeadline,
        reader: @escaping @Sendable (String, Date) -> Result<GitSignal, GitReadFailure>
    ) {
        self.permissions = permissions
        self.memoWindow = memoWindow
        self.deadline = deadline
        self.reader = reader
    }

    public var lastOutcome: GitScanOutcome {
        lock.lock(); defer { lock.unlock() }
        return outcome
    }

    // MARK: Reading

    public func read(
        frontmost: AppIdentity,
        folders: [String],
        documentURL: URL?,
        windowTitle: String?,
        now: Date
    ) async -> GitSignal? {
        noteFolders(folders)
        guard permissions.gitContextPermitted() else {
            record(.optedOut)
            return nil
        }
        guard BundleIDs.isEditorOrTerminal(frontmost) else {
            record(.skipped("the app in front is not an editor or a terminal"))
            return nil
        }
        guard !folders.isEmpty else {
            record(.noFoldersRegistered)
            return nil
        }
        guard let match = Self.match(folders: folders, documentURL: documentURL, title: windowTitle)
        else {
            record(.noFolderMatched(
                documentURL == nil && windowTitle == nil
                    ? "nothing at Tier 1 says which project you are in, and app identity alone "
                        + "cannot: turn on window titles, or keep one project folder registered"
                    : "the window in front does not name exactly one of the folders you added"
            ))
            return nil
        }

        if let cached = memoized(folder: match.folder, now: now) { return cached }

        let name = (match.folder as NSString).lastPathComponent
        guard !isSetAside(match.folder) else {
            record(.timedOut(folder: name))
            return nil
        }

        let result = await bounded(folder: match.folder, now: now)

        guard let result else {
            setAside(match.folder)
            record(.timedOut(folder: name))
            return nil
        }
        switch result {
        case .failure(.notPermitted):
            record(.notPermitted(folder: name))
            return nil
        case .failure:
            record(.noRepository(folder: name))
            return nil
        case .success(let signal):
            store(signal, folder: match.folder, name: name, route: match.route, now: now)
            return signal
        }
    }

    /// The read, or nil if the filesystem did not answer in time.
    ///
    /// The work item is not cancelled, because there is nothing to cancel: it is parked
    /// inside a blocking syscall and it will finish whenever the mount does. What this
    /// guarantees is that the *caller* comes back, which is the half that matters, since
    /// the caller is one `await` away from the tick loop.
    private func bounded(
        folder: String, now: Date
    ) async -> Result<GitSignal, GitReadFailure>? {
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            once.attach(continuation)
            queue.async { [reader] in once.resume(reader(folder, now)) }
            queue.asyncAfter(deadline: .now() + deadline) { once.resume(nil) }
        }
    }

    /// Whichever of the two arrives first wins, and the loser is dropped. Resuming a
    /// checked continuation twice is a crash, so this is a lock rather than a convention.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<GitSignal, GitReadFailure>?, Never>?
        private var done = false

        func attach(_ value: CheckedContinuation<Result<GitSignal, GitReadFailure>?, Never>) {
            lock.lock(); defer { lock.unlock() }
            continuation = value
        }

        func resume(_ value: Result<GitSignal, GitReadFailure>?) {
            lock.lock()
            guard !done, let continuation else { lock.unlock(); return }
            done = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        }
    }

    /// The lock is touched only from these three, because `NSLock` may not be held across
    /// a suspension point and `read` has one in the middle of it.
    private func memoized(folder: String, now: Date) -> GitSignal? {
        lock.lock(); defer { lock.unlock() }
        guard let memo, memo.folder == folder,
              now >= memo.takenAt, now.timeIntervalSince(memo.takenAt) < memoWindow
        else { return nil }
        return memo.signal
    }

    private func store(
        _ signal: GitSignal, folder: String, name: String, route: GitFolderRoute, now: Date
    ) {
        lock.lock(); defer { lock.unlock() }
        memo = (signal, folder, now)
        outcome = .read(
            folder: name,
            branchLength: signal.branch?.count ?? 0,
            detached: signal.branch == nil,
            route: route.rawValue
        )
    }

    private func isSetAside(_ folder: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return unresponsive.contains(folder)
    }

    private func setAside(_ folder: String) {
        lock.lock(); defer { lock.unlock() }
        unresponsive.insert(folder)
    }

    /// Changing the registered folders is the user saying something new about what they
    /// want read, so it is the moment a folder that timed out gets another chance.
    private func noteFolders(_ folders: [String]) {
        lock.lock(); defer { lock.unlock() }
        guard folders != lastFolders else { return }
        lastFolders = folders
        unresponsive.removeAll()
    }

    private func record(_ value: GitScanOutcome) {
        lock.lock(); defer { lock.unlock() }
        outcome = value
        memo = nil
    }

    // MARK: Which folder

    struct FolderMatch: Sendable, Hashable {
        let folder: String
        let route: GitFolderRoute
    }

    /// Exactly one registered folder, or nothing.
    ///
    /// The document path wins because it is a fact: the editor said this file is open and
    /// the file is inside that folder. The title is the fallback and covers the Electron
    /// editors, which return `kAXDocument` as `.success` with an empty string. Two matches
    /// means two projects open and the app cannot tell which one you are looking at, which
    /// per CLAUDE.md §4.1 must produce no branch rather than a coin flip.
    static func match(folders: [String], documentURL: URL?, title: String?) -> FolderMatch? {
        let roots = folders.map { ($0 as NSString).standardizingPath }

        if let url = documentURL, url.isFileURL, url.host == nil {
            let path = url.standardizedFileURL.path
            let inside = roots.filter { path == $0 || path.hasPrefix($0 + "/") }
            if inside.count == 1, let folder = inside.first {
                return FolderMatch(folder: folder, route: .documentPath)
            }
            if inside.count > 1 { return nil }
        }

        guard let title, !title.isEmpty else { return nil }
        let named = roots.filter { root in
            let name = (root as NSString).lastPathComponent
            guard name.count >= 3 else { return false }
            return containsWholeToken(name, in: title)
        }
        guard named.count == 1, let folder = named.first else { return nil }
        return FolderMatch(folder: folder, route: .windowTitle)
    }

    /// A folder called `app` must not match every window title that happens to contain the
    /// letters. The name has to stand as its own word.
    static func containsWholeToken(_ needle: String, in haystack: String) -> Bool {
        let lowerHay = Array(haystack.lowercased())
        let lowerNeedle = Array(needle.lowercased())
        guard !lowerNeedle.isEmpty, lowerHay.count >= lowerNeedle.count else { return false }
        func isBoundary(_ character: Character?) -> Bool {
            guard let character else { return true }
            return !(character.isLetter || character.isNumber)
        }
        for start in 0...(lowerHay.count - lowerNeedle.count) {
            guard Array(lowerHay[start..<(start + lowerNeedle.count)]) == lowerNeedle else { continue }
            let before = start > 0 ? lowerHay[start - 1] : nil
            let end = start + lowerNeedle.count
            let after = end < lowerHay.count ? lowerHay[end] : nil
            if isBoundary(before) && isBoundary(after) { return true }
        }
        return false
    }

    // MARK: The read

    enum GitReadFailure: Error, Sendable, Hashable {
        /// macOS said no. A repository under `~/Desktop`, `~/Documents` or `~/Downloads`
        /// can do this, and it is a different fact from there being no repository, which
        /// is why it is a different case.
        case notPermitted
        case noRepository
    }

    static func readRepository(at folder: String, now: Date) -> Result<GitSignal, GitReadFailure> {
        switch resolveGitDirectory(at: folder) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let gitDirectory):
            switch readFirstLine(gitDirectory + "/HEAD") {
            case .failure(let failure):
                return .failure(failure)
            case .success(let head):
                let parsed = parseHEAD(head)
                let branch = parsed.branch ?? rebaseBranch(in: gitDirectory)
                return .success(GitSignal(
                    branch: branch,
                    repoState: repoState(in: gitDirectory, detached: parsed.detached && branch == nil),
                    repoName: (folder as NSString).lastPathComponent,
                    readAt: now
                ))
            }
        }
    }

    /// `.git` is usually a directory. In a worktree it is a **file** holding an absolute
    /// `gitdir:` line, and in a submodule a **file** holding a relative one, which has to
    /// be resolved against the folder that contains it rather than the process's working
    /// directory. That one indirection is followed once and never recursively.
    static func resolveGitDirectory(at folder: String) -> Result<String, GitReadFailure> {
        let dot = folder + "/.git"
        var info = stat()
        guard stat(dot, &info) == 0 else {
            return .failure(errno == EACCES || errno == EPERM ? .notPermitted : .noRepository)
        }
        if info.st_mode & S_IFMT == S_IFDIR { return .success(dot) }

        switch readFirstLine(dot) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let line):
            let prefix = "gitdir:"
            guard line.hasPrefix(prefix) else { return .failure(.noRepository) }
            let raw = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return .failure(.noRepository) }
            return .success(raw.hasPrefix("/") ? raw : folder + "/" + raw)
        }
    }

    /// `ref: refs/heads/<name>` is a branch. Forty hex characters is a detached HEAD, and
    /// the app says so rather than presenting a commit id as a branch name.
    static func parseHEAD(_ line: String) -> (branch: String?, detached: Bool) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        if trimmed.hasPrefix(prefix) {
            let name = String(trimmed.dropFirst(prefix.count))
            return (name.isEmpty ? nil : name, false)
        }
        if trimmed.count == 40, trimmed.allSatisfy(\.isHexDigit) { return (nil, true) }
        return (nil, false)
    }

    /// Mid-rebase, HEAD is a detached sha and the branch you think you are on is in
    /// `rebase-merge/head-name`. Reporting nothing there would be technically true and
    /// useless, since being mid-rebase is exactly when a break is worth naming properly.
    static func rebaseBranch(in gitDirectory: String) -> String? {
        for candidate in ["/rebase-merge/head-name", "/rebase-apply/head-name"] {
            guard case .success(let line) = readFirstLine(gitDirectory + candidate) else { continue }
            let prefix = "refs/heads/"
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(prefix) else { continue }
            let name = String(trimmed.dropFirst(prefix.count))
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// Four `access` calls. Each one answers a yes/no question and opens nothing, so the
    /// app learns that a rebase is in progress and never what is being rebased.
    static func repoState(in gitDirectory: String, detached: Bool) -> RepoState {
        func exists(_ suffix: String) -> Bool { access(gitDirectory + suffix, F_OK) == 0 }
        if exists("/rebase-merge") || exists("/rebase-apply") { return .rebaseInProgress }
        if exists("/MERGE_HEAD") { return .mergeInProgress }
        if exists("/BISECT_LOG") { return .bisecting }
        return detached ? .detachedHead : .clean
    }

    /// Opens the file, reads at most one line's worth, and closes it. `EACCES` and `EPERM`
    /// are kept separate from every other failure so the app can say *not allowed to look*
    /// instead of *no repository*, which are different things and look identical if you
    /// only check for nil.
    static func readFirstLine(_ path: String) -> Result<String, GitReadFailure> {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            return .failure(errno == EACCES || errno == EPERM ? .notPermitted : .noRepository)
        }
        defer { close(descriptor) }

        var buffer = [UInt8](repeating: 0, count: headReadLimit)
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            Darwin.read(descriptor, raw.baseAddress, headReadLimit)
        }
        guard count > 0 else { return .failure(.noRepository) }
        let end = buffer.prefix(count).firstIndex(of: UInt8(ascii: "\n")) ?? count
        return .success(String(decoding: buffer[0..<end], as: UTF8.self))
    }
}
