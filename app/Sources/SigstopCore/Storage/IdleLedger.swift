import Foundation

public struct IdleLedger: Sendable, Hashable {

    public private(set) var began: Date?

    public init() {}

    public mutating func observe(
        _ events: [SessionEvent],
        idleSeconds: TimeInterval,
        paused: Bool,
        grace: TimeInterval,
        at now: Date
    ) -> [LoggedEvent] {
        var lines: [LoggedEvent] = []
        for event in events {
            switch event {
            case .clockPaused(let cause, let since):
                guard began == nil, cause != .breakActive, cause != .userPaused else { continue }
                lines.append(open(at: since))
            case .clockResumed:
                guard began != nil else { continue }
                lines.append(close(at: now))
            case .sessionEnded:
                began = nil
            default:
                continue
            }
        }
        guard paused else { return lines }
        if began == nil, idleSeconds >= grace {
            lines.append(open(at: now.addingTimeInterval(-idleSeconds)))
        } else if began != nil, idleSeconds < grace {
            lines.append(close(at: now))
        }
        return lines
    }

    private mutating func open(at since: Date) -> LoggedEvent {
        began = since
        return .idleBegin(at: since)
    }

    private mutating func close(at now: Date) -> LoggedEvent {
        let since = began ?? now
        began = nil
        return .idleEnd(at: now, idleSeconds: Int(now.timeIntervalSince(since).rounded()))
    }
}
