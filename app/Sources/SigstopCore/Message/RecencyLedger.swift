import Foundation

// MARK: - Policy

/// The repetition rules. Repetition is the failure mode that gets the app uninstalled, so
/// these are hard gates rather than preferences. See docs/MESSAGE-ENGINE.md §3.1.
public enum Policy {
    /// A line rests three days.
    public static let templateCooldownHours = 72
    /// Don't do two Docker jokes in a row.
    public static let categoryCooldownMinutes = 45
    /// The last N shown ids are excluded outright.
    public static let lruWindow = 60
    public static let relaxedLRUWindow = 20
    /// Scarcity is what makes NUCLEAR land.
    public static let nuclearPerDay = 1
    public static let nuclearCooldownHours = 6
    /// Avoid three identical tones in a row — deprioritized, not blocked.
    public static let toneRepeatWindow = 3
    public static let toneRepeatWeightMultiplier = 0.4
    /// At the `allowSameDay` stage a same-day repeat needs at least this much distance.
    public static let sameDayRepeatMinimumHours = 6.0
    public static let ledgerRetentionDays = 30
}

/// Selection never returns nothing. When the recency rules empty the candidate set, the
/// engine re-runs them one stage looser and records the stage in the trace. A user who
/// reaches stage 3 regularly has packs too small for their usage, which is a thing the app
/// can say out loud rather than silently repeat itself.
public enum RelaxationStage: Int, Sendable, Codable, Hashable, CaseIterable, Comparable {
    case strict = 0        // all rules
    case dropCategory = 1  // drop the 45-minute category cooldown
    case shrinkLRU = 2     // LRU window 60 -> 20
    case dropCooldown = 3  // drop the 72h template cooldown; same-day rule still absolute
    case allowSameDay = 4  // allow a same-day repeat, but only after 6h
    case emergency = 5     // compiled-in fallback pool, tone forced to .friendly

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var lruWindow: Int {
        self >= .shrinkLRU ? Policy.relaxedLRUWindow : Policy.lruWindow
    }
    public var enforcesCategoryCooldown: Bool { self < .dropCategory }
    public var enforcesTemplateCooldown: Bool { self < .dropCooldown }
    public var enforcesSameDayUniqueness: Bool { self < .allowSameDay }
}

// MARK: - Entries

public struct LedgerEntry: Sendable, Codable, Hashable {
    public let templateID: String
    public let category: String
    public let tone: Tone
    public let shownAt: Date

    public init(templateID: String, category: String, tone: Tone, shownAt: Date) {
        self.templateID = templateID
        self.category = category
        self.tone = tone
        self.shownAt = shownAt
    }
}

// MARK: - Ledger

