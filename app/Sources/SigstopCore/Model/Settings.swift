import Foundation

// MARK: - Tone

/// How hard the app is allowed to hit. User-selected, never inferred.
///
/// The rails in `docs/MESSAGE-ENGINE.md` §4.2 apply at EVERY tier, including nuclear:
/// never about body weight, appearance, medical conditions, mental health, competence,
/// or job security. Nuclear is absurd and theatrical — never cruel.
public enum Tone: String, Sendable, Codable, CaseIterable, Hashable, Comparable {
    case friendly
    case sarcastic
    case roast
    case nuclear

    public var rank: Int {
        switch self {
        case .friendly: return 0
        case .sarcastic: return 1
        case .roast: return 2
        case .nuclear: return 3
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }

    public var displayName: String {
        switch self {
        case .friendly: return "Friendly"
        case .sarcastic: return "Sarcastic"
        case .roast: return "Roast"
        case .nuclear: return "Nuclear"
        }
    }

    public var blurb: String {
        switch self {
        case .friendly:  return "A colleague tapping you on the shoulder."
        case .sarcastic: return "A colleague who has watched you do this all week."
        case .roast:     return "Your code reviewer, but about your posture."
        case .nuclear:   return "Pager duty for your spine. You asked for this."
        }
    }
}

// MARK: - Escalation

/// How many times the developer has ignored the current break prompt.
public enum EscalationLevel: Int, Sendable, Codable, CaseIterable, Hashable, Comparable {
    case first = 1
    case second = 2
    case third = 3
    case incident = 4

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var next: EscalationLevel { EscalationLevel(rawValue: rawValue + 1) ?? .incident }
}

// MARK: - Quiet hours

public struct QuietHours: Sendable, Codable, Hashable {
    /// Minutes from local midnight.
    public var startMinute: Int
    public var endMinute: Int
    public var enabled: Bool

    public init(startMinute: Int = 22 * 60, endMinute: Int = 8 * 60, enabled: Bool = false) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.enabled = enabled
    }

    /// Handles windows that wrap past midnight (22:00 -> 08:00).
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return startMinute <= endMinute
            ? (m >= startMinute && m < endMinute)
            : (m >= startMinute || m < endMinute)
    }
}

// MARK: - Settings

public struct SigstopSettings: Sendable, Codable, Hashable {
    /// Continuous active work before a break is due.
    public var workIntervalMinutes: Int
    public var breakDurationMinutes: Int
    public var tone: Tone
    public var quietHours: QuietHours

    /// Idle longer than this pauses the work clock (a short read must not pause it).
    public var microIdleThresholdSeconds: Int
    /// Idle longer than this counts as a break taken without being asked.
    public var idleCountsAsBreakMinutes: Int

    /// Hard ceiling on notifications per day, across all escalation levels.
    public var maxNotificationsPerDay: Int
    public var snoozeMinutes: Int
    public var maxSnoozesPerBreak: Int

    /// Tier 1 — window titles. Off until the user grants Accessibility.
    public var accessibilityEnabled: Bool
    /// Tier 2 — read branch from `.git/HEAD`. Explicit opt-in, off by default.
    public var gitContextEnabled: Bool
    /// Record the browser HOST only. Explicit opt-in, off by default.
    public var browserHostEnabled: Bool

    public var launchAtLogin: Bool
    public var showBreakOverlay: Bool
    public var breakQuestsEnabled: Bool

    public init(
        workIntervalMinutes: Int = 45,
        breakDurationMinutes: Int = 5,
        tone: Tone = .sarcastic,
        quietHours: QuietHours = QuietHours(),
        microIdleThresholdSeconds: Int = 90,
        idleCountsAsBreakMinutes: Int = 5,
        maxNotificationsPerDay: Int = 14,
        snoozeMinutes: Int = 5,
        maxSnoozesPerBreak: Int = 2,
        accessibilityEnabled: Bool = false,
        gitContextEnabled: Bool = false,
        browserHostEnabled: Bool = false,
        launchAtLogin: Bool = false,
        showBreakOverlay: Bool = true,
        breakQuestsEnabled: Bool = true
    ) {
        self.workIntervalMinutes = workIntervalMinutes
        self.breakDurationMinutes = breakDurationMinutes
        self.tone = tone
        self.quietHours = quietHours
        self.microIdleThresholdSeconds = microIdleThresholdSeconds
        self.idleCountsAsBreakMinutes = idleCountsAsBreakMinutes
        self.maxNotificationsPerDay = maxNotificationsPerDay
        self.snoozeMinutes = snoozeMinutes
        self.maxSnoozesPerBreak = maxSnoozesPerBreak
        self.accessibilityEnabled = accessibilityEnabled
        self.gitContextEnabled = gitContextEnabled
        self.browserHostEnabled = browserHostEnabled
        self.launchAtLogin = launchAtLogin
        self.showBreakOverlay = showBreakOverlay
        self.breakQuestsEnabled = breakQuestsEnabled
    }

    public static let `default` = SigstopSettings()

    public var workInterval: TimeInterval { TimeInterval(workIntervalMinutes * 60) }
    public var breakDuration: TimeInterval { TimeInterval(breakDurationMinutes * 60) }

    /// Decoding tolerates missing keys (settings files written by older versions) and
    /// clamps hostile values, so a hand-edited file cannot put the engine in a bad state.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SigstopSettings.default
        func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }

        workIntervalMinutes = clamp(try c.decodeIfPresent(Int.self, forKey: .workIntervalMinutes) ?? d.workIntervalMinutes, 5, 240)
        breakDurationMinutes = clamp(try c.decodeIfPresent(Int.self, forKey: .breakDurationMinutes) ?? d.breakDurationMinutes, 1, 60)
        tone = try c.decodeIfPresent(Tone.self, forKey: .tone) ?? d.tone
        quietHours = try c.decodeIfPresent(QuietHours.self, forKey: .quietHours) ?? d.quietHours
        microIdleThresholdSeconds = clamp(try c.decodeIfPresent(Int.self, forKey: .microIdleThresholdSeconds) ?? d.microIdleThresholdSeconds, 15, 600)
        idleCountsAsBreakMinutes = clamp(try c.decodeIfPresent(Int.self, forKey: .idleCountsAsBreakMinutes) ?? d.idleCountsAsBreakMinutes, 1, 60)
        maxNotificationsPerDay = clamp(try c.decodeIfPresent(Int.self, forKey: .maxNotificationsPerDay) ?? d.maxNotificationsPerDay, 1, 60)
        snoozeMinutes = clamp(try c.decodeIfPresent(Int.self, forKey: .snoozeMinutes) ?? d.snoozeMinutes, 1, 60)
        maxSnoozesPerBreak = clamp(try c.decodeIfPresent(Int.self, forKey: .maxSnoozesPerBreak) ?? d.maxSnoozesPerBreak, 0, 10)
        accessibilityEnabled = try c.decodeIfPresent(Bool.self, forKey: .accessibilityEnabled) ?? d.accessibilityEnabled
        gitContextEnabled = try c.decodeIfPresent(Bool.self, forKey: .gitContextEnabled) ?? d.gitContextEnabled
        browserHostEnabled = try c.decodeIfPresent(Bool.self, forKey: .browserHostEnabled) ?? d.browserHostEnabled
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        showBreakOverlay = try c.decodeIfPresent(Bool.self, forKey: .showBreakOverlay) ?? d.showBreakOverlay
        breakQuestsEnabled = try c.decodeIfPresent(Bool.self, forKey: .breakQuestsEnabled) ?? d.breakQuestsEnabled
    }
}
