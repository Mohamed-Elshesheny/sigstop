import CoreGraphics
import Foundation
import IOKit
import SigstopCore

/// Tier 0. Seconds since the last **human** HID event.
///
/// No permission and no prompt: this reports *when* input last happened, never *what*
/// was typed. Input Monitoring — the grant that would let us count keystrokes — is
/// declined on principle (docs/ACTIVITY-DETECTION.md §12.1).
///
/// Two traps this type exists to avoid:
///
/// 1. **`CGEventType(rawValue: ~0)!`** is the widely-copied "any event type" constant.
///    `CGEventType` imports as a Swift enum whose `init?(rawValue:)` returns nil for
///    values it does not recognise, so the force-unwrap is a latent crash if the import
///    ever changes. We test it and fall back to IOKit.
/// 2. **`.combinedSessionState` counts synthetic events** posted by other processes, so
///    mouse jigglers, automation tools and some conferencing apps make the user look
///    permanently active. `.hidSystemState` stays closer to real human input, which is
///    the whole point of the number.
public struct IdleCollector: Sendable {
    public init() {}

    /// Idle thresholds the engine cares about, ascending. Used to schedule exactly one
    /// timer per idle episode instead of polling.
    ///
    /// * 90 s  — `SigstopSettings.microIdleThresholdSeconds` default: the work clock pauses.
    /// * 120 s — below this a gap is reading/thinking; above it, confidence decays (§7.11).
    /// * 300 s — `IDLE` at 0.90, and the sampling subsystem suspends itself (§8.4).
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
        // Honest absence. Consumers must not read this as "the user is right here".
        return .unknown
    }

    /// Seconds until the user next crosses an idle threshold, given the current idle
    /// reading. Pure, so the scheduling rule is unit-testable without a clock.
    ///
    /// Steady-state cost of scheduling a single timer for this delay is ~2 wakeups per
    /// idle episode, versus 3,600/hour for the naive 1 Hz poll.
    public static func secondsUntilNextThreshold(
        idleSeconds: TimeInterval,
        thresholds: [TimeInterval] = IdleCollector.thresholds,
        maximum: TimeInterval = 300
    ) -> TimeInterval {
        guard let next = thresholds.sorted().first(where: { $0 > idleSeconds }) else {
            // Past every threshold: nothing further to learn until input resumes, and
            // input resumption arrives as an event, not a tick.
            return maximum
        }
        return max(1.0, next - idleSeconds)
    }

    // MARK: - IOKit fallback

    /// `IOHIDSystem` → `HIDIdleTime`, in nanoseconds. Works when the CoreGraphics path
    /// is unavailable (no window server connection, or a future import change).
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
