import Foundation
import SigstopCore
import SigstopSensors

/// `sigstop --doctor`, what the app can observe **right now**, printed plainly.
///
/// This is the file a sceptic runs instead of believing the privacy page. So it is held
/// to a different standard than the rest of the UI:
///
///   * every signal is listed, including the ones that are unavailable, with the reason;
///   * "unavailable" is never printed as `false`, `0 s` idle and *cannot read idle* are
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
        sensors.camera.refresh()
        sensors.audioProcesses.refresh()
        sensors.system.reconcile()
        sensors.frontmost.reconcile()
        sensors.permissions.refresh()

        let sample = await sensors.context.sampleAndPublish()
        let raw = sensors.readSignals()

        var out: [String] = []
        out.append(contentsOf: headerSection(settings: settings))
        out.append(contentsOf: permissionSection(sensors.permissions.status()))
        out.append(contentsOf: signalSection(raw, sensors: sensors))
        out.append(contentsOf: callHoldSection(raw, settings: settings))
        out.append(contentsOf: inferenceSection(sample, raw: raw, settings: settings))
        out.append(contentsOf: unavailableSection(raw))
        out.append(contentsOf: outlookSection(settings: settings))
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
            "  The app's own binary references no networking symbol at all, every byte of",
            "  network code is inside Sparkle.framework. Verify all of it with `make verify`.",
            "",
            "PROCESS",
            "  bundle           \(AppPaths.isBundled ? AppPaths.bundleID : "none, running as a bare executable")",
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
            row("0", "input idle", "UNAVAILABLE, this Mac reports no HID idle time, so the app")
            out.append("                              cannot tell whether you are at the keyboard, and")
            out.append("                              it will not claim that you are.")
        }

        row("0", "screen locked", raw.session.screenLocked ? "yes" : "no")
        row("0", "displays asleep", raw.session.displaysAsleep ? "yes" : "no")
        row("0", "session on console", raw.session.sessionActive ? "yes" : "no, someone else is signed in")
        row("0", "audio input", audioText(raw.audio))
        if let caveat = raw.audioCaveat {
            out.append("        \(caveat)")
        }
        switch raw.audioProcesses.inputBundleIDs {
        case .none:
            row("0", "audio input, by app", "the process table could not be read, so the")
            out.append("                              microphone bit above carries no attribution.")
            out.append("                              That is reported as unknown, never as nobody.")
        case .some(let holders) where holders.isEmpty && raw.audioProcesses.unnamedInputHolders == 0:
            row("0", "audio input, by app", "nobody. \(raw.audioProcesses.processCount) processes are known to")
            out.append("                              CoreAudio and none of them is running input.")
            out.append("                              A device running with nobody holding it is a virtual")
            out.append("                              device, and it does not hold your break.")
        case .some(let holders) where holders.isEmpty:
            row("0", "audio input, by app", "\(raw.audioProcesses.unnamedInputHolders) with no bundle id, which is what a")
            out.append("                              command-line recorder looks like. Counted as a holder,")
            out.append("                              never as nobody.")
        case .some(let holders):
            row("0", "audio input, by app", holders.sorted().joined(separator: ", "))
            out.append("                              kAudioProcessPropertyIsRunningInput, per process object.")
            out.append("                              No permission, no prompt. The bundle id is matched")
            out.append("                              against a fixed list and discarded; nothing else about")
            out.append("                              the process is read.")
        }
        row("0", "camera in use", cameraText(raw.camera))
        for device in raw.cameraDevices {
            out.append("                              \(device)")
        }
        out.append("                              kCMIODevicePropertyDeviceIsRunningSomewhere, a property")
        out.append("                              read. No capture session is opened, no Camera permission")
        out.append("                              is requested, and a read failure is reported as unknown")
        out.append("                              here, never as no.")
        if let caveat = raw.cameraCaveat {
            out.append("        \(caveat)")
        }
        row("0", "on battery", raw.power.onBattery ? "yes" : "no")
        row("0", "low power mode", raw.power.lowPowerMode ? "on" : "off")
        row("0", "thermal", raw.power.thermal.description)

        let tier1 = raw.tiers.contains(.tier1)
        row(
            "1", "window title",
            tier1
                ? "readable, parsed, then discarded; never written to disk"
                : "not readable, see PERMISSIONS above"
        )
        if let failure = sensors.accessibility.lastFailure {
            out.append("        last Accessibility error: \(failure.userFacingSummary)")
        }
        row("2", "tool names", toolText(sensors))
        for line in toolDetail(sensors) {
            out.append("                              \(line)")
        }
        row("2", "git branch", gitText(sensors))
        for line in gitDetail(sensors) {
            out.append("                              \(line)")
        }

        out.append("")
        return out
    }

    /// The Tier 2 process row. Four outcomes and not a count, because "off", "not this
    /// sample", "could not read the table" and "read it, nothing matched" are four facts
    /// and only the last one means no debugger is running.
    private static func toolText(_ sensors: SensorStack) -> String {
        switch sensors.processes.lastOutcome {
        case .optedOut:
            return "opted out, nothing is read"
        case .skipped(let reason):
            return "on, not scanned this sample: \(reason)"
        case .unreadable:
            return "on, and the process table could not be read. Reported as unknown,"
        case .scanned(let count):
            let matched = sensors.processes.lastSnapshot?.matchedTools ?? []
            let names = matched.map(\.displayName).sorted().joined(separator: ", ")
            return "on, \(count) processes compared by name; "
                + (matched.isEmpty ? "none matched" : "matched \(names)")
        }
    }

    private static func toolDetail(_ sensors: SensorStack) -> [String] {
        switch sensors.processes.lastOutcome {
        case .optedOut:
            return []
        case .skipped:
            return [
                "The scan is gated so it costs nothing while it could tell you",
                "nothing. This is not a failure and not an answer: the app does",
                "not know whether a debugger is running, and does not claim to.",
            ]
        case .unreadable:
            return ["never as nobody. A zero-length table is a failure, not a Mac with", "no processes on it."]
        case .scanned:
            let snapshot = sensors.processes.lastSnapshot
            var lines = [
                "Only p_comm, the executable path of the few that matched, and the",
                "P_TRACED flag. No command line, no environment, no working directory.",
            ]
            if snapshot?.tracedUnderFrontmost == true {
                lines.append("under a debugger: yes, in something this app started")
            } else if snapshot?.tracedElsewhere == true {
                lines.append("under a debugger: yes, but elsewhere on this Mac, so it is")
                lines.append("corroboration for a named debugger and never a verdict alone")
            } else {
                lines.append("under a debugger: nothing on this Mac is, right now")
            }
            return lines
        }
    }

    /// What the call latch would do with the signals above.
    ///
    /// `--doctor` is a separate process (`AppMain`) that builds a fresh `SensorStack`. It
    /// therefore starts with the latch closed and **cannot** see the latch the running app
    /// is holding. Printing "not holding" would be exactly the kind of lie this file
    /// exists to prevent, so it prints what it can observe and what the latch would make
    /// of it, and says which is which.
    private static func callHoldSection(_ raw: RawSignals, settings: SigstopSettings) -> [String] {
        let policy = BreakPolicy(settings: settings)
        var out = [
            "CALL HOLD",
            "  This process starts with the latch closed and cannot see the running app's",
            "  latch. Everything below is what --doctor can observe by itself, right now.",
            "",
        ]
        out.append("  enabled              " + (settings.holdBreaksDuringCalls ? "yes" : "no, turned off in Settings"))
        out.append("  arms after           \(Int(policy.latchArmDwell))s of continuous microphone or camera use")
        let capture = raw.micLiveForLatch || raw.camera.contributesToMeeting
        out.append("  capture live now     " + (capture ? "yes" : "no"))
        /// Which block covers a call while it is actually running. On most Macs it is the
        /// device fact and the latch only ever handles the trailing edge. On a Mac with a
        /// virtual audio driver the device fact is not a usable positive at all, so the
        /// latch is the only thing left and it has to block during the call itself. That
        /// is a real difference in behaviour between two Macs and it is printed, not
        /// smoothed over.
        if raw.audio == .unreliable || raw.camera == .unreliable {
            out.append("  live call blocked by the latch itself. The device signal on this Mac is not a")
            out.append("                       usable positive, so audioInputInUse and cameraInUse stay")
            out.append("                       false through a real call. The latch holds during the call")
            out.append("                       as well as after it, and charges its own ceilings for it.")
        } else {
            out.append("  live call blocked by audioInputInUse / cameraInUse, which are device facts.")
            out.append("                       The latch stays out of the way until capture stops.")
        }
        let anchor = raw.attributedCallCapable ?? raw.frontmostCallCapable
            ?? raw.callCapableRunning.first { $0.isConferencing }
        out.append("  anchor it would take " + (anchor.map { "\($0.name) (\($0.bundleID))" }
            ?? "none. A browser anchors a call only when the audio"))
        if anchor == nil {
            out.append("                       process table names it or it is frontmost, because a")
            out.append("                       browser being open all day is not evidence of anything")
        }
        let base = Int(policy.latchFactHold / 60)
        let extra = Int(policy.latchAnchorExtension / 60)
        out.append("  hold it would give   \(base)m unconditionally"
            + (anchor == nil ? "" : ", plus \(extra)m more while that app keeps running,"))
        if anchor != nil {
            out.append("                       dropping to \(Int(policy.latchAnchorQuitHold))s the moment it quits")
        }
        out.append("  ceilings             \(Int(policy.latchEpisodeCeiling / 60))m of holding per call, "
            + "\(Int(policy.latchDailyCeiling / 3600))h per day, then it stops")
        out.append("                       holding and says so in the menu")
        out.append("  call-capable running " + (raw.callCapableRunning.isEmpty
            ? "none" : raw.callCapableRunning.map(\.name).joined(separator: ", ")))
        out.append("")
        out.append("  What this is NOT: a meeting detector. The app cannot tell a call from a voice")
        out.append("  memo. It knows only that a capture device on this machine was running, for how")
        out.append("  long, and how long ago it stopped. It holds the break for a bounded time on")
        out.append("  that basis and names the fact on screen the whole time.")
        out.append("")
        return out
    }

    private static func inferenceSection(
        _ sample: ContextSample, raw: RawSignals, settings: SigstopSettings
    ) -> [String] {
        let context = sample.context
        var out = ["INFERENCE"]

        let label = sample.honestLabel ?? context.claimableActivity.displayName
        out.append("  activity         \(label)")
        if context.claimableActivity != context.activity {
            out.append(
                "                   (degraded from \(context.activity.displayName), not confident"
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
            out.append("    none, nothing here is evidence for anything, and the number says so")
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
        out.append("  MEETING INFERENCE  (separate from the call hold above, and weaker)")
        out.append("    in a meeting       \(context.concurrent.inMeeting ? "yes" : "no")")
        out.append(String(format: "    meeting confidence %.2f", context.concurrent.meetingConfidence.value))
        out.append(String(
            format: "    tier 0 ceiling     %.2f     specific-claim threshold  %.2f",
            ConfidenceEngine.tier0Ceiling, Confidence.specificClaimThreshold.value
        ))
        out.append("    The ceiling sits below the threshold, so the meeting INFERENCE can never")
        out.append("    fire without Accessibility, however much evidence accumulates. It would")
        out.append("    only ever have postponed a prompt, never blocked one. The call hold above")
        out.append("    needs none of it and works with zero permissions granted.")

        out.append("")
        out.append("  PROMPTS")
        /// The engine's own verdict, not the sensors-layer gate that used to be printed
        /// here. The two can disagree, and after the call latch they will: the gate knows
        /// nothing about it. Hard blocks depend only on the signals and on when the last
        /// break ended, so this line is the truth. Soft deferrals and rate limits depend
        /// on cycle state that lives in the running app and is not visible from here, so
        /// they are not printed at all rather than printed wrong.
        var signals = raw.systemSignals
        /// The same attributed question the running app asks. A device that is running
        /// while nothing at all on this Mac has input open is a virtual device, and the
        /// doctor used to print BLOCKED for it with the row two screens up saying nobody
        /// had the microphone.
        signals.audioInputRunning = raw.audioDeviceHold == .held
        signals.frontmostIsFullscreen = context.concurrent.fullscreen
        let policy = BreakPolicy(settings: settings)
        let probe = EngineInput(
            now: Date(), monotonic: 0, context: context, signals: signals, settings: settings
        )
        if let block = InterruptionPolicy(policy: policy).hardBlock(probe) {
            out.append("    BLOCKED, \(AppModel.explain(.hardBlocked(block)) ?? block.rawValue)")
            out.append("    (an OS fact, not an inference. This is the only thing allowed to block.)")
            if block == .audioInputInUse {
                out.append("    A running input device holds a break for at most")
                out.append("    \(DurationText.long(policy.uncorroboratedAudioCeiling)) on its own evidence. Past")
                out.append("    that, with no camera, no adopted call app, no manual hold and no calendar")
                out.append("    event, it stops blocking and only waits for a natural pause.")
            }
        } else if raw.audioDeviceHold == .runningButUnheld {
            out.append("    no hard block right now")
            out.append("    An input device IS running, and nothing on this Mac has input open, so it")
            out.append("    is not treated as a call. That is the virtual-device case.")
        } else {
            out.append("    no hard block right now")
        }
        out.append("    Computed in this process by calling InterruptionPolicy.hardBlock on the")
        out.append("    signals above, not by asking the running app.")
        out.append("")
        return out
    }

    /// The Tier 2 git row, which prints the branch's LENGTH and never the branch.
    ///
    /// `--doctor` is what a sceptic runs and what the bug report form asks people to paste
    /// whole, and a branch name routinely carries a ticket id, a customer, or a product
    /// nobody has announced. Settings shows the name, on the machine it came from, where
    /// it is not going anywhere. docs/PRIVACY.md §8.12 is the argument in full.
    private static func gitText(_ sensors: SensorStack) -> String {
        switch sensors.git.lastOutcome {
        case .optedOut:
            return "opted out, nothing is read"
        case .skipped(let reason):
            return "on, not read this sample: \(reason)"
        case .noFoldersRegistered:
            return "on, but you have not added a project folder, so it reads nothing"
        case .noFolderMatched:
            return "on, and it could not tell which of your folders you are in"
        case .notPermitted(let folder):
            return "on, and macOS refused the read in \(folder)"
        case .noRepository(let folder):
            return "on, and there is no repository at the root of \(folder)"
        case .read(let folder, let length, let detached, _):
            return detached
                ? "read from \(folder): detached HEAD, so there is no branch to name"
                : "read from \(folder): a branch \(length) characters long, not printed here"
        }
    }

    private static func gitDetail(_ sensors: SensorStack) -> [String] {
        switch sensors.git.lastOutcome {
        case .optedOut, .skipped:
            return []
        case .noFoldersRegistered:
            return ["Settings > Signals has the button. The folder you pick there is", "also the grant: nothing else can be opened."]
        case .noFolderMatched(let reason):
            return [reason, "Reported as unknown, never as no branch."]
        case .notPermitted:
            return [
                "Files and Folders. A repository under ~/Desktop, ~/Documents or",
                "~/Downloads is behind that service. This is NOT the same as there",
                "being no repository, and the app does not report it as one.",
            ]
        case .noRepository:
            return ["Register the repository root, not a directory inside it."]
        case .read(_, _, _, let route):
            return [
                "Which folder was decided by \(route).",
                "Settings > Signals shows the name on this machine.",
            ]
        }
    }

    /// Rendered from `ToolAllowlist.undetectable` rather than retyped, so the list a user
    /// reads here cannot drift from the list the collector actually skips.
    private static var undetectableTools: [String] {
        let names = ToolAllowlist.undetectable.map(\.displayName)
        return stride(from: 0, to: names.count, by: 5).map {
            names[$0..<min($0 + 5, names.count)].joined(separator: ", ")
        }
    }

    /// The honest list. Every row here is something the app could plausibly be expected to
    /// know and does not, with the reason it does not.
    private static func unavailableSection(_ raw: RawSignals) -> [String] {
        [
            "UNAVAILABLE, AND WHY",
            "  keystroke rate       Would need Input Monitoring. Declined on principle, the app",
            "                       reports WHEN input happened, never WHAT was typed. The engine",
            "                       therefore never defers for a typing burst. It never fires extra.",
            "  browser URL / host   There is no permission-free way to read it. The only routes are",
            "                       Apple Events (an Automation grant) and Screen Recording, both",
            "                       declined. The opt-in exists; the collector does not, so the",
            "                       field is nil rather than faked.",
            "  argv-shaped tools    These are named by their ARGUMENTS, not by their own",
            "                       executables, and a shebang script called jest is `node` to",
            "                       the kernel. Reading arguments means reading command lines,",
            "                       which is where passwords are, so they are not detected at",
            "                       all. Everything else on the allowlist is, so DEBUGGING is",
            "                       reachable and TESTING keeps only xctest. Not detected:",
        ]
            + undetectableTools.map { "                         \($0)" }
            + [
            "  uncommitted changes  Nothing in .git/HEAD answers it, and answering it properly",
            "                       means reading the index and the working tree, which is the",
            "                       repository's contents. The hasUncommittedChanges fact stays",
            "                       unset, so the templates that need it stay unselectable",
            "                       rather than being fed a guess.",
            "  calendar             EventKit is declined outright. Reading it would mean every event",
            "                       title, attendee and location to answer one yes/no question.",
            "  screen being shared  No permission-free signal, and this is the weaker claim: I",
            "                       looked and did not find one. CGDisplayIsCaptured, which the",
            "                       design doc used to name, has been deprecated since macOS 10.9",
            "                       and no longer compiles. CoreMediaIO enumerates no capture",
            "                       device. ScreenCaptureKit needs the Screen Recording grant,",
            "                       which this app does not request. CONSEQUENCE, said plainly:",
            "                       the screenBeingShared hard block never fires. If you are",
            "                       presenting, use \"I'm in a meeting\" in the menu.",
            "  a call you never     If you joined muted with the camera off and never unmuted, no",
            "  spoke in             capture fact ever happened and the latch cannot open. Nothing",
            "                       at Tier 0 tells that apart from a Meet tab you forgot to",
            "                       close. Use the menu.",
            "  Google Meet in       Safari attributes page audio to com.apple.WebKit.GPU, which",
            "  Safari               serves every WebKit client and so names no app. The latch can",
            "                       still open from the unattributed device bit, but it cannot say",
            "                       which app and gets the shorter hold. Meet in Chrome, Arc or",
            "                       Brave is attributed properly.",
            "  Focus mode           No public API. Passed to the engine as nil, which the policy",
            "                       distinguishes from false, rather than assumed off.",
            "  battery percentage   Not read. Charging state is, and it is permission-free.",
            "  window geometry      \(raw.frontmost.runningBundleIDs.isEmpty ? "unknown" : "counts and a fullscreen hint only; window NAMES are")",
            "                       omitted by macOS without Screen Recording, and are not wanted.",
            "",
        ]
    }

    /// "Why has it not prompted me", answered without anyone reading JSON.
    ///
    /// This section exists because that question had no answer. The owner watched a panel
    /// read RUNNING for eighteen minutes against a five minute interval; the real cause,
    /// a dismissed prompt that re-armed the engine twenty minutes late, was recoverable
    /// only by noticing that the gap between two cycles was exactly `rearmAfterSkip` minus
    /// the work interval. A `--doctor` that cannot answer the app's own central question
    /// is not doing the job §4.1 gives it.
    ///
    /// It reads the log rather than the running engine, because `--doctor` is a separate
    /// process from the menu bar app and pretending otherwise would be the same class of
    /// lie the rest of this file exists to avoid.
    private static func outlookSection(settings: SigstopSettings) -> [String] {
        var out = ["WHY IT HAS NOT PROMPTED YOU"]
        let policy = BreakPolicy(settings: settings)
        guard
            let store = try? FileEventStore(root: AppPaths.storageRoot),
            let events = try? loadToday(store: store, policy: policy)
        else {
            out.append("  The event log could not be read, so this cannot be answered honestly.")
            out.append("")
            return out
        }

        let outlook = PromptOutlook.read(
            events: events, now: Date(), policy: policy, calendar: .current
        )
        out.append("  \(outlook.headline)")
        for line in outlook.detail { out.append("    \(line)") }
        out.append("")
        out.append("  Read from \(AppPaths.storageRoot.path)/events, not from the running app:")
        out.append("  --doctor is a separate process and cannot see the menu bar app's state.")
        out.append("")
        return out
    }

    /// A logical day straddles up to three UTC files, so all three are read and merged.
    private static func loadToday(store: FileEventStore, policy: BreakPolicy) throws -> [LoggedEvent] {
        let today = CalendarDay.local(
            of: Date(), calendar: .current, boundaryHour: policy.dayBoundaryHour
        )
        return [today.adding(days: -1), today, today.adding(days: 1)]
            .flatMap { (try? store.load(day: $0).events) ?? [] }
            .sorted { $0.at < $1.at }
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
            out.append("  days on disk     nothing stored yet, the app has not run here")
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

    private static func cameraText(_ state: CameraInputState) -> String {
        switch state {
        case .running:        return "a camera IS running, treated as a possible call"
        case .notRunning:     return "no camera device is running"
        case .noCameraDevice: return "this Mac has no camera device, or none could be read"
        case .unreliable:     return "DISABLED on this Mac, the signal never turns off"
        }
    }

    private static func audioText(_ state: AudioInputState) -> String {
        switch state {
        case .running:      return "an input device IS running, treated as a possible call"
        case .notRunning:   return "no input device is running"
        case .noInputDevice: return "this Mac has no audio input device"
        case .unreliable:   return "DISABLED on this Mac, the signal never turns off"
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
        case .serious:  return "serious, the app sheds load"
        case .critical: return "critical, the app sheds load"
        }
    }
}
