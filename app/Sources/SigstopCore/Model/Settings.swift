import Foundation

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

public enum AppearancePreference: String, Sendable, Codable, CaseIterable, Hashable {
    case system
    case light
    case dark

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}

public enum EscalationLevel: Int, Sendable, Codable, CaseIterable, Hashable, Comparable {
    case first = 1
    case second = 2
    case third = 3
    case incident = 4

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var next: EscalationLevel { EscalationLevel(rawValue: rawValue + 1) ?? .incident }
}

public struct QuietHours: Sendable, Codable, Hashable {
    public var startMinute: Int
    public var endMinute: Int
    public var enabled: Bool

    public init(startMinute: Int = 22 * 60, endMinute: Int = 8 * 60, enabled: Bool = false) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.enabled = enabled
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return startMinute <= endMinute
            ? (m >= startMinute && m < endMinute)
            : (m >= startMinute || m < endMinute)
    }
}

public struct SigstopSettings: Sendable, Codable, Hashable {
    public var workIntervalMinutes: Int
    public var breakDurationMinutes: Int
    public var tone: Tone
    public var quietHours: QuietHours

    public var microIdleThresholdSeconds: Int
    public var idleCountsAsBreakMinutes: Int

    public var maxNotificationsPerDay: Int
    public var snoozeMinutes: Int
    public var maxSnoozesPerBreak: Int

    public var accessibilityEnabled: Bool
    public var gitContextEnabled: Bool
    public var projectFolders: [String]
    public var processContextEnabled: Bool
    public var browserHostEnabled: Bool

    public var promptSound: Bool
    public var useSystemNotifications: Bool
    public var appearance: AppearancePreference
    public var showInDock: Bool
    public var launchAtLogin: Bool
    public var showBreakOverlay: Bool
    public var breakQuestsEnabled: Bool
    public var holdBreaksDuringCalls: Bool

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
        projectFolders: [String] = [],
        processContextEnabled: Bool = false,
        browserHostEnabled: Bool = false,
        promptSound: Bool = true,
        useSystemNotifications: Bool = false,
        appearance: AppearancePreference = .system,
        showInDock: Bool = true,
        launchAtLogin: Bool = false,
        showBreakOverlay: Bool = true,
        breakQuestsEnabled: Bool = true,
        holdBreaksDuringCalls: Bool = true
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
        self.projectFolders = projectFolders
        self.processContextEnabled = processContextEnabled
        self.browserHostEnabled = browserHostEnabled
        self.promptSound = promptSound
        self.useSystemNotifications = useSystemNotifications
        self.appearance = appearance
        self.showInDock = showInDock
        self.launchAtLogin = launchAtLogin
        self.showBreakOverlay = showBreakOverlay
        self.breakQuestsEnabled = breakQuestsEnabled
        self.holdBreaksDuringCalls = holdBreaksDuringCalls
    }

    public static let `default` = SigstopSettings()

    public var workInterval: TimeInterval { TimeInterval(workIntervalMinutes * 60) }
    public var breakDuration: TimeInterval { TimeInterval(breakDurationMinutes * 60) }

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
        processContextEnabled = try c.decodeIfPresent(Bool.self, forKey: .processContextEnabled) ?? d.processContextEnabled
        projectFolders = Array(
            (try c.decodeIfPresent([String].self, forKey: .projectFolders) ?? d.projectFolders)
                .filter { $0.hasPrefix("/") }
                .prefix(32)
        )
        browserHostEnabled = try c.decodeIfPresent(Bool.self, forKey: .browserHostEnabled) ?? d.browserHostEnabled
        promptSound = try c.decodeIfPresent(Bool.self, forKey: .promptSound) ?? d.promptSound
        useSystemNotifications = try c.decodeIfPresent(Bool.self, forKey: .useSystemNotifications) ?? d.useSystemNotifications
        appearance = try c.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? d.appearance
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? d.showInDock
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        showBreakOverlay = try c.decodeIfPresent(Bool.self, forKey: .showBreakOverlay) ?? d.showBreakOverlay
        breakQuestsEnabled = try c.decodeIfPresent(Bool.self, forKey: .breakQuestsEnabled) ?? d.breakQuestsEnabled
        holdBreaksDuringCalls = try c.decodeIfPresent(Bool.self, forKey: .holdBreaksDuringCalls) ?? d.holdBreaksDuringCalls
    }
}
