import AppKit
import ServiceManagement
import SigstopCore
import SigstopSensors
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    static let size = CGSize(width: 800, height: 620)

    @State private var pane: Pane
    @State private var launchAtLoginFailure: String?
    @State private var dataReport: String?

    init(model: AppModel, initialPane: Pane = .rhythm) {
        self.model = model
        _pane = State(initialValue: initialPane)
    }

    enum Pane: String, CaseIterable, Identifiable {
        case rhythm, voice, badges, access, data, about

        var id: String { rawValue }
        var title: String { rawValue.capitalized }

        var lede: String {
            switch self {
            case .rhythm: return "When a break is due, how long it lasts, and when the app should keep quiet."
            case .voice: return "How hard the app is allowed to hit. A ceiling you set, never a floor it raises."
            case .badges: return "Ten marks. Every one of them is for taking the break or for not needing it, and none of them is a streak."
            case .access: return "What the app can see right now, what each thing costs you, and the switches that widen it."
            case .data: return "Everything the app keeps lives in one folder you can read with cat."
            case .about: return ""
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(Brand.line).frame(width: 1)
                content
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Brand.bg)
    }

    private var settings: Binding<SigstopSettings> {
        Binding(get: { model.settings }, set: { model.update(settings: $0) })
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                BrandMark(size: 16, fill: 0.5)
                Text("sigstop")
                    .font(Brand.mono(13, weight: .semibold))
                    .foregroundStyle(Brand.fg)
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 24)

            ForEach(Pane.allCases) { item in
                NavRow(item.title, selected: pane == item) { pane = item }
            }

            Spacer(minLength: 0)
        }
        .frame(width: 176)
        .frame(maxHeight: .infinity)
        .background(Brand.surface)
    }

    private var content: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if pane == .about {
                    identity
                } else {
                    Text(pane.title)
                        .font(Brand.mono(22, weight: .bold))
                        .tracking(-0.6)
                        .foregroundStyle(Brand.fg)
                    Text(pane.lede)
                        .font(Brand.sans(12.5))
                        .foregroundStyle(Brand.fgMuted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }

                Group {
                    switch pane {
                    case .rhythm: rhythm
                    case .voice: voice
                    case .badges: badges
                    case .access: access
                    case .data: data
                    case .about: about
                    }
                }
                .padding(.top, 28)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rhythm: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("interval") {
                SettingRow(
                    "Work interval",
                    detail: "Continuous active work before a break is due. Reading a diff counts; "
                        + "the twenty minutes you spent in the kitchen does not."
                ) {
                    TerminalStepper(value: settings.workIntervalMinutes, range: 5...240, step: 5, unit: "min")
                }
                SettingRow("Break length", detail: "How long the process stays stopped before SIGCONT.") {
                    TerminalStepper(value: settings.breakDurationMinutes, range: 1...60, unit: "min")
                }
            }

            SettingsSection("quiet hours") {
                SettingRow(
                    "Stay quiet on a schedule",
                    detail: "Inside the window the app still measures, still counts the break "
                        + "opportunity, and says nothing. Suppressed opportunities are excluded "
                        + "from compliance rather than counted as misses."
                ) {
                    TerminalSwitch(isOn: settings.quietHours.enabled)
                }
                SettingRow("Window", detail: "24-hour clock, local time. Wraps past midnight.") {
                    HStack(spacing: 8) {
                        TimeField(minutes: settings.quietHours.startMinute, enabled: model.settings.quietHours.enabled)
                        Text("→")
                            .font(Brand.mono(11))
                            .foregroundStyle(Brand.fgFaint)
                        TimeField(minutes: settings.quietHours.endMinute, enabled: model.settings.quietHours.enabled)
                    }
                }
            }

            SettingsSection("prompt") {
                SettingRow(
                    "Play a sound",
                    detail: "Tink at SIGTSTP, Morse at SIGINT, Submarine at SIGTERM, Sosumi at SIGSTOP. The escalation is carried by volume. Silent while a microphone or camera is on, so it never lands in a call or a recording."
                ) {
                    TerminalSwitch(isOn: settings.promptSound)
                }
                SettingRow(
                    "Use macOS notifications instead",
                    detail: "Off by default. An unsigned build reports the notification as delivered and macOS never draws it, so the app draws its own."
                ) {
                    TerminalSwitch(isOn: settings.useSystemNotifications)
                }
            }

            SettingsSection("budget") {
                SettingRow("Most prompts in a day", detail: capDetail) {
                    TerminalStepper(value: settings.maxNotificationsPerDay, range: 1...60, unit: "max")
                }
            }

            SettingsSection("break") {
                SettingRow("Show the full-screen overlay", detail: "Dimmed, not opaque. The work is still there.") {
                    TerminalSwitch(isOn: settings.showBreakOverlay)
                }
                SettingRow("Suggest something to do", detail: "A small, finishable nudge to leave the chair.") {
                    TerminalSwitch(isOn: settings.breakQuestsEnabled)
                }
                SettingRow(
                    "Hold my break during calls",
                    detail: "After a microphone or camera stops, hold the prompt for up to 20 minutes in case you only muted. Turning it off also ends an \"I'm in a meeting\" hold, and turning it back on restores the feature. A live microphone or camera still blocks on its own, except on a Mac whose audio signal the app cannot trust, where this switch is the only thing holding; --doctor says which one this is."
                ) {
                    TerminalSwitch(isOn: settings.holdBreaksDuringCalls)
                }
            }

            SettingsSection("system") {
                SettingRow(
                    "Appearance",
                    detail: "The app's own windows. The menu bar mark always matches the menu bar."
                ) {
                    TerminalSegmented(
                        selection: appearance,
                        options: AppearancePreference.allCases.map { ($0, $0.displayName) }
                    )
                }
                SettingRow("Show in the Dock", detail: "Menu bar only by default; some people want the app where they look for apps.") {
                    TerminalSwitch(isOn: settings.showInDock)
                }
                SettingRow("Launch at login", detail: launchAtLoginFailure) {
                    TerminalSwitch(isOn: launchAtLogin)
                }
            }
        }
    }

    private var capDetail: String {
        let effective = model.policy.dailyNotificationCap
        let chosen = model.settings.maxNotificationsPerDay
        let each = model.settings.workIntervalMinutes + model.settings.breakDurationMinutes
        let hours = Double(effective * each) / 60
        let covers = String(format: hours >= 10 ? "%.0f" : "%.1f", hours)
        if effective > chosen {
            return "You set \(chosen). At a \(model.settings.workIntervalMinutes)-minute interval "
                + "that is spent before lunch, so it is raised to \(effective), about \(covers) hours of work. "
                + "To be interrupted less, raise the interval."
        }
        return "About \(covers) hours of work at the current interval. After that the app goes quiet until 4am."
    }

    private var appearance: Binding<AppearancePreference> {
        Binding(
            get: { model.settings.appearance },
            set: { choice in
                var updated = model.settings
                updated.appearance = choice
                model.update(settings: updated)
            }
        )
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { AppPaths.isBundled ? SMAppService.mainApp.status == .enabled : model.settings.launchAtLogin },
            set: { wanted in
                guard AppPaths.isBundled else {
                    launchAtLoginFailure =
                        "Launching at login needs the bundled app, build it with `make bundle`."
                    return
                }
                do {
                    if wanted {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    launchAtLoginFailure = nil
                    var updated = model.settings
                    updated.launchAtLogin = wanted
                    model.update(settings: updated)
                } catch {
                    launchAtLoginFailure = "macOS refused, \(error.localizedDescription)"
                }
            }
        )
    }

    private var voice: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("tone") {
                HStack(spacing: 8) {
                    ForEach(Tone.allCases, id: \.self) { tone in
                        ToneCard(tone: tone, selected: model.settings.tone == tone) {
                            var updated = model.settings
                            updated.tone = tone
                            model.update(settings: updated)
                        }
                    }
                }
                .padding(.top, 14)

                Text(model.settings.tone.blurb)
                    .font(Brand.sans(14))
                    .foregroundStyle(Brand.fg)
                    .padding(.top, 16)

                Note(
                    "Your choice is a ceiling, never a floor. The rails apply at every tier: "
                        + "never about appearance, competence, or your job. NUCLEAR is theatrical, "
                        + "not cruel."
                )
            }

            SettingsSection("escalation") {
                Note(
                    "If a prompt is ignored the ladder climbs one signal per rung, SIGTSTP, SIGINT, "
                        + "SIGTERM, then SIGSTOP, ordered by how easy each is to ignore. It stops "
                        + "there. There is no SIGKILL, because SIGKILL destroys the exact thing this "
                        + "app promises to keep."
                )
            }
        }
    }

    private var badges: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(earnedKicker) {
                ForEach(Badge.all) { badge in
                    BadgeRow(
                        badge: badge,
                        earned: model.badges.date(for: badge.id),
                        progress: badge.progress(model.badgeEvidence)
                    )
                }
            }

            Note(
                "Nothing here rewards working longer, because the app exists to interrupt "
                    + "long stretches and paying you for one would have it arguing with "
                    + "itself. yielded is the clearest case: it is for a full day where "
                    + "nothing ran past the hour."
            )
            Note(
                "There is no streak. Nothing expires, missing a day costs nothing, and none "
                    + "of these can go down once it has happened. Every one is counted from "
                    + "the log already on disk; no new tracking was added for them."
            )
        }
        .onAppear { model.acknowledgeBadges() }
    }

    private var earnedKicker: String {
        "\(model.badges.count) of \(Badge.all.count) earned"
    }

    private var access: some View {
        let status = model.permissionStatus
        return VStack(alignment: .leading, spacing: 0) {
            SettingsSection(PermissionStatus.Cost.alwaysOn.label) {
                signalRow(status[.osFacts]) { EmptyView() }
            }

            SettingsSection(PermissionStatus.Cost.needsAccessibility.label) {
                Note(
                    "macOS cannot limit this permission to window titles. Granting it means "
                        + "trusting this code, not the operating system. And until sigstop is signed "
                        + "with an Apple Developer ID, anything already running as you could borrow "
                        + "the grant by running a modified copy of the app. The app works without "
                        + "it; only the two rows below want it."
                )
                SignalRow(
                    "Accessibility",
                    reads: "The grant. The app never shows the macOS alert itself; "
                        + "the button opens the switch.",
                    state: StateLabel(granted: status.accessibilityTrusted)
                ) {
                    HStack(spacing: 6) {
                        TerminalButton("Re-check") { model.refreshPermissions() }
                            .fixedSize()
                        TerminalButton("Open System Settings") { model.openAccessibilitySettings() }
                            .fixedSize()
                    }
                }
                signalRow(status[.windowTitles]) {
                    TerminalSwitch(isOn: settings.accessibilityEnabled)
                }
                signalRow(status[.browserHost]) {
                    TerminalSwitch(
                        isOn: settings.browserHostEnabled,
                        enabled: model.settings.accessibilityEnabled
                    )
                }
            }

            SettingsSection(PermissionStatus.Cost.offByDefault.label) {
                Note(
                    "No permission is involved. Two switches, because they read different "
                        + "things and agreeing to one is not agreeing to the other."
                )
                signalRow(status[.branchName], extra: { branchReading }) {
                    TerminalSwitch(isOn: settings.gitContextEnabled)
                }
                SignalRow(
                    "Project folders",
                    reads: "The whole of what the branch reader may open. Pick the root of a "
                        + "repository; the folder you choose is the grant.",
                    state: StateLabel(count: model.settings.projectFolders.count),
                    extra: { folderList }
                ) {
                    TerminalButton("Add project folder…") { addFolder() }
                        .fixedSize()
                }
                signalRow(status[.toolNames]) {
                    TerminalSwitch(isOn: settings.processContextEnabled)
                }
            }

            SettingsSection("cannot see") {
                SignalRow(
                    "Screen sharing",
                    reads: "No permission-free signal exists, so it is reported as unknown, "
                        + "never as no. When presenting, use \u{201C}I'm in a meeting\u{201D} in the menu.",
                    state: StateLabel(dot: .off, text: "unknown")
                ) {
                    EmptyView()
                }
                Note(
                    "Never requested: Screen Recording, Input Monitoring, Full Disk Access, "
                        + "Automation, Calendar, Contacts, Microphone, Camera, Location. Their "
                        + "usage strings are absent from Info.plist, so an attempt would crash "
                        + "the app rather than prompt you."
                )
            }

            SettingsSection("check it") {
                (Text("sigstop --doctor").font(Brand.mono(11))
                    + Text(" prints every row on this page with the macOS call behind it.")
                        .font(Brand.sans(11)))
                    .foregroundStyle(Brand.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                VStack(alignment: .leading, spacing: 0) {
                    LinkRow(
                        "The full inventory",
                        "docs/PRIVACY.md: every datum, the API that produces it, where it goes and for how long",
                        Links.privacy
                    )
                    LinkRow(
                        "The one file that reads a window",
                        "two attributes, one private reader, and the function that keeps only the host",
                        Links.collector
                    )
                }
                .padding(.top, 8)
            }
        }
        .onAppear { model.refreshPermissions() }
    }

    private func signalRow<Control: View, Extra: View>(
        _ signal: PermissionStatus.Signal,
        @ViewBuilder extra: () -> Extra,
        @ViewBuilder control: () -> Control
    ) -> some View {
        SignalRow(
            Self.title(for: signal),
            reads: signal.reads,
            state: StateLabel(signal.state),
            extra: extra,
            control: control
        )
    }

    private func signalRow<Control: View>(
        _ signal: PermissionStatus.Signal,
        @ViewBuilder control: () -> Control
    ) -> some View {
        signalRow(signal, extra: { EmptyView() }, control: control)
    }

    private static func title(for signal: PermissionStatus.Signal) -> String {
        signal.name.prefix(1).uppercased() + signal.name.dropFirst()
    }

    @ViewBuilder
    private var branchReading: some View {
        if model.settings.gitContextEnabled {
            if let reading = model.gitReading {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Kicker("read")
                        Text(reading.branchText)
                            .font(Brand.mono(11))
                            .foregroundStyle(Brand.fg)
                            .textSelection(.enabled)
                        if let state = reading.stateText {
                            Text(state)
                                .font(Brand.mono(11))
                                .foregroundStyle(Brand.fgMuted)
                        }
                    }
                    Text("in \(reading.folder), matched by \(reading.route)")
                        .font(Brand.mono(10.5))
                        .foregroundStyle(Brand.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Kicker("read")
                    Text(Self.gitOutcome(model.gitStatusLine))
                        .font(Brand.mono(10.5))
                        .foregroundStyle(Brand.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
        }
    }

    private static func gitOutcome(_ line: String) -> String {
        line == "off, nothing is read" ? "not sampled yet" : line
    }

    @ViewBuilder
    private var folderList: some View {
        if !model.settings.projectFolders.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.settings.projectFolders, id: \.self) { folder in
                    HStack(spacing: 10) {
                        Text((folder as NSString).lastPathComponent)
                            .font(Brand.mono(11))
                            .foregroundStyle(Brand.fg)
                            .help(folder)
                        TerminalButton("Remove") { removeFolder(folder) }
                            .fixedSize()
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private var data: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("where it lives") {
                Note(
                    "Plain JSON, nothing encoded. Raw events are kept for "
                        + "\(Retention.defaultEventDays) days. Daily summaries, which hold the seconds "
                        + "spent in each app, stay until you delete them."
                )
                CodeBlock(AppPaths.storageRoot.path)
                    .padding(.top, 10)
                VStack(alignment: .leading, spacing: 5) {
                    FileRow("events/", "one file per day, appended, never rewritten")
                    FileRow("summaries/", "one object per day: seconds per app and per activity, break counts, kept until you delete them")
                    FileRow("badges.json", "which of the ten unlocked, and when")
                    FileRow("counters.json", "today's budgets: prompts delivered, cycles unanswered, the compliance tally")
                    FileRow("call-hold.json", "seconds a call has held a break today; exists once one has")
                    FileRow("settings.json", "exactly what the panes above set")
                    FileRow(".lock", "empty; held while sigstop runs, so a second copy leaves")
                }
                .padding(.top, 12)
            }

            SettingsSection("export") {
                Note(
                    "The event log as one text file, a copy rather than a report. Nothing is "
                        + "filtered or transformed, so what you audit is what the app recorded."
                )
                TerminalButton("Export…") { export() }
                    .fixedSize()
                    .padding(.top, 12)
            }

            SettingsSection("delete") {
                Note(
                    "Removes everything in the folder above except its empty .lock: the event log, "
                        + "the summaries, the badges, the day's counters, the call hold's total for "
                        + "today and these settings. There is no archive, "
                        + "no tombstone and no copy kept anywhere, which is the point and also means "
                        + "there is no undo."
                )
                TerminalButton("Delete my data…") { confirmDelete() }
                    .fixedSize()
                    .padding(.top, 12)
                if let dataReport {
                    CodeBlock(dataReport)
                        .padding(.top, 12)
                }
            }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Pick the root of a repository. sigstop reads the first line of a few of "
            + "git's own files: HEAD, the .git file of a worktree or submodule, and during a "
            + "rebase the branch name. It never opens a file of yours."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var updated = model.settings
        let path = url.standardizedFileURL.path
        guard !updated.projectFolders.contains(path), updated.projectFolders.count < 32 else { return }
        updated.projectFolders.append(path)
        model.update(settings: updated)
    }

    private func removeFolder(_ folder: String) {
        var updated = model.settings
        updated.projectFolders.removeAll { $0 == folder }
        model.update(settings: updated)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "sigstop-export.txt"
        panel.canCreateDirectories = true
        panel.message = "The event log as one readable file, every line on disk, unchanged."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dataReport = model.exportData(to: url)
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete everything sigstop has stored?"
        alert.informativeText =
            "This removes everything in the folder sigstop keeps its data in: the event "
            + "log, the daily summaries, the badges, the day's counters, the call hold's total "
            + "for today and your settings. "
            + "Only its empty .lock stays, because sigstop is still running. "
            + "There is no archive, no tombstone and no copy kept anywhere."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        dataReport = model.deleteEverything()
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        switch (v, b) {
        case let (v?, b?): return "\(v) (\(b))"
        case let (v?, nil): return v
        default: return "development build"
        }
    }

    private var releaseName: String? {
        Bundle.main.infoDictionary?["SGReleaseName"] as? String
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: 18) {
            BrandMark(size: 48, fill: 0.5)
            VStack(alignment: .leading, spacing: 5) {
                Text("sigstop")
                    .font(Brand.mono(22, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Brand.fg)
                if releaseName != nil {
                    Text(version)
                        .font(Brand.mono(10.5))
                        .foregroundStyle(Brand.fgFaint)
                        .textSelection(.enabled)
                }
                Text("\(releaseName ?? version) · GPL-3.0 · macOS 14+ · swift 6")
                    .font(Brand.mono(10.5))
                    .foregroundStyle(Brand.fgMuted)
                    .textSelection(.enabled)
                Text("A stopped process keeps everything and continues at the exact instruction.")
                    .font(Brand.sans(12.5))
                    .foregroundStyle(Brand.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                madeBy
            }
            Spacer(minLength: 0)
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 0) {
            updates
            links
            builtOn
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var links: some View {
        SettingsSection("links") {
            VStack(alignment: .leading, spacing: 0) {
                LinkRow("Source on GitHub", "every line of this, including the parts that are wrong", Links.repo)
                LinkRow("Architecture docs", "why it decides what it decides, written before the code", Links.docs)
                LinkRow("What it collects", "the full inventory, and the one thing that leaves the machine", Links.privacy)
                LinkRow("Report a bug", "run the doctor first, it prints everything this app can see", Links.issues)
            }
            .padding(.top, 12)
        }
    }

    private var builtOn: some View {
        SettingsSection("built on") {
            VStack(alignment: .leading, spacing: 10) {
                CreditRow(
                    "Sparkle 2.10.0",
                    "The only third-party code in the app, and the only thing in it that can "
                        + "open a socket. It refuses any update whose signature does not verify "
                        + "against a key compiled into this binary."
                )
                CreditRow(
                    "JetBrains Mono",
                    "Used if you already have it. Nothing is downloaded and no font is bundled: "
                        + "without it this falls back to the system monospace."
                )
            }
            .padding(.top, 12)
        }
    }

    private var madeBy: some View {
        HStack(spacing: 5) {
            Text("Made with")
            Text("\u{1FAF6}")
                .font(.system(size: 11))
            Text("by")
            Text("Mohamed Elshesheny")
                .foregroundStyle(Brand.fgMuted)
        }
        .font(Brand.mono(10.5))
        .foregroundStyle(Brand.fgFaint)
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Made with love by Mohamed Elshesheny")
    }

    @ViewBuilder
    private var updates: some View {
        let updater = model.updates

        SettingsSection("updates") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StateDot(state: Self.dot(for: updater.state))
                    Text(Self.statusLine(for: updater.state))
                        .font(Brand.mono(11))
                        .foregroundStyle(Self.isError(updater.state) ? Brand.fg : Brand.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if case .downloading(let received, let expected) = updater.state, expected > 0 {
                        Text(Self.bytes(received, of: expected))
                            .font(Brand.mono(10))
                            .foregroundStyle(Brand.fgMuted)
                            .monospacedDigit()
                    }
                }

                if updater.state.isBusy {
                    TransferBar(fraction: transferFraction(updater.state))
                }

                HStack(spacing: 6) {
                    switch updater.state {
                    case .available:
                        TerminalButton("Download", style: .filled) { updater.proceed() }.fixedSize()
                        TerminalButton("Not now") { updater.dismiss() }.fixedSize()
                    case .downloaded:
                        TerminalButton("Install", style: .filled) { updater.proceed() }.fixedSize()
                        TerminalButton("Later") { updater.dismiss() }.fixedSize()
                    case .readyToInstall:
                        TerminalButton("Install and restart", style: .filled) { updater.proceed() }.fixedSize()
                        TerminalButton("Later") { updater.dismiss() }.fixedSize()
                    case .informational(_, let link):
                        TerminalButton("Open releases in browser") {
                            NSWorkspace.shared.open(link ?? Links.releases)
                        }
                        .fixedSize()
                        TerminalButton("Check for updates", enabled: updater.canCheck) {
                            updater.checkForUpdates()
                        }
                        .fixedSize()
                    case .downloading, .checking:
                        TerminalButton("Cancel") { updater.dismiss() }.fixedSize()
                    case .extracting:
                        TerminalButton("Working…", enabled: false) {}.fixedSize()
                    case .installing:
                        TerminalButton("Working…", enabled: false) {}.fixedSize()
                        TerminalButton("Try again") { updater.retryInstalling() }.fixedSize()
                    case .unavailable:
                        TerminalButton("Open releases in browser") {
                            NSWorkspace.shared.open(Links.releases)
                        }
                        .fixedSize()
                    default:
                        TerminalButton("Check for updates", enabled: updater.canCheck) {
                            updater.checkForUpdates()
                        }
                        .fixedSize()
                    }
                }
            }
            .padding(.top, 12)
        }
    }

    private func transferFraction(_ state: UpdateChecker.State) -> Double? {
        switch state {
        case .downloading: return state.downloadFraction
        case .extracting(let fraction): return fraction
        default: return nil
        }
    }

    private static func isError(_ state: UpdateChecker.State) -> Bool {
        switch state {
        case .failed, .unavailable: return true
        default: return false
        }
    }

    private static func dot(for state: UpdateChecker.State) -> StateDot.State {
        switch state {
        case .available, .downloaded, .informational, .readyToInstall, .checking, .downloading, .extracting, .installing:
            return .suspend
        case .upToDate:
            return .running
        default:
            return .off
        }
    }

    private static func statusLine(for state: UpdateChecker.State) -> String {
        switch state {
        case .idle:
            return "Nothing has been checked yet."
        case .checking:
            return "Asking the feed…"
        case .upToDate(let current):
            return "\(current) is the latest version."
        case .available(let version):
            return "\(version) is available."
        case .downloading:
            return "Downloading…"
        case .extracting:
            return "Checking the signature, then unpacking…"
        case .downloaded(let version):
            return "\(version) is downloaded. Installing checks its signature first."
        case .informational(let version, _):
            return "\(version) is available but installs by hand."
        case .readyToInstall(let version):
            return "\(version) is verified and ready."
        case .installing:
            return "Installing. sigstop will restart itself."
        case .failed(let message):
            return message
        case .unavailable(let reason):
            return reason
        }
    }

    private static func bytes(_ received: Int64, of expected: Int64) -> String {
        func mb(_ value: Int64) -> String {
            String(format: "%.1f", Double(value) / 1_048_576)
        }
        return "\(mb(received)) of \(mb(expected)) MB"
    }

    private enum Links {
        static let repo = URL(string: "https://github.com/Mohamed-Elshesheny/sigstop")!
        static let releases = URL(string: "https://github.com/Mohamed-Elshesheny/sigstop/releases")!
        static let privacy = URL(
            string: "https://github.com/Mohamed-Elshesheny/sigstop/blob/main/docs/PRIVACY.md")!
        static let docs = URL(
            string: "https://github.com/Mohamed-Elshesheny/sigstop/tree/main/docs")!
        static let issues = URL(
            string: "https://github.com/Mohamed-Elshesheny/sigstop/issues/new/choose")!
        static let collector = URL(
            string: "https://github.com/Mohamed-Elshesheny/sigstop/blob/main/app/Sources/"
                + "SigstopSensors/Collectors/AccessibilityCollector.swift")!
    }
}

private struct NavRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(selected ? Brand.amberFill : Color.clear)
                    .frame(width: 2)
                Text(title)
                    .font(Brand.mono(12, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Brand.fg : Brand.fgMuted)
                    .padding(.leading, 16)
                Spacer(minLength: 0)
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            .background(selected || hovering ? Brand.surfaceHi : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct LinkRow: View {
    let title: String
    let detail: String
    let url: URL

    @State private var hovering = false

    init(_ title: String, _ detail: String, _ url: URL) {
        self.title = title
        self.detail = detail
        self.url = url
    }

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Brand.mono(12, weight: .medium))
                        .foregroundStyle(hovering ? Brand.fg : Brand.fgMuted)
                    Text(detail)
                        .font(Brand.sans(11.5))
                        .foregroundStyle(Brand.fgFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text("\u{2197}")
                    .font(Brand.mono(11))
                    .foregroundStyle(hovering ? Brand.amber : Brand.fgFaint)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(hovering ? Brand.surfaceHi : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityHint(detail)
    }
}

private struct CreditRow: View {
    let name: String
    let role: String

    init(_ name: String, _ role: String) {
        self.name = name
        self.role = role
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(Brand.mono(11.5, weight: .medium))
                .foregroundStyle(Brand.fgMuted)
            Text(role)
                .font(Brand.sans(11.5))
                .foregroundStyle(Brand.fgFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FileRow: View {
    let name: String
    let role: String

    init(_ name: String, _ role: String) {
        self.name = name
        self.role = role
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name)
                .font(Brand.mono(11))
                .foregroundStyle(Brand.fgMuted)
                .frame(width: 112, alignment: .leading)
            Text(role)
                .font(Brand.sans(11.5))
                .foregroundStyle(Brand.fgFaint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let kicker: String
    let content: Content

    init(_ kicker: String, @ViewBuilder content: () -> Content) {
        self.kicker = kicker
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Kicker(kicker)
                .padding(.bottom, 8)
            Rule()
            content
        }
        .padding(.bottom, 28)
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    let detail: String?
    let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(Brand.sans(13))
                        .foregroundStyle(Brand.fg)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(Brand.sans(11))
                            .foregroundStyle(Brand.fgMuted)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 16)
                control
                    .padding(.top, 1)
                    .accessibilityLabel(title)
            }
            .padding(.vertical, 13)
            Rule()
        }
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Brand.sans(11))
            .foregroundStyle(Brand.fgMuted)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
    }
}

private struct CodeBlock: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Brand.mono(11))
            .foregroundStyle(Brand.fg)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Brand.line, lineWidth: 1)
            )
    }
}

