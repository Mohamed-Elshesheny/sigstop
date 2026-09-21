import Foundation

// MARK: - Slots

public enum SlotKey: String, Codable, Sendable, CaseIterable, Hashable {
    case app        // "Cursor"         , display name of the foreground app
    case minutes    // "94"             , continuous work minutes
    case project    // "payments-api"   , workspace / repo name
    case branch     // "fix/retry-loop" , current git branch
    case activity   // "debugging"      , human-readable activity noun
    case streak     // "3"              , skipped-breaks count
    case count      // "41"             , generic counter the collector supplies
    case hour       // "2:14 AM"        , localized time of day

    /// Slots that must never degrade, because a wrong value is worse than no line at all.
    /// There is no "your branch" that is funny, and a wrong skip count destroys the
    /// joke's entire premise. See docs/MESSAGE-ENGINE.md §2.3.
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
        case exact     // read directly (git HEAD, window title, an OS API)
        case derived   // computed from an exact value (minutes from a timestamp)
        case degraded  // family-level substitute ("your editor")
        case generic   // neutral filler ("this")
    }

    public init(text: String, confidence: Double, provenance: Provenance) {
        self.text = text
        self.confidence = min(max(confidence, 0), 1)
        self.provenance = provenance
    }

    /// Treated as exact for gating purposes, a derived value is arithmetic on a fact.
    public var isHardEnoughForRequiredSlot: Bool {
        provenance == .exact || provenance == .derived
    }
}

// MARK: - Resolver

/// Builds the slot table from the context and renders a template's text.
///
/// Pure: it reads the context and nothing else. No clock, no I/O, no AppKit.
public struct SlotResolver: Sendable {
    public static let requiredFloor: Double = 0.70
    public static let optionalFloor: Double = 0.50

    public init() {}

    // MARK: Table

    /// Every slot value the engine can offer for this context, before any degradation.
    /// Absent means absent: a slot with no honest value simply is not in the table, which
    /// is what makes "a {branch} line is unselectable when branch is nil" a hard gate in
    /// step 1 rather than a string check at render time.
    public func table(for ctx: MessageContext) -> [SlotKey: SlotValue] {
        var out: [SlotKey: SlotValue] = [:]

        out[.minutes] = SlotValue(
            text: format(integer: ctx.continuousWorkMinutes, locale: ctx.locale),
            confidence: 0.99, provenance: .derived)

        out[.hour] = SlotValue(
            text: format(time: ctx.now, locale: ctx.locale, timeZone: ctx.calendar.timeZone),
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
                text: format(integer: skipped, locale: ctx.locale),
                confidence: 0.99, provenance: .exact)
        }

        for (k, v) in ctx.slotOverrides { out[k] = v }
        /// Last, and after the overrides on purpose: a withheld slot is a property of
        /// where this line is going, and nothing upstream may put the value back.
        for key in ctx.withheldSlots { out.removeValue(forKey: key) }
        return out
    }

    // MARK: Gate

    /// Hard gate, evaluated in step 1: can every required slot be satisfied exactly or by
    /// derivation, at or above the required floor?
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

    // MARK: Render

    /// Returns the filled text, or nil when the line cannot be rendered honestly.
    ///
    /// Never returns a string containing an unfilled `{slot}`, if a placeholder would
    /// survive, the template is dropped instead.
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

    /// The fallback chain from §2.3: exact -> derived -> degraded -> generic.
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

    // MARK: Formatting

    private func format(integer: Int, locale: Locale) -> String {
        integer.formatted(.number.locale(locale))
    }

    private func format(time: Date, locale: Locale, timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        return time.formatted(style)
    }
}
