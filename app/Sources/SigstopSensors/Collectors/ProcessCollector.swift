import Darwin
import Foundation
import SigstopCore

// MARK: - Outcome

/// What the last scan did, for `--doctor`.
///
/// Four cases and not a `ProcessSnapshot?`, because "the switch is off", "the gate said
/// no this time", "the table could not be read" and "nothing matched" are four different
/// facts and the first three are not "no debugger is running". Collapsing them is exactly
/// the lie docs/ACTIVITY-DETECTION.md §4.3(b) forbids when it says to treat every read
/// failure as no information.
public enum ProcessScanOutcome: Sendable, Hashable {
    case optedOut
    /// The opt-in is on and the §8.2 gate declined this sample. Carries the reason.
    case skipped(String)
    /// `sysctl` failed, or returned a zero-length table. A machine with no processes on
    /// it does not exist, so this is a failure, never an empty result.
    case unreadable
    case scanned(processCount: Int)
}

// MARK: - Allowlist

/// The tools the collector is allowed to notice, by executable name.
///
/// This list is the whole feature. Anything not on it is not reported, not counted, and
/// not held anywhere: the scan compares a name, and a process that matches nothing leaves
/// no trace of having existed. The list lives here, in the source, for the same reason
/// `BundleIDs` does, so a sceptic can read it and a contributor can correct it.
///
/// Every entry is a real Mach-O binary that carries its own name. That is the load-bearing
/// property, and it is why the list is shorter than `ToolToken`. A tool that is a shebang
/// script is named by its *arguments*: a `#!/usr/bin/env node` script called `jest` is
/// `node` to the kernel, and `python3 -m debugpy` is `Python`. Naming those would mean
/// reading `KERN_PROCARGS2`, which is where passwords and `AWS_SECRET_ACCESS_KEY` live, so
/// they are simply not detected and `--doctor` says so in those words.
public enum ToolAllowlist {
    public struct Entry: Sendable, Hashable {
        public let comm: String
        public let token: ToolToken
        public let verifiedHere: Bool
    }

    /// `verifiedHere` means a process with that `p_comm` was actually observed on the
    /// machine this was written on, in the same spirit as the VERIFIED / UNVERIFIED marks
    /// on `BundleIDs`. Unverified entries are inference from the fact that the tool ships
    /// as its own executable, which is a much weaker claim and is marked as one.
    public static let entries: [Entry] = [
        Entry(comm: "debugserver", token: .debugserver, verifiedHere: true),
        Entry(comm: "lldb", token: .lldb, verifiedHere: false),
        Entry(comm: "gdb", token: .gdb, verifiedHere: false),
        Entry(comm: "dlv", token: .delve, verifiedHere: false),

        Entry(comm: "xctest", token: .xctest, verifiedHere: false),

        Entry(comm: "vim", token: .vim, verifiedHere: true),
        Entry(comm: "nvim", token: .nvim, verifiedHere: false),
        Entry(comm: "hx", token: .helix, verifiedHere: false),
        Entry(comm: "emacs", token: .emacs, verifiedHere: false),
        Entry(comm: "nano", token: .nano, verifiedHere: false),

        Entry(comm: "claude", token: .claudeCLI, verifiedHere: true),
        Entry(comm: "aider", token: .aider, verifiedHere: false),
        Entry(comm: "codex", token: .codexCLI, verifiedHere: false),
        Entry(comm: "goose", token: .gooseCLI, verifiedHere: false),

        Entry(comm: "ssh", token: .ssh, verifiedHere: true),
        Entry(comm: "mosh-client", token: .mosh, verifiedHere: false),
        Entry(comm: "kubectl", token: .kubectl, verifiedHere: false),
    ]

    /// Tokens that exist in `ToolToken` and are deliberately absent above, with the reason.
    /// `--doctor` prints this rather than reporting them as not running.
    public static let undetectable: [ToolToken] = [
        .nodeInspect, .debugpy, .pytest, .jest, .vitest, .playwright, .rspec, .phpunit,
        .goTest, .cargoTest, .swiftTesting, .swiftBuild, .tsc, .webpack, .vite,
    ]

