import AppKit
import ServiceManagement
import SigstopCore
import SwiftUI

/// Settings, as a sidebar and a page rather than a `TabView` of `Form`s.
///
/// The previous version was five grouped forms behind a toolbar tab strip, and it looked
/// like a System Settings pane someone had wandered into: rounded grey cards, system-blue
/// switches, no hierarchy, 640 points of it. This is the same settings in the app's own
/// vocabulary, a monospaced nav on the left, one headline per page, sections marked by
/// a kicker and ruled rows, controls drawn in the palette. The window is wider so the
/// help text can sit beside its control instead of under it.
struct SettingsView: View {
    let model: AppModel

    /// The window's content size. `AppMain` sizes the `NSWindow` to match; the two
    /// numbers have to agree or the hosting view fights the frame.
    static let size = CGSize(width: 800, height: 620)

    @State private var pane: Pane
    @State private var launchAtLoginFailure: String?
    @State private var dataReport: String?

    /// `initialPane` is the page shown first. The window always opens on Rhythm; the
    /// parameter exists so a preview or a render check can start on any page.
    init(model: AppModel, initialPane: Pane = .rhythm) {
        self.model = model
        _pane = State(initialValue: initialPane)
    }

    enum Pane: String, CaseIterable, Identifiable {
        case rhythm, voice, badges, signals, data, about

        var id: String { rawValue }
        var title: String { rawValue.capitalized }

        var lede: String {
            switch self {
            case .rhythm: return "When a break is due, how long it lasts, and when the app should keep quiet."
            case .voice: return "How hard the app is allowed to hit. A ceiling you set, never a floor it raises."
            case .badges: return "Ten marks. Every one of them is for taking the break or for not needing it, and none of them is a streak."
            case .signals: return "What the app can see right now, tier by tier, and the two switches that widen it."
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
            if pane == .about { madeBy }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Brand.bg)
    }

    private var settings: Binding<SigstopSettings> {
        Binding(get: { model.settings }, set: { model.update(settings: $0) })
    }

    // MARK: Sidebar

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

