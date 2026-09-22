import Foundation

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
    case aiEditor
    case editor
    case ide
    case terminal
    case browser
    case design
    case containers
    case chat
    case other

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

public enum WorkBand: String, Codable, Sendable, CaseIterable, Hashable {
    case short
    case focused
    case deep
    case marathon
    case absurd

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
    case earlyMorning
    case morning
    case afternoon
    case evening
    case night
    case lateNight

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

public enum StreakKey: String, Codable, Sendable, CaseIterable, Hashable {
    case skippedToday
    case skippedConsecutive
    case takenToday
    case snoozeSecondsToday
    case buildsWatchedInSession
    case sameCommandRepeats
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

public struct MessageContext: Sendable, Hashable {
    public var developer: DeveloperContext
    public var escalation: EscalationLevel
    public var toneCeiling: Tone
    public var streaks: [StreakKey: Int]
    public var facts: [FactKey: FactValue]
    public var slotOverrides: [SlotKey: SlotValue]
    public var calendar: Calendar
    public var locale: Locale
    public var appConfidenceOverride: Double?
    public var withheldSlots: Set<SlotKey>

    public init(
        developer: DeveloperContext,
        escalation: EscalationLevel = .first,
        toneCeiling: Tone = .sarcastic,
        streaks: [StreakKey: Int] = [:],
        facts: [FactKey: FactValue] = [:],
        slotOverrides: [SlotKey: SlotValue] = [:],
        calendar: Calendar = .current,
        locale: Locale = .current,
        appConfidence: Double? = nil,
        withheldSlots: Set<SlotKey> = []
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
        self.withheldSlots = withheldSlots
    }

    public init(
        developer: DeveloperContext,
        escalation: EscalationLevel,
        settings: SigstopSettings,
        streaks: [StreakKey: Int] = [:],
        facts: [FactKey: FactValue] = [:],
        slotOverrides: [SlotKey: SlotValue] = [:],
        calendar: Calendar = .current,
        locale: Locale = .current,
        withheldSlots: Set<SlotKey> = []
    ) {
        self.init(
            developer: developer,
            escalation: escalation,
            toneCeiling: settings.tone,
            streaks: streaks,
            facts: facts,
            slotOverrides: slotOverrides,
            calendar: calendar,
            locale: locale,
            withheldSlots: withheldSlots
        )
    }

    public var now: Date { developer.timestamp }

    public var app: AppKey { AppKey(bundleID: developer.application.bundleID) }

    public var appFamily: AppFamily { app.family }

    public var appDisplayName: String? {
        let name = developer.application.localizedName
        return name.isEmpty ? nil : name
    }

    public var appConfidence: Double {
        if let override = appConfidenceOverride { return min(max(override, 0), 1) }
        guard let bundleID = developer.application.bundleID, !bundleID.isEmpty else {
            return 0.20
        }
        return app == .unknown ? 0.50 : 0.95
    }

    public var activity: Activity { developer.claimableActivity }

    public var activityConfidence: Double { developer.confidence.value }

    public var continuousWorkMinutes: Int { developer.continuousWorkMinutes }

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