    /// The names above, compiled once into NUL-terminated bytes.
    ///
    /// This exists for a measured reason. Comparing against the `String` directly makes
    /// every `strncmp` bridge a Swift string into a C buffer, and the scan does that for
    /// every process on the machine: 17,000 conversions per scan, which measured 1.5 ms
    /// where the same work over bytes measures a fraction of it. The first byte is kept
    /// beside them so the overwhelming majority of processes are rejected by one compare.
    private struct CompiledName {
        let first: CChar
        let bytes: ContiguousArray<CChar>
        let token: ToolToken
    }

    private static let compiled: [CompiledName] = entries.map { entry in
        var bytes = ContiguousArray(entry.comm.utf8.map { CChar(bitPattern: $0) })
        bytes.append(0)
        return CompiledName(first: bytes[0], bytes: bytes, token: entry.token)
    }

    /// Compared against `p_comm` in place, without allocating anything per process.
    /// `p_comm` is `MAXCOMLEN + 1` bytes and NUL-terminated, and no name above is longer
    /// than 15 characters, so an exact compare here cannot be satisfied by the truncated
    /// prefix of some longer name.
    public static func token(comm: UnsafePointer<CChar>) -> ToolToken? {
        let first = comm.pointee
        guard first != 0 else { return nil }
        for candidate in compiled where candidate.first == first {
            let equal: Bool = candidate.bytes.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return false }
                return strncmp(comm, base, 16) == 0
            }
            if equal { return candidate.token }
        }
        return nil
    }

    public static func expectedName(for token: ToolToken) -> String? {
        entries.first { $0.token == token }?.comm
    }
}

// MARK: - Collector

/// The Tier 2 process snapshot: is a known debugger running, and is anything on this Mac
/// under `ptrace` right now.
///
/// **What it reads.** One `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_ALL)`, which yields
/// `p_comm`, `e_ppid` and `p_flag` for every process, and `proc_pidpath` for the handful
/// of pids whose name already matched the allowlist. Both are public, need no permission
/// and produce no prompt. `KERN_PROCARGS2` is never called, so no command line, argument
/// or environment variable is ever in this process's memory, and `proc_pidinfo` is never
/// called, so no working directory is either.
///
/// **What it costs.** 0.17 ms per scan over 1006 processes, mean of 200 scans of the real
/// table in a release build on the development machine. It is not on a timer of its own:
/// it runs inside the sample the context engine was already going to build, behind the
/// §8.2 gate, and a memo holds the answer for a few seconds so a burst of samples shares
/// one scan. At one scan every five seconds that is 0.003% of one core.
///
/// **Why `P_TRACED` matters more than a name.** A name says a binary with that name is
/// running. `kp_proc.p_flag & P_TRACED` is set on the process *being debugged*, so it says
/// something has that process under `ptrace` at this instant. It is as near an OS fact as
/// this tier gets, it covers debuggers nobody has heard of, and it is in the buffer the
/// scan already fetched. It does not cover `node --inspect` or `debugpy`, which use their
/// own protocols and never call `ptrace`, which is one more reason those two are written
/// off rather than guessed at.
public final class ProcessCollector: @unchecked Sendable {
    /// `PROC_PIDPATHINFO_MAXSIZE` is a C macro and does not import into Swift. Its value
    /// is `4 * MAXPATHLEN`, named here rather than left as a literal at the call site.
    private static let pathBufferSize: Int32 = 4096
    /// Idle above this and the gate declines: docs/ACTIVITY-DETECTION.md §8.2.
    private static let idleGate: TimeInterval = 120

    private let lock = NSLock()
    private let permissions: PermissionBroker
    private let memoWindow: TimeInterval

    private var memo: (snapshot: ProcessSnapshot, frontmostPID: pid_t, takenAt: Date)?
    private var outcome: ProcessScanOutcome = .optedOut

    public init(permissions: PermissionBroker, memoWindow: TimeInterval = 4) {
        self.permissions = permissions
        self.memoWindow = memoWindow
    }

