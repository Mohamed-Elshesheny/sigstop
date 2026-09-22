import Foundation

public enum Policy {
    public static let templateCooldownHours = 72
    public static let categoryCooldownMinutes = 45
    public static let lruWindow = 60
    public static let relaxedLRUWindow = 20
    public static let nuclearPerDay = 1
    public static let nuclearCooldownHours = 6
    public static let toneRepeatWindow = 3
    public static let toneRepeatWeightMultiplier = 0.4
    public static let sameDayRepeatMinimumHours = 6.0
    public static let ledgerRetentionDays = 30
}

public enum RelaxationStage: Int, Sendable, Codable, Hashable, CaseIterable, Comparable {
    case strict = 0
    case dropCategory = 1
    case shrinkLRU = 2
    case dropCooldown = 3
    case allowSameDay = 4
    case emergency = 5

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var lruWindow: Int {
        self >= .shrinkLRU ? Policy.relaxedLRUWindow : Policy.lruWindow
    }
    public var enforcesCategoryCooldown: Bool { self < .dropCategory }
    public var enforcesTemplateCooldown: Bool { self < .dropCooldown }
    public var enforcesSameDayUniqueness: Bool { self < .allowSameDay }
}

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

public final class RecencyLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [LedgerEntry]

    public init(entries: [LedgerEntry] = []) {
        self.entries = entries.sorted { $0.shownAt < $1.shownAt }
    }

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

    public func lastShownToday(templateID: String, calendar: Calendar, now: Date) -> Date? {
        lock.withLock {
            entries.last {
                $0.templateID == templateID && calendar.isDate($0.shownAt, inSameDayAs: now)
            }?.shownAt
        }
    }

    public func recentTemplateIDs(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        return lock.withLock { entries.suffix(limit).reversed().map(\.templateID) }
    }

    public func recentTones(limit: Int) -> [Tone] {
        guard limit > 0 else { return [] }
        return lock.withLock { entries.suffix(limit).reversed().map(\.tone) }
    }

    public func countOnDay(tone: Tone, calendar: Calendar, now: Date) -> Int {
        lock.withLock {
            entries.filter { $0.tone == tone && calendar.isDate($0.shownAt, inSameDayAs: now) }.count
        }
    }

    public func purge(before cutoff: Date) {
        lock.withLock { entries.removeAll { $0.shownAt < cutoff } }
    }

    public func reset() {
        lock.withLock { entries.removeAll() }
    }

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

    public func freshness(_ t: MessageTemplate, now: Date) -> Double {
        guard let last = lastShown(templateID: t.id) else { return 1.0 }
        let hours = now.timeIntervalSince(last) / 3600
        let recovery = Double(t.cooldownHours ?? Policy.templateCooldownHours)
        guard recovery > 0 else { return 1.0 }
        return min(1.0, max(0.05, hours / recovery))
    }

    public func toneIsOverused(_ tone: Tone) -> Bool {
        let recent = recentTones(limit: Policy.toneRepeatWindow)
        guard recent.count == Policy.toneRepeatWindow else { return false }
        return recent.allSatisfy { $0 == tone }
    }
}