struct BadgeRow: View {
    let badge: Badge
    let earned: CalendarDay?
    let progress: BadgeProgress?

    private var unlocked: Bool { earned != nil }

    private var trailing: String {
        if let earned { return earned.description }
        if let progress { return "\(progress.have) / \(progress.need)" }
        return "not yet"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                BadgeMark(motif: badge.motif, unlocked: unlocked, size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(badge.title)
                        .font(Brand.mono(12, weight: .medium))
                        .foregroundStyle(unlocked ? Brand.fg : Brand.fgMuted)
                    Text(unlocked ? badge.blurb : badge.lockedHint)
                        .font(Brand.sans(11))
                        .foregroundStyle(Brand.fgMuted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !unlocked, let progress, progress.have > 0 {
                        ProgressTrack(fraction: progress.fraction)
                            .padding(.top, 3)
                    }
                }
                Spacer(minLength: 16)
                Text(trailing)
                    .font(Brand.mono(10))
                    .foregroundStyle(unlocked ? Brand.fgMuted : Brand.fgFaint)
                    .monospacedDigit()
                    .padding(.top, 2)
            }
            .padding(.vertical, 13)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                unlocked
                    ? "\(badge.title), earned \(earned?.description ?? ""). \(badge.blurb)"
                    : progress.map {
                        "\(badge.title), \($0.have) of \($0.need). \(badge.lockedHint)"
                    } ?? "\(badge.title), not earned yet. \(badge.lockedHint)"
            )
            Rule()
        }
    }
}

