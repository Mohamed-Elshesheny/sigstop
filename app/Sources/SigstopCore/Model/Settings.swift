import Foundation

// MARK: - Tone

/// How hard the app is allowed to hit. User-selected, never inferred.
///
/// The rails in `docs/MESSAGE-ENGINE.md` §4.2 apply at EVERY tier, including nuclear:
/// never about body weight, appearance, medical conditions, mental health, competence,
/// or job security. Nuclear is absurd and theatrical, never cruel.
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

/// Which palette the app's own windows draw in.
///
/// `Brand` has had a full light and dark ramp from the start; what it did not have was a
/// way to disagree with the system. `.system` is the default and keeps the old behaviour
/// exactly, which matters because it is the behaviour every screenshot was taken in.
///
/// This is deliberately about *the app's windows*. The menu bar mark is not one of them:
/// it is drawn into the system menu bar and has to match that bar, not this preference,
/// or choosing Light on a dark Mac paints a dark-ink mark onto a dark strip.
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

    /// Tier 1, window titles. Off until the user grants Accessibility.
    public var accessibilityEnabled: Bool
    /// Tier 2, read branch from `.git/HEAD`. Explicit opt-in, off by default.
    public var gitContextEnabled: Bool
    /// Absolute paths of the project folders the user added themselves.
    ///
    /// The whole of what the git collector may open. It is a list and not a search root
    /// because the open panel the user picks a folder in is also the grant: a repository
    /// under `~/Desktop`, `~/Documents` or `~/Downloads` is behind the Files-and-Folders
    /// TCC service, and a path discovered from a window title carries no such grant.
    public var projectFolders: [String]
    /// Tier 2, look for a known debugger in the process table. Its OWN opt-in.
    ///
    /// Two switches, not one, because they read different things and the copy on each has
    /// to be true. Somebody who agreed to have a branch name read has not agreed to have
    /// the process table enumerated, and docs/ACTIVITY-DETECTION.md §4.3 has said "two
    /// independent opt-ins, each with its own switch" since before either existed.
    public var processContextEnabled: Bool
    /// Record the browser HOST only. Explicit opt-in, off by default.
    public var browserHostEnabled: Bool

    /// Show a Dock icon. Menu bar utilities conventionally have none, which is why the
    /// app is LSUIElement, but the activation policy is changeable at runtime and some
    /// people want the app where they look for apps.
    /// Deliver prompts through macOS notifications instead of the app's own panel.
    ///
    /// Off by default, and the reason matters. A notification is only reliably shown when
    /// the app has a stable signing identity. An ad-hoc or unsigned build, which is every
    /// development build and every unsigned download, gets `authorizationStatus ==
    /// .authorized` and a successful `add()` and is still never drawn on screen. The app
    /// then records a prompt nobody saw as ignored, backs off, and goes quiet. A break
    /// reminder that fails silently is worse than no break reminder.
    /// Play a sound with the prompt, from escalation two onward.
    ///
    /// The first prompt is silent on purpose. A sound on every reminder is how a break
    /// reminder becomes something people mute, and a sound that only arrives when you
    /// have already ignored one still carries information.
    public var promptSound: Bool
    public var useSystemNotifications: Bool
    public var appearance: AppearancePreference
    public var showInDock: Bool
    public var launchAtLogin: Bool
    public var showBreakOverlay: Bool
    public var breakQuestsEnabled: Bool
    /// Hold a due break back for a bounded time after a microphone or camera stops.
    ///
    /// Off disables the call latch and NOTHING else: a microphone or camera that is
    /// actually running still hard-blocks, because that is a fact and it predates this
    /// switch. Turning off a new mechanism must not turn off an old one.
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
        processContextEnabled = try c.decodeIfPresent(Bool.self, forKey: .processContextEnabled) ?? d.processContextEnabled
        /// Capped rather than trusted, like every other decoded value here: a hand-edited
        /// file must not be able to hand the collector an unbounded list of paths to stat.
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