/// What has been shown, and when.
///
/// A reference type on purpose: the engine and the persistence layer hold the same ledger,
/// and "what did we already say" is genuine shared identity rather than a value. Core does
/// no I/O, so persistence is somebody else's job — `snapshot` / `init(entries:)` is the
/// whole interface they need.
public final class RecencyLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [LedgerEntry]   // append order, oldest first

    public init(entries: [LedgerEntry] = []) {
        self.entries = entries.sorted { $0.shownAt < $1.shownAt }
    }

    /// For the persistence layer. Ordered oldest first.
    public var snapshot: [LedgerEntry] {
        lock.withLock { entries }
    }

    public var count: Int { lock.withLock { entries.count } }

    public func record(templateID: String, category: String, tone: Tone, at date: Date) {
        lock.withLock {
            entries.append(LedgerEntry(
                templateID: templateID, category: category, tone: tone, shownAt: date))
        }
    }

    public func record(_ template: MessageTemplate, at date: Date) {
        record(templateID: template.id, category: template.category, tone: template.tone, at: date)
    }

    public func lastShown(templateID: String) -> Date? {
        lock.withLock { entries.last { $0.templateID == templateID }?.shownAt }
    }

    public func lastShown(category: String) -> Date? {
        lock.withLock { entries.last { $0.category == category }?.shownAt }
    }

    public func lastShown(tone: Tone) -> Date? {
        lock.withLock { entries.last { $0.tone == tone }?.shownAt }
    }

    public func showCount(templateID: String, since: Date) -> Int {
        lock.withLock { entries.filter { $0.templateID == templateID && $0.shownAt >= since }.count }
    }

    public func shownToday(templateID: String, calendar: Calendar, now: Date) -> Bool {
        lastShownToday(templateID: templateID, calendar: calendar, now: now) != nil
    }

    /// The most recent show of this template that falls on `now`'s calendar day.
    public func lastShownToday(templateID: String, calendar: Calendar, now: Date) -> Date? {
        lock.withLock {
            entries.last {
                $0.templateID == templateID && calendar.isDate($0.shownAt, inSameDayAs: now)
            }?.shownAt
        }
    }

    /// Most-recent-first.
    public func recentTemplateIDs(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        return lock.withLock { entries.suffix(limit).reversed().map(\.templateID) }
    }

    /// Most-recent-first.
    public func recentTones(limit: Int) -> [Tone] {
        guard limit > 0 else { return [] }
        return lock.withLock { entries.suffix(limit).reversed().map(\.tone) }
    }

    public func countOnDay(tone: Tone, calendar: Calendar, now: Date) -> Int {
        lock.withLock {
            entries.filter { $0.tone == tone && calendar.isDate($0.shownAt, inSameDayAs: now) }.count
        }
    }

    /// Retention. Core never schedules this; the app calls it.
    public func purge(before cutoff: Date) {
        lock.withLock { entries.removeAll { $0.shownAt < cutoff } }
    }

    public func reset() {
        lock.withLock { entries.removeAll() }
    }

    // MARK: Rules

    /// True when this template may be shown at this relaxation stage.
    public func allows(
        _ t: MessageTemplate, at stage: RelaxationStage, now: Date, calendar: Calendar
    ) -> Bool {
        if recentTemplateIDs(limit: stage.lruWindow).contains(t.id) { return false }

        if let today = lastShownToday(templateID: t.id, calendar: calendar, now: now) {
            if stage.enforcesSameDayUniqueness { return false }
            if now.timeIntervalSince(today) < Policy.sameDayRepeatMinimumHours * 3600 {
                return false
            }
        }

        if stage.enforcesTemplateCooldown, let last = lastShown(templateID: t.id) {
            let hours = Double(t.cooldownHours ?? Policy.templateCooldownHours)
            if now.timeIntervalSince(last) < hours * 3600 { return false }
        }

        if stage.enforcesCategoryCooldown, let last = lastShown(category: t.category) {
            if now.timeIntervalSince(last) < Double(Policy.categoryCooldownMinutes) * 60 {
                return false
            }
        }

        if t.tone == .nuclear {
            if countOnDay(tone: .nuclear, calendar: calendar, now: now) >= Policy.nuclearPerDay {
                return false
            }
            if let last = lastShown(tone: .nuclear),
               now.timeIntervalSince(last) < Double(Policy.nuclearCooldownHours) * 3600 {
                return false
            }
        }

        return true
    }

    /// Freshness in `0.05...1`. A never-shown template scores 1 and therefore dominates
    /// naturally, which is why a newly installed pack surfaces without a special case.
    public func freshness(_ t: MessageTemplate, now: Date) -> Double {
        guard let last = lastShown(templateID: t.id) else { return 1.0 }
        let hours = now.timeIntervalSince(last) / 3600
        let recovery = Double(t.cooldownHours ?? Policy.templateCooldownHours)
        guard recovery > 0 else { return 1.0 }
        return min(1.0, max(0.05, hours / recovery))
    }

    /// True when the last `Policy.toneRepeatWindow` shows were all this tone.
    public func toneIsOverused(_ tone: Tone) -> Bool {
        let recent = recentTones(limit: Policy.toneRepeatWindow)
        guard recent.count == Policy.toneRepeatWindow else { return false }
        return recent.allSatisfy { $0 == tone }
    }
}