            Text(version)
                .font(Brand.mono(10))
                .foregroundStyle(Brand.fgMuted)
                .padding(18)
        }
        .frame(width: 176)
        .frame(maxHeight: .infinity)
        .background(Brand.surface)
    }

    // MARK: Content

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
                    case .signals: signals
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

    // MARK: Rhythm

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
                    detail: "Tink at SIGTSTP, Morse at SIGINT, Submarine at SIGTERM, Sosumi at SIGSTOP. The escalation is carried by volume, quiet enough at the first rung to sit under a conversation."
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

            SettingsSection("break") {
                SettingRow("Show the full-screen overlay", detail: "Dimmed, not opaque. The work is still there.") {
                    TerminalSwitch(isOn: settings.showBreakOverlay)
                }
                SettingRow("Suggest something to do", detail: "A small, finishable nudge to leave the chair.") {
                    TerminalSwitch(isOn: settings.breakQuestsEnabled)
                }
                SettingRow(
                    "Hold my break during calls",
                    detail: "After a microphone or camera stops, hold the prompt for up to 20 minutes in case you only muted. Turning it off also ends an \"I'm in a meeting\" hold, and turning it back on restores the feature. A live microphone or camera still blocks on its own \u{2014} except on a Mac whose audio signal the app cannot trust, where this switch is the only thing holding; --doctor says which one this is."
                ) {
                    TerminalSwitch(isOn: settings.holdBreaksDuringCalls)
                }
            }

            SettingsSection("system") {
                SettingRow("Show in the Dock", detail: "Menu bar only by default; some people want the app where they look for apps.") {
                    TerminalSwitch(isOn: settings.showInDock)
                }
                SettingRow("Launch at login", detail: launchAtLoginFailure) {
                    TerminalSwitch(isOn: launchAtLogin)
                }
            }
        }
    }

    /// `SMAppService.mainApp`, which needs a real `.app` bundle. Run as a bare executable
    /// there is nothing for launchd to register, so the switch says so instead of failing
    /// silently.
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

    // MARK: Voice

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

    // MARK: Badges

    /// The ten, in catalogue order, unlocked and locked in the same list.
    ///
    /// One list rather than an "earned" section and a "locked" section: splitting them
    /// turns the locked half into a to-do list, and these are not tasks. The order never
    /// changes, so the pane looks the same on the first day as on the hundredth and the
    /// shapes read as the progression they are.
    private var badges: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(earnedKicker) {
                ForEach(Badge.all) { badge in
                    BadgeRow(badge: badge, earned: model.badges.date(for: badge.id))
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
                    + "the log already on disk — no new tracking was added for them."
            )
        }
        .onAppear { model.acknowledgeBadges() }
    }

    private var earnedKicker: String {
        "\(model.badges.count) of \(Badge.all.count) earned"
    }

    // MARK: Signals

    private var signals: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("visible now") {
                ForEach(Array(model.permissionStatus.explanation.enumerated()), id: \.offset) { _, line in
                    TierRow(line: line)
                }
            }

            SettingsSection("tier 1 · window titles") {
                SettingRow(
                    "Use window titles to tell a meeting from a terminal",
                    detail: "Titles are parsed inside one function and the raw string is discarded. "
                        + "Nothing about a title is ever written to disk, only whether one was "
                        + "legible at all."
                ) {
                    TerminalSwitch(isOn: settings.accessibilityEnabled)
                }
                SettingRow(
                    "Accessibility",
                    detail: "The button takes you to the switch. The app never raises the macOS "
                        + "permission alert on its own, not at launch, not from a timer, not when "
                        + "it decides you would get more out of it."
                ) {
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 6) {
                            StateDot(state: model.permissionStatus.accessibilityTrusted ? .running : .off)
                            Text(model.permissionStatus.accessibilityTrusted ? "granted" : "not granted")
                                .font(Brand.mono(11))
                                .foregroundStyle(Brand.fgMuted)
                        }
                        HStack(spacing: 6) {
                            TerminalButton("Re-check") { model.refreshPermissions() }
                                .fixedSize()
                            TerminalButton("Open System Settings") { model.openAccessibilitySettings() }
                                .fixedSize()
                        }
                    }
                }
            }

            SettingsSection("tier 2 · git context") {
                SettingRow(
                    "Read the branch name from .git/HEAD",
                    detail: "Off by default. The branch name only, read from the file, never a "
                        + "command, never a diff, never a commit message."
                ) {
                    TerminalSwitch(isOn: settings.gitContextEnabled)
                }
            }
        }
        .onAppear { model.refreshPermissions() }
    }

    // MARK: Data

    private var data: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("where it lives") {
                Note(
                    "One JSON object per line, in four files you can open with cat. Raw events "
                        + "are kept for \(Retention.defaultEventDays) days; daily summaries outlive "
                        + "them because they are a hundredth of the data."
                )
                CodeBlock(AppPaths.storageRoot.path)
                    .padding(.top, 10)
                VStack(alignment: .leading, spacing: 5) {
                    FileRow("events/", "one file per day, appended, never rewritten")
                    FileRow("summaries/", "one object per day, kept after the events age out")
                    FileRow("badges.json", "which of the ten unlocked, and when")
                    FileRow("settings.json", "exactly what the panes above set")
                }
                .padding(.top, 12)
            }

            SettingsSection("export") {
                Note(
                    "A copy, not a report. Nothing is filtered or transformed, so what you audit "
                        + "is what the app has."
                )
                TerminalButton("Export…") { export() }
                    .fixedSize()
                    .padding(.top, 12)
            }

            SettingsSection("delete") {
                Note(
                    "Removes the event log, the summaries, the badges and these settings. There "
                        + "is no archive, no tombstone and no copy kept anywhere, which is the "
                        + "point and also means there is no undo."
                )
                /// Boxed, while every other secondary control in this window is not.
                /// There is no undo behind this one, and a border is cheap next to the
                /// cost of it reading as the heading of the paragraph above it.
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

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "sigstop-export.txt"
        panel.canCreateDirectories = true
        panel.message = "Everything sigstop has on disk, as one readable file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dataReport = model.exportData(to: url)
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete everything sigstop has stored?"
        alert.informativeText =
            "This removes the event log, the daily summaries and your settings. "
            + "There is no archive, no tombstone and no copy kept anywhere."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        dataReport = model.deleteEverything()
    }

    // MARK: About

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        switch (v, b) {
        case let (v?, b?): return "\(v) (\(b))"
        case let (v?, nil): return v
        default: return "development build"
        }
    }

    /// The mark, the wordmark and one dense machine-shaped line instead of four labelled
    /// rows. Selectable, because the first thing anyone does with a version string is
    /// paste it into an issue.
    private var identity: some View {
        HStack(alignment: .top, spacing: 18) {
            BrandMark(size: 48, fill: 0.5)
            VStack(alignment: .leading, spacing: 5) {
                Text("sigstop")
                    .font(Brand.mono(22, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Brand.fg)
                Text("\(version) · Apache-2.0 · macOS 14+ · swift 6")
                    .font(Brand.mono(10.5))
                    .foregroundStyle(Brand.fgMuted)
                    .textSelection(.enabled)
                Text("A stopped process keeps everything and continues at the exact instruction.")
                    .font(Brand.sans(12.5))
                    .foregroundStyle(Brand.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
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

    /// The four places a curious or suspicious reader goes next.
    ///
    /// Two of these URLs were already defined and rendered nowhere, which is the shape of
    /// a pane that was built and never looked at: the constants existed, the page was two
    /// thirds empty, and nothing connected the two facts.
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

    /// Credit where the app is not its own work.
    ///
    /// Short, and specific about what each thing is doing here, because "acknowledgements"
    /// as a wall of names tells a reader nothing about what is running on their machine.
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

    /// The one piece of the interface that is not about the user.
    ///
    /// A bar across the bottom of the window, shown on About and nowhere else. It is
    /// outside the scroll view so it cannot drift up the page, and outside the pane so it
    /// spans the sidebar too rather than starting at the content margin. It sits on the raised
    /// surface under a hairline, which is the separation the sidebar already uses, so it
    /// reads as part of the window's chrome rather than as content. The heart is the only
    /// non-amber colour in the app and it is four millimetres wide, which is about the
    /// right amount of sentiment for a utility that otherwise refuses to be warm at you.
    ///
    /// The name is text and not a link on purpose. Linking it needs an account-root URL in
    /// the binary, and `verify.sh` allowlists only this repository, which is the narrower
    /// promise `docs/PRIVACY.md` makes: every URL in here goes to one known place.
    /// Widening that to the whole account so a byline could be clicked would be paying a
    /// real boundary for a small convenience.
    private var madeBy: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Brand.line).frame(height: 1)
            HStack(spacing: 6) {
                Text("Made with")
                Text("\u{1FAF6}")
                    .font(.system(size: 12))
                Text("by")
                Text("Mohamed Elshesheny")
                    .foregroundStyle(Brand.fgMuted)
            }
            .font(Brand.mono(11))
            .foregroundStyle(Brand.fgFaint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
        }
        .background(Brand.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Made with love by Mohamed Elshesheny")
    }

    /// One line that always says what is true right now, a bar underneath it only while
    /// bytes are actually moving, and the buttons that state allows.
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
                    case .readyToInstall:
                        TerminalButton("Install and restart", style: .filled) { updater.proceed() }.fixedSize()
                        TerminalButton("Later") { updater.dismiss() }.fixedSize()
                    case .downloading, .checking:
                        TerminalButton("Cancel") { updater.dismiss() }.fixedSize()
                    case .extracting, .installing:
                        TerminalButton("Working…", enabled: false) {}.fixedSize()
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

    /// Amber while something is happening or waiting for the user, off otherwise. The
    /// text beside it always says the same thing; the dot never carries meaning alone.
    private static func dot(for state: UpdateChecker.State) -> StateDot.State {
        switch state {
        case .available, .readyToInstall, .checking, .downloading, .extracting, .installing:
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
            return "Signature verified. Unpacking…"
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

    /// `1.2 of 4.8 MB`. Megabytes, not a percentage: a percentage of an unknown total is a
    /// number the app does not actually have.
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
    }
}

// MARK: - Navigation

/// A sidebar entry. The selected one gets a 2pt amber rail on the window's edge and the
/// primary text colour; the others are muted. No icons: five monospaced words are
/// scanned faster than five glyphs that have to be learned.
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

// MARK: - Page structure

/// A kicker, a rule, and rows. Sections are separated by air, not by cards.
/// One row in the About pane's link list: a label, a line saying what is on the other
/// side, and an arrow. The whole row is the target, not just the text.
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

/// A thing the app did not write, and what it is doing here.
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

/// One file in the storage root, and what is in it. A name in mono against a sentence in
/// prose, so the list scans as a directory listing rather than as more paragraphs.
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

/// Title and help on the left, the control on the right, a rule underneath. The help
/// text is set in the sans at 11pt so it reads as a sentence next to a monospaced value,
/// which is the same split the site makes between chrome and prose.
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
            }
            .padding(.vertical, 13)
            Rule()
        }
    }
}

