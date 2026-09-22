import Foundation

public enum SlotKey: String, Codable, Sendable, CaseIterable, Hashable {
    case app
    case minutes
    case project
    case branch
    case activity
    case streak
    case count
    case hour

    public var canDegrade: Bool {
        switch self {
        case .branch, .streak, .minutes, .count, .hour: return false
        case .app, .project, .activity:                 return true
        }
    }
}

public struct SlotValue: Sendable, Hashable, Codable {
    public let text: String
    public let confidence: Double
    public let provenance: Provenance

    public enum Provenance: String, Sendable, Codable, Hashable {
        case exact
        case derived
        case degraded
        case generic
    }

    public init(text: String, confidence: Double, provenance: Provenance) {
        self.text = text
        self.confidence = min(max(confidence, 0), 1)
        self.provenance = provenance
    }

    public var isHardEnoughForRequiredSlot: Bool {
        provenance == .exact || provenance == .derived
    }
}

public struct SlotResolver: Sendable {
    public static let requiredFloor: Double = 0.70
    public static let optionalFloor: Double = 0.50

    public init() {}

    public func table(for ctx: MessageContext) -> [SlotKey: SlotValue] {
        var out: [SlotKey: SlotValue] = [:]

        out[.minutes] = SlotValue(
            text: format(integer: ctx.continuousWorkMinutes),
            confidence: 0.99, provenance: .derived)

        out[.hour] = SlotValue(
            text: format(time: ctx.now, timeZone: ctx.calendar.timeZone),
            confidence: 0.99, provenance: .derived)

        if let name = ctx.appDisplayName {
            out[.app] = SlotValue(text: name, confidence: ctx.appConfidence, provenance: .exact)
        }

        if let project = ctx.developer.context.projectName, !project.isEmpty {
            out[.project] = SlotValue(text: project, confidence: 0.75, provenance: .exact)
        }

        if let branch = ctx.developer.context.branch, !branch.isEmpty {
            out[.branch] = SlotValue(text: branch, confidence: 0.95, provenance: .exact)
        }

        out[.activity] = SlotValue(
            text: ctx.activity.displayName,
            confidence: ctx.activityConfidence, provenance: .exact)

        if let skipped = ctx.streaks[.skippedConsecutive] ?? ctx.streaks[.skippedToday] {
            out[.streak] = SlotValue(
                text: format(integer: skipped),
                confidence: 0.99, provenance: .exact)
        }

        for (k, v) in ctx.slotOverrides { out[k] = v }
        for key in ctx.withheldSlots { out.removeValue(forKey: key) }
        return out
    }

    public func canSatisfyRequired(_ t: MessageTemplate, in ctx: MessageContext) -> Bool {
        canSatisfyRequired(t, table: table(for: ctx))
    }

    public func canSatisfyRequired(_ t: MessageTemplate, table: [SlotKey: SlotValue]) -> Bool {
        t.requiredSlots.allSatisfy { key in
            guard let v = table[key] else { return false }
            guard v.confidence >= Self.requiredFloor else { return false }
            return v.isHardEnoughForRequiredSlot
        }
    }

    public func fill(_ t: MessageTemplate, in ctx: MessageContext) -> String? {
        fill(t, table: table(for: ctx), family: ctx.appFamily)
    }

    public func fill(
        _ t: MessageTemplate, table: [SlotKey: SlotValue], family: AppFamily
    ) -> String? {
        guard canSatisfyRequired(t, table: table) else { return nil }

        let optionalsOK = t.optionalSlots.allSatisfy { key in
            resolve(key, table: table, family: family, required: false) != nil
        }
        let source: String
        if optionalsOK {
            source = t.text
        } else if let alt = t.altText {
            source = alt
        } else {
            return nil
        }

        var rendered = source
        for key in SlotKey.allCases {
            let token = "{\(key.rawValue)}"
            guard rendered.contains(token) else { continue }
            let isRequired = t.requiredSlots.contains(key)
            guard let value = resolve(key, table: table, family: family, required: isRequired) else {
                return nil
            }
            rendered = rendered.replacingOccurrences(of: token, with: value)
        }

        if rendered.contains("{") && rendered.contains("}") { return nil }
        return rendered
    }

    private func resolve(
        _ key: SlotKey, table: [SlotKey: SlotValue], family: AppFamily, required: Bool
    ) -> String? {
        if let v = table[key] {
            let floor = required ? Self.requiredFloor : Self.optionalFloor
            if v.confidence >= floor, required ? v.isHardEnoughForRequiredSlot : true {
                return v.text
            }
        }
        guard !required, key.canDegrade else { return nil }
        switch key {
        case .app:      return family.degradedAppName
        case .project:  return "this project"
        case .activity: return "whatever this is"
        default:        return nil
        }
    }

    private static let corpusLocale = Locale(identifier: "en_US_POSIX")

    private func format(integer: Int) -> String {
        integer.formatted(.number.locale(Self.corpusLocale))
    }

    private func format(time: Date, timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = Self.corpusLocale
        style.timeZone = timeZone
        return time.formatted(style)
    }
}
