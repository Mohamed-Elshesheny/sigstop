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

    private var onDisk: String?

    public init() {}

    public mutating func update(enabled: Bool, line: String) -> Action? {
        guard enabled else {
            guard onDisk != nil else { return nil }
            onDisk = nil
            return .remove
        }
        guard onDisk != line else { return nil }
        onDisk = line
        return .write(line)
    }

    public mutating func noteWriteFailed() {
        onDisk = nil
    }
}
