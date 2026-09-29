import Foundation
import SigstopCore

public struct FinishedCommand: Sendable, Hashable {
    public let tool: ToolToken?
    public let evidence: [Evidence]
    public let confidence: Confidence
    public let noticedAt: Date

    public init(tool: ToolToken?, evidence: [Evidence], confidence: Confidence, noticedAt: Date) {
        self.tool = tool
        self.evidence = evidence
        self.confidence = confidence
        self.noticedAt = noticedAt
    }

    public var seam: Seam { .terminalCommandFinished }

    public var summary: String {
        evidence.map(\.summary).joined(separator: "; ")
    }
}

public struct CommandWatch: Sendable, Hashable {
    public static let maxGap: TimeInterval = 60
    public static let ceiling = ConfidenceEngine.debuggingCeiling

    private struct Scan: Sendable, Hashable {
        let snapshot: ProcessSnapshot
        let frontmostPID: pid_t
        let settled: Set<ToolToken>
    }

    private var last: Scan?

    public init() {}

    public mutating func observe(_ snapshot: ProcessSnapshot?, frontmostPID: pid_t) -> FinishedCommand? {
        let previous = last
        last = snapshot.map { current in
            Scan(
                snapshot: current,
                frontmostPID: frontmostPID,
                settled: Self.settled(current, after: previous)
            )
        }
        guard let snapshot, let previous else { return nil }
        return Self.compare(
            previous: previous.snapshot,
            settled: previous.settled,
            previousFrontmostPID: previous.frontmostPID,
            current: snapshot,
            currentFrontmostPID: frontmostPID
        )
    }

    private static func settled(_ current: ProcessSnapshot, after previous: Scan?) -> Set<ToolToken> {
        guard let previous else { return [] }
        guard current.capturedAt > previous.snapshot.capturedAt else { return previous.settled }
        return current.childrenOfFrontmost.intersection(previous.snapshot.childrenOfFrontmost)
    }

    public static func compare(
        previous: ProcessSnapshot,
        settled: Set<ToolToken>,
        previousFrontmostPID: pid_t,
        current: ProcessSnapshot,
        currentFrontmostPID: pid_t
    ) -> FinishedCommand? {
        let gap = current.capturedAt.timeIntervalSince(previous.capturedAt)
        guard gap > 0, gap <= maxGap else { return nil }

        let sameFrontmost = previousFrontmostPID == currentFrontmostPID
        let stillRunning = sameFrontmost ? current.childrenOfFrontmost : current.matchedTools
        let gone = settled.intersection(previous.childrenOfFrontmost).subtracting(stillRunning)
        let tool = gone.sorted { $0.rawValue < $1.rawValue }.first

        var evidence: [Evidence] = []
        if let tool { evidence.append(Ev.commandFinished(tool)) }
        if sameFrontmost, previous.tracedUnderFrontmost, !current.tracedUnderFrontmost {
            evidence.append(Ev.debugSessionEnded())
        }
        guard !evidence.isEmpty else { return nil }

        let raw = Probability.combine(evidence).value
        return FinishedCommand(
            tool: tool,
            evidence: evidence,
            confidence: Confidence(min(raw, ceiling)),
            noticedAt: current.capturedAt
        )
    }
}
