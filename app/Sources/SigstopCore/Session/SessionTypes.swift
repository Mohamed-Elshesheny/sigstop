import Foundation

/// Why the continuous-work clock is not currently running.
public enum PauseCause: String, Sendable, Codable, Hashable {
    case microIdleExceeded   // input gap grew past the grace window
    case screenLocked
    case systemSleep
    case displaySleep
    case fastUserSwitch
    case meetingNoInput      // live call, hands off keyboard
    case breakActive
    case userPaused
}

public enum WorkClockState: Sendable, Codable, Hashable {
    case running
    case paused(cause: PauseCause, since: Date)
    case stopped
}

/// Why the *continuous* work counter went back to zero.
public enum ResetReason: String, Sendable, Codable, Hashable {
    case qualifyingBreak   // long enough away to count as a real break
    case longPause         // context is gone regardless of cause
    case sessionStart
    case dayBoundary
    case userReset
}

/// Identifies one "a break is due -> resolved" cycle, so escalation counters and
/// notification budgets can be scoped to a cycle instead of leaking across the day.
public struct CycleID: Sendable, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public func next() -> CycleID { CycleID(rawValue: rawValue + 1) }
    public static let initial = CycleID(rawValue: 0)
}

/// How a gap in input is interpreted. The whole point of the work clock is that
/// elapsed wall time and *worked* time are different numbers.
public enum GapClassification: Sendable, Hashable {
    /// Short enough that it is just reading/thinking. Clock keeps running.
    case microIdle
    /// Long enough to pause the clock, short enough that continuity survives.
    case pause(PauseCause)
    /// Long enough to count as a real break and reset continuous work.
    case qualifyingBreak
    /// So long the session itself is over.
    case sessionEnd
}

/// Where a break came from, which changes how it is reported in the daily summary.
public enum BreakOrigin: String, Sendable, Codable, Hashable {
    case accepted      // the app asked, the developer said yes
    case idleInferred  // they walked away without being asked
    case userInitiated // they hit "take a break now"
}
