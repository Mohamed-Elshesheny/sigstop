import Foundation

public enum DurationText {
    public static func short(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int((seconds / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    public static func long(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int((seconds / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if hours == 0 { return plural(minutes, "minute") }
        if minutes == 0 { return plural(hours, "hour") }
        return "\(plural(hours, "hour")) \(plural(minutes, "minute"))"
    }
}

public struct SummaryNarrator: Sendable {
    private let appName: @Sendable (String) -> String

    public init(appName: @escaping @Sendable (String) -> String = SummaryNarrator.defaultAppName) {
        self.appName = appName
    }

    public static let defaultAppName: @Sendable (String) -> String = { bundleID in
        if bundleID == DailyRollup.unattributedApplication { return "an unidentified app" }
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last.isEmpty ? bundleID : last
    }

    public func detail(for summary: DailySummary) -> String {
        var parts: [String] = []
        parts.append("Active work \(DurationText.short(summary.totalActiveWork))")
        if summary.longestContinuousSession > 0 {
            parts.append("longest stretch \(DurationText.short(summary.longestContinuousSession))")
        }
        parts.append("\(summary.breakCount) break\(summary.breakCount == 1 ? "" : "s")")
        parts.append("break compliance \(summary.complianceDescription)")
        if let top = summary.topApplication {
            parts.append("\(appName(top.bundleID)) \(DurationText.short(top.seconds))")
        }
        if summary.malformedLines > 0 {
            parts.append("\(summary.malformedLines) unreadable log line(s) skipped")
        }
        return parts.joined(separator: " · ")
    }
}
