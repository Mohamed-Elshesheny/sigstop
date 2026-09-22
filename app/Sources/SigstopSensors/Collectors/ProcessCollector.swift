import Darwin
import Foundation
import SigstopCore

public enum ProcessScanOutcome: Sendable, Hashable {
    case optedOut
    case skipped(String)
    case unreadable
    case scanned(processCount: Int)
}

public enum ToolAllowlist {
    public struct Entry: Sendable, Hashable {
        public let comm: String
        public let token: ToolToken
        public let verifiedHere: Bool
    }

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

    public static let undetectable: [ToolToken] = [
        .nodeInspect, .debugpy, .pytest, .jest, .vitest, .playwright, .rspec, .phpunit,
        .goTest, .cargoTest, .swiftTesting, .swiftBuild, .tsc, .webpack, .vite,
    ]

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

public final class ProcessCollector: @unchecked Sendable {
    private static let pathBufferSize: Int32 = 4096
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

    public var lastOutcome: ProcessScanOutcome {
        lock.lock(); defer { lock.unlock() }
        return outcome
    }

    public var lastSnapshot: ProcessSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return memo?.snapshot
    }

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