    /// What the last call did. Read by `--doctor`, which has to say which of "off",
    /// "not this sample", "could not read" and "nothing matched" happened.
    public var lastOutcome: ProcessScanOutcome {
        lock.lock(); defer { lock.unlock() }
        return outcome
    }

    /// The memoized snapshot, for `--doctor` only. `nil` whenever the last call did not
    /// produce one, which includes every gated and every failed sample.
    public var lastSnapshot: ProcessSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return memo?.snapshot
    }

    // MARK: Sampling

    /// The gate from docs/ACTIVITY-DETECTION.md §8.2, then the scan, then the memo.
    ///
    /// Returns `nil` for every case that is not a successful read, including the gated
    /// ones. A caller must treat `nil` as *no information*: an empty `ProcessSnapshot`
    /// would mean *no debugger is running*, which is a claim this collector is often in no
    /// position to make.
    public func snapshot(
        frontmost: AppIdentity,
        input: InputActivity,
        power: PowerState,
        now: Date
    ) -> ProcessSnapshot? {
        guard permissions.processContextPermitted() else {
            record(.optedOut)
            return nil
        }
        if let reason = gateReason(frontmost: frontmost, input: input, power: power) {
            record(.skipped(reason))
            return nil
        }

        lock.lock()
        if let memo, memo.frontmostPID == frontmost.pid,
           now.timeIntervalSince(memo.takenAt) < memoWindow,
           now >= memo.takenAt {
            let cached = memo.snapshot
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let scan = Self.scan(frontmostPID: frontmost.pid, now: now) else {
            record(.unreadable)
            return nil
        }

        lock.lock()
        memo = (scan.snapshot, frontmost.pid, now)
        outcome = .scanned(processCount: scan.processCount)
        lock.unlock()
        return scan.snapshot
    }

    /// Why this sample will not be scanned, or `nil` to go ahead.
    private func gateReason(
        frontmost: AppIdentity, input: InputActivity, power: PowerState
    ) -> String? {
        guard BundleIDs.isEditorOrTerminal(frontmost) else {
            return "the app in front is not an editor or a terminal"
        }
        if let idle = input.knownIdleSeconds, idle >= Self.idleGate {
            return "nobody has touched this Mac for \(Int(idle))s"
        }
        if power.thermal.shouldShedLoad {
            return "this Mac is thermally throttled"
        }
        if power.onBattery && power.lowPowerMode {
            return "on battery, in Low Power Mode"
        }
        return nil
    }

    private func record(_ value: ProcessScanOutcome) {
        lock.lock()
        outcome = value
        memo = nil
        lock.unlock()
    }

    // MARK: The scan

    private struct Scan {
        let snapshot: ProcessSnapshot
        let processCount: Int
    }

    private static func scan(frontmostPID: pid_t, now: Date) -> Scan? {
        withProcessTable { procs, count in
            var parentPairs: [(pid: pid_t, ppid: pid_t)] = []
            parentPairs.reserveCapacity(count)
            var matches: [(pid: pid_t, token: ToolToken)] = []
            var tracedPIDs: [pid_t] = []

            for index in 0..<count {
                let entry = procs + index
                let pid = entry.pointee.kp_proc.p_pid
                parentPairs.append((pid, entry.pointee.kp_eproc.e_ppid))
                if entry.pointee.kp_proc.p_flag & P_TRACED != 0 { tracedPIDs.append(pid) }
                var comm = entry.pointee.kp_proc.p_comm
                let token = withUnsafePointer(to: &comm) { raw -> ToolToken? in
                    raw.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                        ToolAllowlist.token(comm: $0)
                    }
                }
                if let token { matches.append((pid, token)) }
            }

            /// The parent map is built only when there is something to walk, which is the
            /// overwhelmingly common case: with no debugger running nothing matches and
            /// nothing is traced, so the whole scan is one `sysctl` and one pass of name
            /// compares over memory that was never copied.
            guard !matches.isEmpty || !tracedPIDs.isEmpty else {
                return Scan(
                    snapshot: ProcessSnapshot(
                        matchedTools: [], childrenOfFrontmost: [], capturedAt: now
                    ),
                    processCount: count
                )
            }
            var parents: [pid_t: pid_t] = [:]
            parents.reserveCapacity(parentPairs.count)
            for pair in parentPairs { parents[pair.pid] = pair.ppid }

            var matched: Set<ToolToken> = []
            var children: Set<ToolToken> = []
            for match in matches {
                /// `p_comm` was only the prefilter. The authority is `proc_pidpath`, which
                /// returns the complete, untruncated path with no permission at all. A pid
                /// whose path cannot be read is dropped rather than credited: a read
                /// failure is no information, not a confirmation.
                guard let path = executablePath(match.pid) else { continue }
                guard (path as NSString).lastPathComponent
                    == ToolAllowlist.expectedName(for: match.token) else { continue }
                matched.insert(match.token)
                if descends(match.pid, from: frontmostPID, parents: parents) {
                    children.insert(match.token)
                }
            }

            var tracedUnderFrontmost = false
            var tracedElsewhere = false
            for pid in tracedPIDs {
                if descends(pid, from: frontmostPID, parents: parents) {
                    tracedUnderFrontmost = true
                } else {
                    tracedElsewhere = true
                }
            }

            return Scan(
                snapshot: ProcessSnapshot(
                    matchedTools: matched,
                    childrenOfFrontmost: children,
                    tracedUnderFrontmost: tracedUnderFrontmost,
                    tracedElsewhere: tracedElsewhere,
                    capturedAt: now
                ),
                processCount: count
            )
        }
    }

    /// One `sysctl`, sized then read, into raw memory that is never zero-filled and never
    /// copied out. The table is 650 KB on a machine with a thousand processes, so taking
    /// it as a `[kinfo_proc]` would mean zeroing that much, filling it, and copying it
    /// again for no gain. The buffer does not escape this call.
    ///
    /// A zero-length result is a failure, not a Mac with no processes on it: a sandbox
    /// profile without `sysctl-read` produces exactly that and sets no errno a caller
    /// would notice.
    private static func withProcessTable(_ body: (UnsafePointer<kinfo_proc>, Int) -> Scan?) -> Scan? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var sized = 0
        guard sysctl(&mib, 4, nil, &sized, nil, 0) == 0, sized > 0 else { return nil }

        let stride = MemoryLayout<kinfo_proc>.stride
        let capacity = sized + 64 * stride
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: capacity, alignment: MemoryLayout<kinfo_proc>.alignment
        )
        defer { raw.deallocate() }

        var got = capacity
        guard sysctl(&mib, 4, raw, &got, nil, 0) == 0, got >= stride else { return nil }
        let count = got / stride
        return body(UnsafePointer(raw.bindMemory(to: kinfo_proc.self, capacity: count)), count)
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(pathBufferSize))
        let written = buffer.withUnsafeMutableBytes { raw -> Int32 in
            proc_pidpath(pid, raw.baseAddress, UInt32(pathBufferSize))
        }
        guard written > 0, written <= pathBufferSize else { return nil }
        let end = buffer.prefix(Int(written)).firstIndex(of: 0) ?? Int(written)
        return String(decoding: buffer[0..<end], as: UTF8.self)
    }

    /// Does `pid` reach `ancestor` by walking parents?
    ///
    /// Bounded, and it does not stop at a process whose own details are unreadable: a
    /// terminal's shell is a grandchild through a root-owned `login`, so a walk that gave
    /// up at the first uid it could not inspect would find nothing under Terminal.app.
    /// Only the parent *link* is needed here, and `KERN_PROC_ALL` supplies it for every
    /// process regardless of owner.
    static func descends(_ pid: pid_t, from ancestor: pid_t, parents: [pid_t: pid_t]) -> Bool {
        guard ancestor > 0, pid != ancestor else { return false }
        var current = pid
        for _ in 0..<32 {
            guard let parent = parents[current], parent > 1 else { return false }
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }
}
