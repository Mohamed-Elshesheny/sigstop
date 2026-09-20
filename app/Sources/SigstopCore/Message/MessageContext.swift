import Foundation

// MARK: - Why this file exists

// MARK: - Application vocabulary

/// The applications the corpus is allowed to name out loud.
///
/// Resolved from the bundle identifier, which is a Tier 0 OS fact, no permission, no
/// prompt, no inference. That is why `appConfidence` may legitimately be high while
/// `activityConfidence` is not.
public enum AppKey: String, Codable, Sendable, CaseIterable, Hashable {
    case cursor, vscode, zed, xcode, jetbrains, terminal, browser
    case figma, docker, slack, discord, unknown

    public init(bundleID: String?) {
        guard let raw = bundleID?.lowercased(), !raw.isEmpty else {
            self = .unknown
            return
        }

        if raw.contains("cursor") || raw == "com.todesktop.230313mzl4w4u92" {
            self = .cursor
        } else if raw.hasPrefix("com.microsoft.vscode")
                    || raw == "com.visualstudio.code.oss"
                    || raw.hasPrefix("com.vscodium") {
            self = .vscode
        } else if raw.hasPrefix("dev.zed.") {
            self = .zed
        } else if raw == "com.apple.dt.xcode" {
            self = .xcode
        } else if raw.hasPrefix("com.jetbrains.")
                    || raw.hasPrefix("com.google.android.studio") {
            self = .jetbrains
        } else if Self.terminalIDs.contains(raw) {
            self = .terminal
        } else if Self.browserIDs.contains(raw) {
            self = .browser
        } else if raw.hasPrefix("com.figma.") {
            self = .figma
        } else if raw.hasPrefix("com.docker.") || raw == "com.electron.dockerdesktop" {
            self = .docker
        } else if raw == "com.tinyspeck.slackmacgap" {
            self = .slack
        } else if raw.hasPrefix("com.hnc.discord") {
            self = .discord
        } else {
            self = .unknown
        }
    }

    private static let terminalIDs: Set<String> = [
        "com.apple.terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "io.alacritty", "org.alacritty",
        "dev.warp.warp-stable", "com.mitchellh.ghostty", "co.zeit.hyper",
    ]

    private static let browserIDs: Set<String> = [
        "com.apple.safari", "com.apple.safaritechnologypreview", "com.google.chrome",
        "com.google.chrome.canary", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "company.thebrowser.browser", "com.microsoft.edgemac", "com.brave.browser",
        "com.operasoftware.opera", "com.vivaldi.vivaldi", "app.zen-browser.zen",
    ]

    public var family: AppFamily {
        switch self {
        case .cursor:           return .aiEditor
        case .vscode, .zed:     return .editor
        case .xcode, .jetbrains: return .ide
        case .terminal:         return .terminal
        case .browser:          return .browser
        case .figma:            return .design
        case .docker:           return .containers
        case .slack, .discord:  return .chat
        case .unknown:          return .other
        }
    }
}

public enum AppFamily: String, Codable, Sendable, CaseIterable, Hashable {
    case aiEditor      // completion-forward editors
    case editor        // vscode, zed, sublime
    case ide           // xcode, jetbrains
    case terminal
    case browser
    case design
    case containers
    case chat
    case other

    /// The family-level substitute for `{app}` when the exact name is not available.
    /// Never wrong, which is the whole point, see docs/MESSAGE-ENGINE.md §2.3.
    public var degradedAppName: String {
        switch self {
        case .aiEditor, .editor, .ide: return "your editor"
        case .terminal:                return "your terminal"
        case .browser:                 return "your browser"
        case .design:                  return "your design tool"
        case .containers:              return "your containers"
        case .chat:                    return "your chat app"
        case .other:                   return "that"
        }
    }
}

// MARK: - Bands

public enum WorkBand: String, Codable, Sendable, CaseIterable, Hashable {
    case short      // < 25
    case focused    // 25 ..< 50
    case deep       // 50 ..< 90
    case marathon   // 90 ..< 150
    case absurd     // >= 150

    public init(minutes: Int) {
        switch minutes {
        case ..<25:  self = .short
        case ..<50:  self = .focused
        case ..<90:  self = .deep
        case ..<150: self = .marathon
        default:     self = .absurd
        }
    }
}

public enum TimeBand: String, Codable, Sendable, CaseIterable, Hashable {
    case earlyMorning   // 05:00 ..< 08:00
    case morning        // 08:00 ..< 12:00
    case afternoon      // 12:00 ..< 17:00
    case evening        // 17:00 ..< 21:00
    case night          // 21:00 ..< 01:00
    case lateNight      // 01:00 ..< 05:00

    public init(hour: Int) {
        switch hour {
        case 5..<8:      self = .earlyMorning
        case 8..<12:     self = .morning
        case 12..<17:    self = .afternoon
        case 17..<21:    self = .evening
        case 21..<24, 0: self = .night
        default:         self = .lateNight
        }
    }
}

public enum Weekday: String, Codable, Sendable, CaseIterable, Hashable {
    case mon, tue, wed, thu, fri, sat, sun