private struct ProgressTrack: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.line)
                Capsule()
                    .fill(Brand.amber.opacity(0.55))
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 2)
        .frame(maxWidth: 190, alignment: .leading)
    }
}

private struct ToneCard: View {
    let tone: Tone
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tone.displayName.uppercased())
                    .font(Brand.mono(11, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(selected ? Brand.amber : Brand.fg)
                Text(gloss)
                    .font(Brand.mono(10))
                    .foregroundStyle(Brand.fgMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                selected ? Brand.amberFill.opacity(0.08) : (hovering ? Brand.surfaceHi : Brand.surface),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? Brand.amber.opacity(0.6) : (hovering ? Brand.lineHi : Brand.line), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var gloss: String {
        switch tone {
        case .friendly: return "polite"
        case .sarcastic: return "default"
        case .roast: return "you asked"
        case .nuclear: return "theatrical"
        }
    }
}

private struct SignalRow<Control: View, Extra: View>: View {
    let title: String
    let reads: String
    let state: StateLabel
    let extra: Extra
    let control: Control

    init(
        _ title: String,
        reads: String,
        state: StateLabel,
        @ViewBuilder extra: () -> Extra,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.reads = reads
        self.state = state
        self.extra = extra()
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(Brand.sans(13))
                        .foregroundStyle(Brand.fg)
                    Text(reads)
                        .font(Brand.sans(11))
                        .foregroundStyle(Brand.fgMuted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    extra
                }
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 8) {
                    state
                        .padding(.top, 2)
                    control
                }
            }
            .padding(.vertical, 13)
            Rule()
        }
    }
}

