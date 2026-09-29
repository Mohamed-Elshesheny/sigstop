import Foundation

public enum StatusWord {
    public static func read(state: EngineState, indicator: IndicatorState) -> String {
        if case .quiet(let q) = state, q.cause == .userPaused { return "paused" }
        if indicator == .backedOff { return "stood down" }
        switch state {
        case .working:      return "running"
        case .breakDue:     return "break due"
        case .ignored:      return "escalating"
        case .snoozed:      return "snoozed"
        case .breakActive:  return "stopped"
        case .idle:         return "idle"
        case .quiet(let q): return q.cause.title
        }
    }
}

public enum StatusLine {
    public static let fileName = "status.txt"
    public static let separator = " \u{00B7} "

    public static func render(word: String, waiting: WaitingLine) -> String {
        "\(word)\(separator)\(waiting.text)\n"
    }
}

public struct StatusLineLedger: Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        case write(String)
        case remove
    }

    public static let retryInterval: TimeInterval = 60

    private struct Failure: Sendable, Hashable {
        let line: String
        let at: Double
    }

    private var armed = false
    private var onDisk: String?
    private var failure: Failure?

    public init() {}

    public mutating func update(enabled: Bool, line: String, now: Double) -> Action? {
        guard enabled else {
            guard armed else { return nil }
            armed = false
            onDisk = nil
            failure = nil
            return .remove
        }
        armed = true
        guard onDisk != line else { return nil }
        if let failure, failure.line == line, now - failure.at < Self.retryInterval { return nil }
        onDisk = line
        failure = nil
        return .write(line)
    }

    public mutating func noteWriteFailed(at now: Double) {
        failure = onDisk.map { Failure(line: $0, at: now) }
        onDisk = nil
    }
}
