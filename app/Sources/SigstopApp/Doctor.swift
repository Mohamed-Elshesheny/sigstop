import Foundation
import SigstopCore
import SigstopSensors

/// `sigstop --doctor` — what the app can observe **right now**, printed plainly.
///
/// This is the file a sceptic runs instead of believing the privacy page. So it is held
/// to a different standard than the rest of the UI:
///
///   * every signal is listed, including the ones that are unavailable, with the reason;
///   * "unavailable" is never printed as `false` — `0 s` idle and *cannot read idle* are
///     different facts, and collapsing them is exactly the lie a time tracker tells;
///   * the confidence number is shown with the log-odds that produced it, so the column
///     can be added up by hand and checked against the total;
///   * no colour codes, no spinners, no progress bars. It is meant to be piped, diffed,
///     and pasted into an issue.
///
/// It does not start the UI, does not post a notification, does not write to the event
/// log, and cannot reach a permission prompt.
@MainActor
enum Doctor {

    static func run() async {
        for line in await report() {
            print(line)
        }
    }

    static func report() async -> [String] {
        let settings = SettingsStore.load()
        let sensors = SensorStack(settings: settings)

        sensors.audio.refresh()
        sensors.system.reconcile()
        sensors.frontmost.reconcile()
        sensors.permissions.refresh()

        let sample = await sensors.context.sampleAndPublish()
        let raw = sensors.readSignals()

        var out: [String] = []
        out.append(contentsOf: headerSection(settings: settings))
        out.append(contentsOf: permissionSection(sensors.permissions.status()))
        out.append(contentsOf: signalSection(raw, sensors: sensors))
        out.append(contentsOf: inferenceSection(sample))
        out.append(contentsOf: unavailableSection(raw))
        out.append(contentsOf: storageSection())
        out.append("")
        return out
    }

    // MARK: Sections

    private static func headerSection(settings: SigstopSettings) -> [String] {
        [
            "sigstop --doctor",
            "  Everything below was read from this machine just now, and none of it was sent",
            "  anywhere. This process has made no network request: the only one it can make is",
            "  the update check, and that happens when you press the button in Settings.",
            "  The app's own binary references no networking symbol at all — every byte of",
            "  network code is inside Sparkle.framework. Verify all of it with `make verify`.",
            "",
            "PROCESS",
            "  bundle           \(AppPaths.isBundled ? AppPaths.bundleID : "none — running as a bare executable")",
            "  executable       \(CommandLine.arguments.first ?? "unknown")",
            "  work interval    \(settings.workIntervalMinutes) min of continuous active work",
            "  break length     \(settings.breakDurationMinutes) min",
            "  tone             \(settings.tone.displayName.uppercased())",
            "  quiet hours      "
                + (settings.quietHours.enabled
                    ? "\(Format.minuteOfDay(settings.quietHours.startMinute)) – \(Format.minuteOfDay(settings.quietHours.endMinute))"
                    : "off"),
            "",
        ]
    }

    private static func permissionSection(_ status: PermissionStatus) -> [String] {
        var out = ["PERMISSIONS"]
        out.append(contentsOf: status.explanation.map { "  \($0)" })
        out.append(
            "  Never requested at all: Screen Recording, Input Monitoring, Full Disk Access,"
        )
        out.append(
            "  Automation/Apple Events, Calendar, Contacts, Microphone, Camera, Location."
        )
        out.append("")
        return out
    }