extension SignalRow where Extra == EmptyView {
    init(
        _ title: String,
        reads: String,
        state: StateLabel,
        @ViewBuilder control: () -> Control
    ) {
        self.init(title, reads: reads, state: state, extra: { EmptyView() }, control: control)
    }
}

private struct StateLabel: View {
    let dot: StateDot.State?
    let text: String

    init(dot: StateDot.State?, text: String) {
        self.dot = dot
        self.text = text
    }

    init(_ state: PermissionStatus.SignalState) {
        switch state {
        case .reading: self.init(dot: .running, text: "on")
        case .off: self.init(dot: .off, text: "off")
        case .held(let reason): self.init(dot: .off, text: "on \u{00B7} \(reason)")
        }
    }

    init(granted: Bool) {
        self.init(dot: granted ? .running : .off, text: granted ? "granted" : "not granted")
    }

    init(count: Int) {
        self.init(dot: nil, text: count == 0 ? "none yet" : "\(count) added")
    }

    var body: some View {
        HStack(spacing: 6) {
            if let dot {
                StateDot(state: dot)
            }
            Text(text)
                .font(Brand.mono(10.5))
                .foregroundStyle(Brand.fgMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("state: \(text)")
    }
}

private struct TimeField: View {
    @Binding var minutes: Int
    var enabled: Bool = true

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(Brand.mono(12, weight: .medium))
            .foregroundStyle(Brand.fg)
            .multilineTextAlignment(.center)
            .frame(width: 54, height: 24)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(focused ? Brand.amber : Brand.lineHi, lineWidth: 1)
            )
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onChange(of: minutes) { _, value in
                text = Format.minuteOfDay(value)
            }
            .onAppear { text = Format.minuteOfDay(minutes) }
            .opacity(enabled ? 1 : 0.4)
            .disabled(!enabled)
    }

    private func commit() {
        if let parsed = Self.parse(text) {
            minutes = parsed
        }
        text = Format.minuteOfDay(minutes)
    }

    static func parse(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let hour: Int?
        let minute: Int?
        if let colon = trimmed.firstIndex(of: ":") {
            hour = Int(trimmed[..<colon])
            minute = Int(trimmed[trimmed.index(after: colon)...])
        } else if trimmed.count > 2, trimmed.allSatisfy(\.isNumber) {
            hour = Int(trimmed.dropLast(2))
            minute = Int(trimmed.suffix(2))
        } else {
            hour = Int(trimmed)
            minute = 0
        }
        guard let hour, let minute, (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}
