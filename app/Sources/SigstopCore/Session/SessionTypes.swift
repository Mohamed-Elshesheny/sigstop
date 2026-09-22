import Foundation

public enum PauseCause: String, Sendable, Codable, Hashable {
    case microIdleExceeded
    case screenLocked
    case systemSleep
    case displaySleep
    case fastUserSwitch
    case meetingNoInput
    case breakActive
    case userPaused
}

public enum WorkClockState: Sendable, Codable, Hashable {
    case running
    case paused(cause: PauseCause, since: Date)
    case stopped
}

public enum ResetReason: String, Sendable, Codable, Hashable {
    case qualifyingBreak
    case longPause
    case sessionStart
    case dayBoundary
    case userReset
}

public struct CycleID: Sendable, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public func next() -> CycleID { CycleID(rawValue: rawValue + 1) }
    public static let initial = CycleID(rawValue: 0)
}

public enum GapClassification: Sendable, Hashable {
    case microIdle
    case pause(PauseCause)
    case qualifyingBreak
    case sessionEnd
}

public enum BreakOrigin: String, Sendable, Codable, Hashable {
    case accepted
    case idleInferred
    case userInitiated
}