    private static func signalSection(_ raw: RawSignals, sensors: SensorStack) -> [String] {
        var out = [
            "SIGNALS",
            "  tier  signal                value",
        ]

        func row(_ tier: String, _ name: String, _ value: String) {
            let paddedTier = tier.padding(toLength: 6, withPad: " ", startingAt: 0)
            let paddedName = name.padding(toLength: 22, withPad: " ", startingAt: 0)
            out.append("  \(paddedTier)\(paddedName)\(value)")
        }

        row("0", "frontmost app", raw.frontmost.frontmost.localizedName)
        row("0", "bundle id", raw.frontmost.frontmost.bundleID ?? "none (bundle-less process)")
        row(
            "0", "frontmost for",
            "\(Int(Date().timeIntervalSince(raw.frontmost.frontmostSince)))s "
                + "(measured from when this process started, not from when you switched)"
        )
        row("0", "app switches", "\(raw.frontmost.switchCount) since launch")
        row("0", "apps running", "\(raw.frontmost.runningBundleIDs.count)")

        switch raw.input.knownIdleSeconds {
        case .some(let seconds):
            row("0", "input idle", String(format: "%.1fs via %@", seconds, raw.input.source.rawValue))
        case .none:
            row("0", "input idle", "UNAVAILABLE — this Mac reports no HID idle time, so the app")
            out.append("                              cannot tell whether you are at the keyboard, and")
            out.append("                              it will not claim that you are.")
        }

        row("0", "screen locked", raw.session.screenLocked ? "yes" : "no")
        row("0", "displays asleep", raw.session.displaysAsleep ? "yes" : "no")
        row("0", "session on console", raw.session.sessionActive ? "yes" : "no — someone else is signed in")
        row("0", "audio input", audioText(raw.audio))
        if let caveat = raw.audioCaveat {
            out.append("        \(caveat)")
        }
        row("0", "on battery", raw.power.onBattery ? "yes" : "no")
        row("0", "low power mode", raw.power.lowPowerMode ? "on" : "off")
        row("0", "thermal", raw.power.thermal.description)

        let tier1 = raw.tiers.contains(.tier1)
        row(
            "1", "window title",
            tier1
                ? "readable — parsed, then discarded; never written to disk"
                : "not readable — see PERMISSIONS above"
        )
        if let failure = sensors.accessibility.lastFailure {
            out.append("        last Accessibility error: \(failure.userFacingSummary)")
        }
        row(
            "2", "git branch",
            raw.tiers.contains(.tier2)
                ? "opted in, but the collector is not implemented yet (see UNAVAILABLE)"
                : "opted out"
        )

        out.append("")
        return out
    }

    private static func inferenceSection(_ sample: ContextSample) -> [String] {
        let context = sample.context
        var out = ["INFERENCE"]

        let label = sample.honestLabel ?? context.claimableActivity.displayName
        out.append("  activity         \(label)")
        if context.claimableActivity != context.activity {
            out.append(
                "                   (degraded from \(context.activity.displayName) — not confident"
            )
            out.append("                   enough to pick between siblings, so it says the parent)")
        }
        out.append(String(format: "  confidence       %.2f", context.confidence.value))
        out.append("  provider         \(sample.providerID.rawValue)")
        out.append("  tiers used       \(tierText(context.tiersUsed))")
        out.append("  continuous work  \(DurationText.short(context.continuousWork))")
        out.append(
            "  since last break "
                + (context.timeSinceLastBreak.map(DurationText.short) ?? "no break recorded yet")
        )

        out.append("")
        out.append("  EVIDENCE  (log-odds; the prior is about -1.74, single items clamp at ±2.00)")
        if context.evidence.isEmpty {
            out.append("    none — nothing here is evidence for anything, and the number says so")
        }
        for item in context.evidence.sorted(by: { abs($0.logOdds) > abs($1.logOdds) }) {
            out.append("    \(Format.logOdds(item.logOdds))  t\(item.tier.rawValue)  \(item.summary)")
        }

        if !sample.caveats.isEmpty {
            out.append("")
            out.append("  CAVEATS")
            for caveat in sample.caveats { out.append("    \(caveat)") }
        }

        out.append("")
        out.append("  PROMPTS")
        switch sample.gate {
        case .allowed:
            out.append("    allowed right now")
        case .softDeferred(let reason):
            out.append("    deferred — \(reason)")
            out.append("    (a guess may delay a prompt. It may never suppress one.)")
        case .hardBlocked(let reason):
            out.append("    blocked — \(reason)")
            out.append("    (an OS fact, not an inference. This is the only thing allowed to block.)")
        }
        out.append("")
        return out
    }

