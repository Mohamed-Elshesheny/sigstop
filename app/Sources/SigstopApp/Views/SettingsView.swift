import AppKit
import ServiceManagement
import SigstopCore
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    @State private var launchAtLoginFailure: String?
    @State private var dataReport: String?

    var body: some View {
        TabView {
            rhythm.tabItem { Label("Rhythm", systemImage: "clock") }
            voice.tabItem { Label("Voice", systemImage: "text.bubble") }
            signals.tabItem { Label("Signals", systemImage: "antenna.radiowaves.left.and.right") }
            data.tabItem { Label("Data", systemImage: "externaldrive") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 640, height: 560)
    }

    private var settings: Binding<SigstopSettings> {
        Binding(get: { model.settings }, set: { model.update(settings: $0) })
    }


    // MARK: About

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        switch (v, b) {
        case let (v?, b?): return "\(v) (\(b))"
        case let (v?, nil): return v
        default:           return "development build"
        }
    }

    /// Deliberately not a `Form`.
    ///
    /// The previous version of this pane was `Form(.grouped)` with `LabeledContent` rows,
    /// and it looked like a System Settings panel someone had wandered into — rounded
    /// grey cards, system-blue buttons, generous air, no relationship to the product it
    /// was describing. This is the same information in the app's own vocabulary: the
    /// mark, a monospaced identity line, and an updater that shows what it is actually
    /// doing. The grammar is `MenuBarView`'s — 10 to 13pt, monospace for anything
    /// machine-shaped, rules instead of cards, amber as the only accent.
    private var about: some View {
        VStack(alignment: .leading, spacing: 0) {
            identity
            Rule()
            updates
            Rule()
            Spacer(minLength: 0)
            links
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: About — identity

    private var identity: some View {
        HStack(alignment: .top, spacing: 14) {
            BrandMark(size: 38, fill: 0.5)

            VStack(alignment: .leading, spacing: 3) {
                Text("sigstop")
                    .font(Brand.mono(19, weight: .semibold))
                // One dense machine-shaped line instead of four labelled rows. Selectable,
                // because the first thing anyone does with a version string is paste it
                // into an issue.
                Text("\(version) · Apache-2.0 · macOS 14+ · swift 6")
                    .font(Brand.mono(10))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("A stopped process keeps everything and continues at the exact instruction.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: About — the updater

    @ViewBuilder
    private var updates: some View {
        let updater = model.updates

        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("updates")

            // One line that always says what is true right now, and a bar underneath it
            // only while bytes are actually moving.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(state: updater.state)
                Text(Self.statusLine(for: updater.state))
                    .font(Brand.mono(11))
                    .foregroundStyle(Self.isError(updater.state) ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if case .downloading(let received, let expected) = updater.state, expected > 0 {
                    Text(Self.bytes(received, of: expected))
                        .font(Brand.mono(10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            if updater.state.isBusy {
                TransferBar(fraction: transferFraction(updater.state))
            }

            HStack(spacing: 6) {
                switch updater.state {
                case .available:
                    TerminalButton(title: "Download", prominent: true) { updater.proceed() }
                    TerminalButton(title: "Not now") { updater.dismiss() }
                case .readyToInstall:
                    TerminalButton(title: "Install and restart", prominent: true) { updater.proceed() }
                    TerminalButton(title: "Later") { updater.dismiss() }
                case .downloading, .checking:
                    TerminalButton(title: "Cancel") { updater.dismiss() }
                case .extracting, .installing:
                    TerminalButton(title: "Working…", enabled: false) {}
                case .unavailable:
                    TerminalButton(title: "Open releases in browser") {
                        NSWorkspace.shared.open(Links.releases)
                    }
                default:
                    TerminalButton(title: "Check for updates", prominent: true, enabled: updater.canCheck) {
                        updater.checkForUpdates()
                    }
                }
            }

            // The switch, off by default. Hidden when Sparkle cannot run at all, because
            // a switch that governs nothing is worse than no switch.
            if case .unavailable = updater.state {} else {
                Toggle(isOn: Binding(
                    get: { updater.automaticallyChecks },
                    set: { updater.automaticallyChecks = $0 }
                )) {
                    Text("Check once a day on its own")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .padding(.top, 2)
            }
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

    // MARK: About — links

    private var links: some View {
        HStack(spacing: 6) {
            TerminalButton(title: "Source") { NSWorkspace.shared.open(Links.repo) }
            TerminalButton(title: "Releases") { NSWorkspace.shared.open(Links.releases) }
            TerminalButton(title: "Privacy") { NSWorkspace.shared.open(Links.privacy) }
        }
        .padding(.top, 14)
    }

    private enum Links {
        static let repo = URL(string: "https://github.com/Mohamed-Elshesheny/sigstop")!
        static let releases = URL(string: "https://github.com/Mohamed-Elshesheny/sigstop/releases")!
        static let privacy = URL(
            string: "https://github.com/Mohamed-Elshesheny/sigstop/blob/main/docs/PRIVACY.md")!
    }

    // MARK: Rhythm

    private var rhythm: some View {
        Form {
            Section {
                Stepper(value: settings.workIntervalMinutes, in: 5...240, step: 5) {
                    LabeledContent("Work interval", value: "\(model.settings.workIntervalMinutes) min")
                }
                Stepper(value: settings.breakDurationMinutes, in: 1...60) {
                    LabeledContent("Break length", value: "\(model.settings.breakDurationMinutes) min")
                }
            } footer: {
                Text(
                    "The interval is continuous **active** work, not elapsed time. Reading a "
                        + "diff counts; the twenty minutes you spent in the kitchen does not."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Quiet hours") {
                Toggle("Stay quiet on a schedule", isOn: settings.quietHours.enabled)
                MinutePicker(title: "From", minutes: settings.quietHours.startMinute)
                    .disabled(!model.settings.quietHours.enabled)
                MinutePicker(title: "Until", minutes: settings.quietHours.endMinute)
                    .disabled(!model.settings.quietHours.enabled)
                Text(
                    "Inside quiet hours the app still measures, still counts the break "
                        + "opportunity, and says nothing. Suppressed opportunities are excluded "
                        + "from compliance rather than counted as misses."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Break") {
                Toggle("Show in the Dock", isOn: settings.showInDock)
                Toggle("Show the full-screen overlay", isOn: settings.showBreakOverlay)
                Toggle("Suggest something to do", isOn: settings.breakQuestsEnabled)
            }

            Section {
                Toggle("Launch at login", isOn: launchAtLogin)
                if let launchAtLoginFailure {
                    Text(launchAtLoginFailure).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// `SMAppService.mainApp`, which needs a real `.app` bundle. Run as a bare executable
    /// there is nothing for launchd to register, so the toggle says so instead of failing
    /// silently.
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { AppPaths.isBundled ? SMAppService.mainApp.status == .enabled : model.settings.launchAtLogin },
            set: { wanted in
                guard AppPaths.isBundled else {
                    launchAtLoginFailure =
                        "Launching at login needs the bundled app — build it with `make bundle`."
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
                    launchAtLoginFailure = "macOS refused — \(error.localizedDescription)"
                }
            }
        )
    }

    // MARK: Voice

    private var voice: some View {
        Form {
            Section {
                Picker("Tone", selection: settings.tone) {
                    ForEach(Tone.allCases, id: \.self) { tone in
                        Text(tone.displayName.uppercased()).tag(tone)
                    }
                }
                .pickerStyle(.inline)
                Text(model.settings.tone.blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } footer: {
                Text(
                    "Your choice is a ceiling, never a floor. The rails apply at every tier: "
                        + "never about appearance, competence, or your job. NUCLEAR is theatrical, "
                        + "not cruel."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Signals

    private var signals: some View {
        Form {
            Section("What the app can see right now") {
                ForEach(model.permissionStatus.explanation, id: \.self) { line in
                    Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Window titles (Accessibility)") {
                Toggle("Use window titles to tell a meeting from a terminal", isOn: settings.accessibilityEnabled)
                Text(
                    "Titles are parsed inside one function and the raw string is discarded. "
                        + "Nothing about a title is ever written to disk — only whether one was "
                        + "legible at all."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Button("Open System Settings") { model.openAccessibilitySettings() }
                    Button("Re-check") { model.refreshPermissions() }
                    Spacer()
                    Text(model.permissionStatus.accessibilityTrusted ? "granted" : "not granted")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(
                    "This button takes you to the switch. The app never raises the macOS "
                        + "permission alert on its own — not at launch, not from a timer, not "
                        + "when it decides you would get more out of it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Git context") {
                Toggle("Read the branch name from .git/HEAD", isOn: settings.gitContextEnabled)
                Text(
                    "Off by default. The branch name only, read from the file — never a "
                        + "command, never a diff, never a commit message."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Data

    private var data: some View {
        Form {
            Section("Where it lives") {
                Text(AppPaths.storageRoot.path)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                Text(
                    "One JSON object per line. Raw events are kept for "
                        + "\(Retention.defaultEventDays) days; daily summaries outlive them because "
                        + "they are a hundredth of the data."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Export…") { export() }
                    Button("Delete my data…", role: .destructive) { confirmDelete() }
                }
                if let dataReport {
                    Text(dataReport)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text(
                    "The export is a copy, not a report: nothing is filtered or transformed, "
                        + "so what you audit is what the app has."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
}

// MARK: - Pieces for the About pane

/// A lowercase monospaced section marker, the same one `MenuBarView` uses above `jobs`.
/// It is not a heading in the System Settings sense and is not meant to be read as one —
/// it is a label on a block of terminal output.
private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Brand.mono(10, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

/// A hairline with the pane's own rhythm around it, so the About tab has structure
/// without the grey cards that made it look borrowed.
private struct Rule: View {
    var body: some View {
        Divider().padding(.vertical, 14)
    }
}

/// Three states' worth of colour in four points: amber while something is happening,
/// amber while something is waiting for the user, and grey otherwise. Paired with text
/// that says the same thing, never carrying meaning alone.
private struct StatusDot: View {
    let state: UpdateChecker.State

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 5, height: 5)
            .padding(.top, 4)
    }

    private var fill: AnyShapeStyle {
        switch state {
        case .available, .readyToInstall, .checking, .downloading, .extracting, .installing:
            return AnyShapeStyle(Brand.amber)
        case .failed, .unavailable:
            return AnyShapeStyle(.secondary)
        default:
            return AnyShapeStyle(.quaternary)
        }
    }
}

// MARK: - Pieces

/// Quiet hours are stored as minutes from local midnight, which is the only
/// representation that survives a time-zone change without moving. `DatePicker` wants a
/// `Date`, so the conversion happens here and nowhere else.
private struct MinutePicker: View {
    let title: String
    @Binding var minutes: Int

    var body: some View {
        DatePicker(
            title,
            selection: Binding(
                get: {
                    Calendar.current.date(
                        bySettingHour: (minutes / 60) % 24, minute: minutes % 60, second: 0, of: Date()
                    ) ?? Date()
                },
                set: { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                }
            ),
            displayedComponents: .hourAndMinute
        )
    }
}