    /// `Calendar` numbers weekdays 1 = Sunday ... 7 = Saturday.
    public init(calendarWeekday: Int) {
        switch calendarWeekday {
        case 1:  self = .sun
        case 2:  self = .mon
        case 3:  self = .tue
        case 4:  self = .wed
        case 5:  self = .thu
        case 6:  self = .fri
        default: self = .sat
        }
    }
}

// MARK: - Counters and facts

/// Counters the collectors maintain across the day or the session.
public enum StreakKey: String, Codable, Sendable, CaseIterable, Hashable {
    case skippedToday          // breaks dismissed or snoozed today
    case skippedConsecutive    // dismissed in a row, resets on a taken break
    case takenToday
    case snoozeSecondsToday
    case buildsWatchedInSession
    case sameCommandRepeats    // terminal: identical command re-run count
}

public enum FactKey: String, Codable, Sendable, CaseIterable, Hashable {
    case branchIsDefault
    case branchIsLongLived
    case hasUncommittedChanges
    case ciPending
    case prOpenInForeground
    case testsFailing
    case buildRunning
    case windowCount
    case editorTabCount
}

public enum FactValue: Sendable, Hashable, Codable {
    case bool(Bool)
    case int(Int)
    case string(String)
}

public enum FactMatch: Sendable, Hashable, Codable {
    case isTrue
    case isFalse
    case intAtLeast(Int)
    case equalsString(String)
}

// MARK: - The selection context

/// Everything the engine may read at selection time. Nothing else is consulted, which is
/// what makes `select` a pure function of this value plus the ledger and the RNG.
public struct MessageContext: Sendable, Hashable {
    /// The contract value produced by the context engine. Untouched.
    public var developer: DeveloperContext
    public var escalation: EscalationLevel
    /// User preference. A hard ceiling, never a floor.
    public var toneCeiling: Tone
    public var streaks: [StreakKey: Int]
    public var facts: [FactKey: FactValue]
    /// Values only a collector can know (`{count}`), or a test wants to pin.
    public var slotOverrides: [SlotKey: SlotValue]
    public var calendar: Calendar
    public var locale: Locale
    /// Override for how sure we are *which app is in front*. Normally derived from the
    /// bundle identifier, which is an OS fact rather than an inference.
    public var appConfidenceOverride: Double?

    public init(
        developer: DeveloperContext,
        escalation: EscalationLevel = .first,
        toneCeiling: Tone = .sarcastic,
        streaks: [StreakKey: Int] = [:],
        facts: [FactKey: FactValue] = [:],
        slotOverrides: [SlotKey: SlotValue] = [:],
        calendar: Calendar = .current,
        locale: Locale = .current,
        appConfidence: Double? = nil
    ) {
        self.developer = developer
        self.escalation = escalation
        self.toneCeiling = toneCeiling
        self.streaks = streaks
        self.facts = facts
        self.slotOverrides = slotOverrides
        self.calendar = calendar
        self.locale = locale
        self.appConfidenceOverride = appConfidence
    }

    /// Convenience: the tone ceiling is a setting, so read it from the settings.
    public init(
        developer: DeveloperContext,
        escalation: EscalationLevel,
        settings: SigstopSettings,
        streaks: [StreakKey: Int] = [:],
        facts: [FactKey: FactValue] = [:],
        slotOverrides: [SlotKey: SlotValue] = [:],
        calendar: Calendar = .current,
        locale: Locale = .current
    ) {
        self.init(
            developer: developer,
            escalation: escalation,
            toneCeiling: settings.tone,
            streaks: streaks,
            facts: facts,
            slotOverrides: slotOverrides,
            calendar: calendar,
            locale: locale
        )
    }

    // MARK: Derived

    public var now: Date { developer.timestamp }

    public var app: AppKey { AppKey(bundleID: developer.application.bundleID) }

    public var appFamily: AppFamily { app.family }

    /// The name we are willing to print. `AppIdentity.localizedName` comes from the OS.
    public var appDisplayName: String? {
        let name = developer.application.localizedName
        return name.isEmpty ? nil : name
    }

    /// How sure we are *which app is frontmost*, not what is happening inside it.
    public var appConfidence: Double {
        if let override = appConfidenceOverride { return min(max(override, 0), 1) }
        guard let bundleID = developer.application.bundleID, !bundleID.isEmpty else {
            return 0.20
        }
        return app == .unknown ? 0.50 : 0.95
    }

    /// The activity the app is *allowed to name*. Already degraded to the parent class
    /// below the specific-claim threshold by the contract type. See CLAUDE.md §4.1.
    public var activity: Activity { developer.claimableActivity }

    public var activityConfidence: Double { developer.confidence.value }

    public var continuousWorkMinutes: Int { developer.continuousWorkMinutes }

    /// Falls back to continuous work when no break has ever been recorded: a session with
    /// no break yet is not a session with a *recent* break.
    public var minutesSinceLastBreak: Int {
        Int((developer.timeSinceLastBreak ?? developer.continuousWork) / 60)
    }

    public var workBand: WorkBand { WorkBand(minutes: continuousWorkMinutes) }

    public var timeBand: TimeBand {
        TimeBand(hour: calendar.component(.hour, from: now))
    }

    public var weekday: Weekday {
        Weekday(calendarWeekday: calendar.component(.weekday, from: now))
    }

    public func streak(_ key: StreakKey) -> Int { streaks[key] ?? 0 }
}