    /// The honest list. Every row here is something the app could plausibly be expected to
    /// know and does not, with the reason it does not.
    private static func unavailableSection(_ raw: RawSignals) -> [String] {
        [
            "UNAVAILABLE, AND WHY",
            "  keystroke rate       Would need Input Monitoring. Declined on principle — the app",
            "                       reports WHEN input happened, never WHAT was typed. The engine",
            "                       therefore never defers for a typing burst. It never fires extra.",
            "  browser URL / host   There is no permission-free way to read it. The only routes are",
            "                       Apple Events (an Automation grant) and Screen Recording, both",
            "                       declined. The opt-in exists; the collector does not, so the",
            "                       field is nil rather than faked.",
            "  running processes    Tier 2 process snapshot is not implemented yet. Consequence:",
            "                       DEBUGGING is currently unreachable and the app degrades to",
            "                       CODING instead of guessing between them.",
            "  git branch / state   Tier 2 .git/HEAD collector is not implemented yet, so the opt-in",
            "                       currently buys nothing. Templates needing {branch} simply cannot",
            "                       be selected.",
            "  calendar             EventKit is declined outright. Reading it would mean every event",
            "                       title, attendee and location to answer one yes/no question.",
            "  camera in use        No permission-free API. Reported as absent, never as false.",
            "  screen being shared  Would need ScreenCaptureKit and the Screen Recording grant.",
            "  Focus mode           No public API. Passed to the engine as nil — which the policy",
            "                       distinguishes from false — rather than assumed off.",
            "  battery percentage   Not read. Charging state is, and it is permission-free.",
            "  window geometry      \(raw.frontmost.runningBundleIDs.isEmpty ? "unknown" : "counts and a fullscreen hint only; window NAMES are")",
            "                       omitted by macOS without Screen Recording, and are not wanted.",
            "",
        ]
    }

    private static func storageSection() -> [String] {
        let root = AppPaths.storageRoot
        var out = [
            "STORAGE",
            "  location         \(root.path)",
            "  format           one JSON object per line; `cat` is a complete audit tool",
            "  retention        \(Retention.defaultEventDays) days of raw events",
        ]
        guard FileManager.default.fileExists(atPath: root.path) else {
            out.append("  days on disk     nothing stored yet — the app has not run here")
            out.append("")
            out.append("  Never stored, by construction: window titles, URLs, file paths, document text,")
            out.append("  keystrokes, clipboard contents, screen contents, message text. There is no")
            out.append("  field in the log's type that could hold one.")
            return out
        }
        if let store = try? FileEventStore(root: root), let days = try? store.availableDays() {
            out.append("  days on disk     \(days.count)\(days.isEmpty ? "" : "  (\(days[0]) .. \(days[days.count - 1]))")")
            let today = CalendarDay.local(of: Date(), calendar: .current, boundaryHour: BreakPolicy.default.dayBoundaryHour)
            if let summary = try? DailyRollup.compute(day: today, from: store) {
                out.append("  today            \(SummaryNarrator(tone: .friendly).detail(for: summary))")
            }
        } else {
            out.append("  days on disk     could not read the store")
        }
        out.append("")
        out.append("  Never stored, by construction: window titles, URLs, file paths, document text,")
        out.append("  keystrokes, clipboard contents, screen contents, message text. There is no")
        out.append("  field in the log's type that could hold one.")
        return out
    }

    // MARK: Small renderings

    private static func audioText(_ state: AudioInputState) -> String {
        switch state {
        case .running:      return "an input device IS running — treated as a possible call"
        case .notRunning:   return "no input device is running"
        case .noInputDevice: return "this Mac has no audio input device"
        case .unreliable:   return "DISABLED on this Mac — the signal never turns off"
        }
    }

    private static func tierText(_ tiers: SignalTierSet) -> String {
        var names: [String] = []
        if tiers.contains(.tier0) { names.append("0") }
        if tiers.contains(.tier1) { names.append("1") }
        if tiers.contains(.tier2) { names.append("2") }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }
}

extension ThermalLevel {
    var description: String {
        switch self {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious — the app sheds load"
        case .critical: return "critical — the app sheds load"
        }
    }
}
