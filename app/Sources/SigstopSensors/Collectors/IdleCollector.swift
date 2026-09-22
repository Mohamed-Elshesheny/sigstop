import CoreGraphics
import Foundation
import IOKit

public struct IdleCollector: Sendable {
    public init() {}

    public static let thresholds: [TimeInterval] = [90, 120, 300]

    public func read() -> InputActivity {
        if let any = CGEventType(rawValue: ~0) {
            let seconds = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
            if seconds.isFinite, seconds >= 0 {
                return InputActivity(idleSeconds: seconds, source: .hidSystemState)
            }
        }
        if let seconds = Self.hidIdleSecondsFromIORegistry() {
            return InputActivity(idleSeconds: seconds, source: .ioRegistry)
        }
        return .unknown
    }

    public static func secondsUntilNextThreshold(
        idleSeconds: TimeInterval,
        thresholds: [TimeInterval] = IdleCollector.thresholds,
        maximum: TimeInterval = 300
    ) -> TimeInterval {
        guard let next = thresholds.sorted().first(where: { $0 > idleSeconds }) else {
            return maximum
        }
        return max(1.0, next - idleSeconds)
    }

    static func hidIdleSecondsFromIORegistry() -> TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(
            service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }

        guard let number = property as? NSNumber else { return nil }
        let nanoseconds = number.doubleValue
        guard nanoseconds.isFinite, nanoseconds >= 0 else { return nil }
        return nanoseconds / 1_000_000_000.0
    }
}
