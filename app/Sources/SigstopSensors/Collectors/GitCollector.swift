import Darwin
import Foundation
import SigstopCore

public enum GitScanOutcome: Sendable, Hashable {
    case optedOut
    case skipped(String)
    case noFoldersRegistered
    case noFolderMatched(String)
    case notPermitted(folder: String)
    case noRepository(folder: String)
    case timedOut(folder: String)
    case read(folder: String, branchLength: Int, head: GitHead, route: String)
}

public enum GitFolderRoute: String, Sendable, Hashable {
    case documentPath = "the document path your editor reported"
    case windowTitle = "the project named in the window title"
}

public final class GitCollector: @unchecked Sendable {
    private static let headReadLimit = 512

    static let reftablePlaceholder = ".invalid"

    public static let defaultDeadline: TimeInterval = 1.0

    static let strikesBeforeSettingAside = 2

    private let queue = DispatchQueue(
        label: "dev.sigstop.git", qos: .userInitiated, attributes: .concurrent
    )
    private let deadlineQueue = DispatchQueue(label: "dev.sigstop.git.deadline", qos: .userInitiated)
    private let lock = NSLock()
    private let permissions: PermissionBroker
    private let memoWindow: TimeInterval
    private let deadline: TimeInterval
    private let reader: @Sendable (String, Date) -> Result<GitSignal, GitReadFailure>

    private var memo: (signal: GitSignal, folder: String, takenAt: Date)?
    private var outcome: GitScanOutcome = .optedOut
    private var misses: [String: Int] = [:]
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

    public var lastScan: (outcome: GitScanOutcome, signal: GitSignal?) {
        lock.lock(); defer { lock.unlock() }
        guard case .read = outcome else { return (outcome, nil) }
        return (outcome, memo?.signal)
    }

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
            noteMiss(match.folder)
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
            clearMisses(match.folder)
            store(signal, folder: match.folder, name: name, route: match.route, now: now)
            return signal
        }
    }

    private func bounded(
        folder: String, now: Date
    ) async -> Result<GitSignal, GitReadFailure>? {
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            once.attach(continuation)
            queue.async { [reader] in once.resume(reader(folder, now)) }
            deadlineQueue.asyncAfter(deadline: .now() + deadline) { once.resume(nil) }
        }
    }

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
            head: signal.head,
            route: route.rawValue
        )
    }

    private func isSetAside(_ folder: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return misses[folder, default: 0] >= Self.strikesBeforeSettingAside
    }

    private func noteMiss(_ folder: String) {
        lock.lock(); defer { lock.unlock() }
        misses[folder, default: 0] += 1
    }

    private func clearMisses(_ folder: String) {
        lock.lock(); defer { lock.unlock() }
        misses[folder] = nil
    }

    private func noteFolders(_ folders: [String]) {
        lock.lock(); defer { lock.unlock() }
        guard folders != lastFolders else { return }
        lastFolders = folders
        misses.removeAll()
    }

    private func record(_ value: GitScanOutcome) {
        lock.lock(); defer { lock.unlock() }
        outcome = value
        memo = nil
    }

    struct FolderMatch: Sendable, Hashable {
        let folder: String
        let route: GitFolderRoute
    }

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

    enum GitReadFailure: Error, Sendable, Hashable {
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
                    readAt: now,
                    headInReftable: parsed.reftable
                ))
            }
        }
    }

    static func resolveGitDirectory(at folder: String) -> Result<String, GitReadFailure> {
        let dot = folder + "/.git"
        var info = stat()
        guard lstat(dot, &info) == 0 else {
            return .failure(errno == EACCES || errno == EPERM ? .notPermitted : .noRepository)
        }
        if info.st_mode & S_IFMT == S_IFDIR { return .success(dot) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .failure(.noRepository) }

        switch readStart(of: dot, wholeFile: true) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let contents):
            guard let raw = gitdirTarget(contents) else { return .failure(.noRepository) }
            let target = raw.hasPrefix("/") ? raw : folder + "/" + raw
            guard let resolved = realPath(target), isGitDirectory(resolved) else {
                return .failure(.noRepository)
            }
            return .success(resolved)
        }
    }

    static func gitdirTarget(_ contents: [UInt8]) -> String? {
        let prefix = Array("gitdir: ".utf8)
        guard contents.starts(with: prefix) else { return nil }
        var end = contents.count
        while end > prefix.count,
              contents[end - 1] == UInt8(ascii: "\n") || contents[end - 1] == UInt8(ascii: "\r") {
            end -= 1
        }
        guard end > prefix.count else { return nil }
        return String(decoding: contents[prefix.count..<end], as: UTF8.self)
    }

    static func isGitDirectory(_ path: String) -> Bool {
        func kind(_ suffix: String) -> mode_t? {
            var info = stat()
            guard lstat(path + suffix, &info) == 0 else { return nil }
            return info.st_mode & S_IFMT
        }
        guard kind("") == S_IFDIR, kind("/HEAD") == S_IFREG else { return false }
        return kind("/objects") == S_IFDIR || kind("/commondir") == S_IFREG
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func parseHEAD(_ line: String) -> (branch: String?, detached: Bool, reftable: Bool) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        if trimmed.hasPrefix(prefix) {
            let name = String(trimmed.dropFirst(prefix.count))
            if name == reftablePlaceholder { return (nil, false, true) }
            return (name.isEmpty ? nil : name, false, false)
        }
        if trimmed.count == 40 || trimmed.count == 64, trimmed.allSatisfy(\.isHexDigit) {
            return (nil, true, false)
        }
        return (nil, false, false)
    }

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

    static func repoState(in gitDirectory: String, detached: Bool) -> RepoState {
        func exists(_ suffix: String) -> Bool { access(gitDirectory + suffix, F_OK) == 0 }
        if exists("/rebase-merge") || exists("/rebase-apply") { return .rebaseInProgress }
        if exists("/MERGE_HEAD") { return .mergeInProgress }
        if exists("/BISECT_LOG") { return .bisecting }
        return detached ? .detachedHead : .clean
    }

    static func readFirstLine(_ path: String) -> Result<String, GitReadFailure> {
        readStart(of: path, wholeFile: false).map { bytes in
            let end = bytes.firstIndex(of: UInt8(ascii: "\n")) ?? bytes.count
            return String(decoding: bytes[0..<end], as: UTF8.self)
        }
    }

    static func readStart(of path: String, wholeFile: Bool) -> Result<[UInt8], GitReadFailure> {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            return .failure(errno == EACCES || errno == EPERM ? .notPermitted : .noRepository)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return .failure(.noRepository)
        }
        if wholeFile, info.st_size > headReadLimit { return .failure(.noRepository) }

        var buffer = [UInt8](repeating: 0, count: headReadLimit)
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            Darwin.read(descriptor, raw.baseAddress, headReadLimit)
        }
        guard count > 0 else { return .failure(.noRepository) }
        if wholeFile, count != Int(info.st_size) { return .failure(.noRepository) }
        return .success(Array(buffer[0..<count]))
    }
}