/// A paragraph of help under a section, in the sans.
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

/// Monospaced text in a bordered block, selectable. Paths and reports.
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

/// One badge: the mark, its name, and one line that is either what it means or what it
/// takes. The date sits on the right in the same column the rest of the window puts its
/// values in.
///
/// A locked row is the same row — same height, same type, same position — with the
/// outline mark and its hint. Nothing is struck through, greyed to illegibility, or
/// marked with a symbol that could be read as a failure: a badge that has not happened
/// yet is not a problem, and the row must not imply it is one.
struct BadgeRow: View {
    let badge: Badge
    let earned: CalendarDay?

    private var unlocked: Bool { earned != nil }

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
                }
                Spacer(minLength: 16)
                Text(earned.map(\.description) ?? "not yet")
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
                    : "\(badge.title), not earned yet. \(badge.lockedHint)"
            )
            Rule()
        }
    }
}

// MARK: - Controls specific to this window

/// One tone, as the site's tone switch draws it: the name in small caps mono, a
/// two-word gloss under it, amber border and tint when selected.
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

/// One line of `PermissionStatus.explanation`, which the sensors layer writes as
/// `Tier N, what: ON/OFF, and why`. The tier is set in mono, the rest in the sans, and
/// the dot is green only when the line says the tier is on. The split is presentational:
/// a line without the dash is shown whole.
private struct TierRow: View {
    let line: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                StateDot(state: line.contains(": ON") ? .running : .off)
                Text(label)
                    .font(Brand.mono(11, weight: .medium))
                    .foregroundStyle(Brand.fg)
                    .frame(width: 58, alignment: .leading)
                Text(rest)
                    .font(Brand.sans(12))
                    .foregroundStyle(Brand.fgMuted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 10)
            Rule()
        }
    }

    private var split: (String, String) {
        guard let range = line.range(of: ", ") else { return ("", line) }
        return (String(line[..<range.lowerBound]), String(line[range.upperBound...]))
    }

    private var label: String { split.0 }
    private var rest: String { split.1 }
}

/// `HH:mm` typed, not picked.
///
/// Quiet hours are stored as minutes from local midnight, which is the only
/// representation that survives a time-zone change without moving. `DatePicker` wants a
/// `Date` and draws the system's control; a five-character monospaced field is both the
/// app's own grammar and faster for anyone who knows what time they stop working. The
/// text is parsed on commit and reverts to the stored value when it does not parse.
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

    /// Accepts `22:00`, `8:30`, `2200`, `830` and a bare hour.
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
