import Foundation

// MARK: - Deterministic selection

// MARK: - Duration formatting

/// `"8h 12m"`, `"47m"`, `"0m"`. Minute resolution, because a summary that reports
/// seconds is inviting someone to optimise seconds.
public enum DurationText {
    public static func short(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int((seconds / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    /// `"8 hours"`, `"1 hour 12 minutes"`, `"47 minutes"`. For the opening clause of a
    /// sentence, where `8h 12m` reads like a log line.
    public static func long(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int((seconds / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if hours == 0 { return plural(minutes, "minute") }
        if minutes == 0 { return plural(hours, "hour") }
        return "\(plural(hours, "hour")) \(plural(minutes, "minute"))"
    }
}

// MARK: - Narrator

/// Turns a `DailySummary` into the one line a developer actually reads.
///
/// This is the voice of `jobs`: everything you had suspended today, reported once, in
/// the tone the user chose. It reports; it does not grade (docs/BREAK-DECISION.md §16)
/// — there are no streaks and no red numbers anywhere in this file.
///
/// This used to say "no badges" too. There are badges now — ten of them, in
/// `Badges/Badge.swift`, shown in Settings and nowhere near this file — so the sentence
/// was rewritten rather than quietly deleted. The line it drew is still the real one and
/// it moved by one word: **the daily summary does not grade a day.** A badge is a record
/// of something that already happened, it cannot go down, nothing expires, and none of
/// the ten rewards working longer. A streak would be the opposite of all four, which is
/// why there still is not one.
public struct SummaryNarrator: Sendable {
    public let tone: Tone
    private let appName: @Sendable (String) -> String

    /// - Parameter appName: how a bundle identifier is spoken. The default takes the
    ///   last dotted component, which turns `com.apple.dt.Xcode` into `Xcode` without
    ///   asking the operating system anything — `SigstopCore` has no way to look up a
    ///   localized name and must not acquire one.
    public init(
        tone: Tone = .sarcastic,
        appName: @escaping @Sendable (String) -> String = SummaryNarrator.defaultAppName
    ) {
        self.tone = tone
        self.appName = appName
    }

    public static let defaultAppName: @Sendable (String) -> String = { bundleID in
        if bundleID == DailyRollup.unattributedApplication { return "an unidentified app" }
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last.isEmpty ? bundleID : last
    }

    // MARK: Slots

    enum Slot: String, CaseIterable {
        case work
        case workLong
        case longest
        case breaks
        case top
        case topTime
        case opportunities
        case honored
        case compliance
        case missed
        case sessions
    }

    struct Template: Sendable {
        let text: String
        let requires: Set<String>

        init(_ text: String, requires: Set<Slot> = []) {
            self.text = text
            self.requires = Set(requires.map(\.rawValue))
        }
    }

    // MARK: Public API

    /// The single developer-voice line.
    ///
    /// Deterministic in `seed`: the same seed and the same day always produce the same
    /// sentence. Callers pass something stable per day (a hash of the date, say), so the
    /// line does not change if the popover is reopened, and varies from day to day so it
    /// does not go stale.
    public func line(for summary: DailySummary, seed: UInt64) -> String {
        var rng = SeededGenerator(seed: seed)
        let values = slots(for: summary)

        if summary.totalActiveWork <= 0 {
            let pool = Self.emptyDayLines[tone] ?? []
            return pick(pool, values: values, rng: &rng) ?? "No active work recorded today."
        }

        let opener = pick(Self.openers[tone] ?? [], values: values, rng: &rng)
            ?? "\(DurationText.long(summary.totalActiveWork)) of active work today."
        let kicker = pick(Self.kickers[tone] ?? [], values: values, rng: &rng) ?? ""
        return kicker.isEmpty ? opener : "\(opener) \(kicker)"
    }

    /// The auditable long form that sits under the line: numbers, no voice.
    /// Always rendered with the parenthetical, per docs/BREAK-DECISION.md §14.2 — a bare
    /// percentage invites optimising a number.
    public func detail(for summary: DailySummary) -> String {
        var parts: [String] = []
        parts.append("Active work \(DurationText.short(summary.totalActiveWork))")
        if summary.longestContinuousSession > 0 {
            parts.append("longest stretch \(DurationText.short(summary.longestContinuousSession))")
        }
        parts.append("\(summary.breakCount) break\(summary.breakCount == 1 ? "" : "s")")
        parts.append("break compliance \(summary.complianceDescription)")
        if let top = summary.topApplication {
            parts.append("\(appName(top.bundleID)) \(DurationText.short(top.seconds))")
        }
        if summary.malformedLines > 0 {
            parts.append("\(summary.malformedLines) unreadable log line(s) skipped")
        }
        return parts.joined(separator: " · ")
    }

    /// How many distinct lines this tone can produce for a day with every slot filled.
    /// Exposed so a test can assert the corpus has not quietly shrunk to one variant.
    public func variantCount() -> Int {
        (Self.openers[tone]?.count ?? 0) * (Self.kickers[tone]?.count ?? 0)
    }

    // MARK: Rendering

    private func slots(for summary: DailySummary) -> [String: String] {
        var values: [String: String] = [
            Slot.work.rawValue: DurationText.short(summary.totalActiveWork),
            Slot.workLong.rawValue: DurationText.long(summary.totalActiveWork),
            Slot.breaks.rawValue: "\(summary.breakCount)",
            Slot.sessions.rawValue: "\(summary.sessionCount)",
        ]
        if summary.longestContinuousSession > 0 {
            values[Slot.longest.rawValue] =
                DurationText.short(summary.longestContinuousSession)
        }
        if let top = summary.topApplication, top.seconds > 0 {
            values[Slot.top.rawValue] = appName(top.bundleID)
            values[Slot.topTime.rawValue] = DurationText.short(top.seconds)
        }
        if summary.breakOpportunities > 0 {
            values[Slot.opportunities.rawValue] = "\(summary.breakOpportunities)"
            values[Slot.honored.rawValue] = "\(summary.honoredOpportunities)"
        }
        if summary.breakCompliance != nil {
            values[Slot.compliance.rawValue] = summary.complianceDescription
        }
        if summary.missedOpportunities > 0 {
            values[Slot.missed.rawValue] = "\(summary.missedOpportunities)"
        }
        return values
    }

    /// Picks only among templates whose every slot can actually be filled.
    ///
    /// Absence is modelled as absence: a template that needs `{top}` simply cannot be
    /// selected on a day with no attributed app. This is the same rule the message
    /// engine follows, and it is why no rendered string ever contains a stray `{...}`.
    private func pick(
        _ pool: [Template], values: [String: String], rng: inout SeededGenerator
    ) -> String? {
        let eligible = pool.filter { $0.requires.isSubset(of: Set(values.keys)) }
        guard !eligible.isEmpty else { return nil }
        let chosen = eligible[rng.index(below: eligible.count)]
        return render(chosen.text, values: values)
    }

    func render(_ text: String, values: [String: String]) -> String {
        var out = text
        for (key, value) in values {
            out = out.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return out
    }
}

// MARK: - The corpus

extension SummaryNarrator {

    /// Openers carry the facts. The tone changes *what the sentence is about*, not how
    /// hard it hits — see docs/MESSAGE-ENGINE.md §4.1.
    static let openers: [Tone: [Template]] = [
        .friendly: [
            Template("{workLong} of active work today."),
            Template("{work} on the clock today, with {breaks} breaks."),
            Template("{workLong} today. Longest unbroken stretch: {longest}.", requires: [.longest]),
            Template("Day's total: {work}. Break compliance {compliance}.", requires: [.compliance]),
            Template("{work} of active work, mostly in {top} ({topTime}).", requires: [.top, .topTime]),
            Template("{workLong} across {sessions} sessions."),
        ],
        .sarcastic: [
            Template("{workLong} of active work. The clock is not editorialising; it only counts."),
            Template("{work} today, {breaks} breaks. Filed without comment."),
            Template(
                "Longest unbroken stretch: {longest}. A number you picked, apparently.",
                requires: [.longest]
            ),
            Template(
                "{work} on the clock. {top} claimed {topTime} of it.",
                requires: [.top, .topTime]
            ),
            Template(
                "{work} of work and a break compliance of {compliance}.",
                requires: [.compliance]
            ),
            Template("{workLong}. The log agrees with itself, for once."),
        ],
        .roast: [
            Template("{work} of active work. {breaks} breaks. Do the arithmetic."),
            Template(
                "{work} today. Longest stretch without stopping: {longest}.",
                requires: [.longest]
            ),
            Template(
                "The app opened {opportunities} break windows. You walked through {honored}.",
                requires: [.opportunities, .honored]
            ),
            Template(
                "{work} on the clock, {missed} prompts answered with silence.",
                requires: [.missed]
            ),
            Template(
                "{work}, and {top} took {topTime} of it without once being questioned.",
                requires: [.top, .topTime]
            ),
            Template("{workLong}. The ladder went all the way up again."),
        ],
        .nuclear: [
            Template("{work} OF ACTIVE WORK. THE BUILD SERVER HAS FILED FOR EMANCIPATION."),
            Template(
                "{longest} IN ONE UNBROKEN STRETCH. CONTINENTS MOVED FURTHER THAN THIS CURSOR.",
                requires: [.longest]
            ),
            Template("{work} TODAY. THE KEYBOARD HAS UNIONISED AND ELECTED A REPRESENTATIVE."),
            Template(
                "{top} LOGGED {topTime}. GEOLOGISTS ARE DATING THE CHAIR BY ITS LAYERS.",
                requires: [.top, .topTime]
            ),
            Template("{work}. THE TIMER ACHIEVED SENTIENCE AT HOUR FOUR AND FILED A REPORT."),
            Template(
                "{breaks} BREAKS IN {work}. THE SCROLLBACK HAS BEEN DECLARED A PRIMARY SOURCE."
            ),
        ],
    ]

    /// Kickers carry the voice. Every one of them targets a tool, the clock, the log, or
    /// a behaviour. None targets a person, a body, or an ability.
    static let kickers: [Tone: [Template]] = [
        .friendly: [
            Template("Everything you suspended today is right where you left it."),
            Template("The log is closed. SIGCONT tomorrow."),
            Template("Nothing else is due today."),
            Template("Nicely done. The stack is saved."),
            Template("That is the whole jobs list."),
            Template("Go do something with no build step."),
        ],
        .sarcastic: [
            Template("The chair held up its end of the deal."),
            Template("The clock has no opinion. The clock only has receipts."),
            Template("SIGCONT is available tomorrow, same place, same stack."),
            Template("Filed under: days that happened."),
            Template("{top} would like to be listed as an emergency contact.", requires: [.top]),
            Template("There are badges. There is no streak, so there is nothing here to protect."),
        ],
        .roast: [
            Template("The ladder starts at SIGTSTP again tomorrow. It always does."),
            Template("The log does not round in your favour."),
            Template("Every one of those prompts was catchable. That was the point."),
            Template("SIGSTOP was never the threat. Ignoring SIGTERM was."),
            Template("The timer will be here tomorrow. It has nowhere else to be."),
            Template("Tomorrow it starts at zero, whether or not that suits you."),
        ],
        .nuclear: [
            Template("SIGSTOP WAS NEVER A THREAT. IT WAS A PROMISE. THE PROMISE HAS BEEN KEPT."),
            Template("THE LOG HAS BEEN SEALED AND SENT TO AN ARCHIVE THAT DOES NOT EXIST YET."),
            Template("SOMEWHERE A LINTER IS SCREAMING INTO A VOID OF ITS OWN MAKING."),
            Template("TOMORROW THE LADDER RESETS. THE LADDER ALWAYS RESETS. THE LADDER IS ETERNAL."),
            Template("YOUR COMPILER HAS REQUESTED A TRANSFER TO A QUIETER DEPARTMENT."),
            Template("SIGCONT AT DAWN. EVERYTHING INTACT. REGISTERS, MEMORY, ALL OF IT."),
        ],
    ]

    /// A day with nothing on the clock. Reported plainly — an empty log is a result,
    /// not a failure, and nothing here implies the reader did something wrong.
    static let emptyDayLines: [Tone: [Template]] = [
        .friendly: [
            Template("No active work recorded today. The log is empty."),
            Template("Nothing on the clock today. Nothing due, either."),
            Template("The jobs list is empty. That is allowed."),
        ],
        .sarcastic: [
            Template("Zero minutes of active work recorded. Either you were away or the sensors were."),
            Template("Nothing on the clock. The log has one job and today it had none."),
            Template("An empty day, faithfully recorded. You are welcome."),
        ],
        .roast: [
            Template("Nothing on the clock today. The log came up completely empty."),
            Template("Zero credited minutes. Whatever happened today, it happened elsewhere."),
            Template("The event log has nothing to report and is not pretending otherwise."),
        ],
        .nuclear: [
            Template("ZERO. THE EVENT LOG HAS BEEN DECLARED A PROTECTED WILDERNESS."),
            Template("NO CREDITED WORK. THE TIMER SAT IN THE DARK AND COUNTED NOTHING."),
            Template("AN EMPTY DAY. THE SCHEDULER HAS FILED IT UNDER 'UNEXPLAINED PHENOMENA'."),
        ],
    ]

    /// Every template in the file, for the rails test.
    public static var allTemplateTexts: [String] {
        (openers.values.flatMap { $0 } + kickers.values.flatMap { $0 }
            + emptyDayLines.values.flatMap { $0 }).map(\.text)
    }
}
