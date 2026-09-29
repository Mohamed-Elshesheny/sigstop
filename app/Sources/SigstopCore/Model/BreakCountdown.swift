import Foundation

public enum BreakCountdown {

    public enum Unit: String, Sendable, Hashable {
        case minutes = "min"
        case seconds = "s"
    }

    public struct Reading: Sendable, Hashable {
        public let value: Int
        public let unit: Unit

        public var text: String { "\(value) \(unit.rawValue)" }
    }

    public static let finalMinute: TimeInterval = 60

    public static func reading(remaining: TimeInterval) -> Reading {
        let seconds = max(0, Int(remaining.rounded()))
        if TimeInterval(seconds) > finalMinute {
            return Reading(value: (seconds + 59) / 60, unit: .minutes)
        }
        return Reading(value: seconds, unit: .seconds)
    }

    public static func length(_ total: TimeInterval) -> Reading {
        let seconds = max(0, Int(total.rounded()))
        if seconds >= 60 {
            return Reading(value: (seconds + 30) / 60, unit: .minutes)
        }
        return Reading(value: seconds, unit: .seconds)
    }

    public static func redraws(from now: Date, until end: Date) -> [Date] {
        let remaining = end.timeIntervalSince(now)
        guard remaining > 0 else { return [] }
        var points: [TimeInterval] = []
        var minute = finalMinute * 2
        while minute < remaining {
            points.append(minute)
            minute += 60
        }
        var second = min(finalMinute, remaining.rounded(.up) - 1)
        while second >= 0 {
            points.append(second)
            second -= 1
        }
        return points.sorted(by: >).map { end.addingTimeInterval(-$0) }
    }
}
