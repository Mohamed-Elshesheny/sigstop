import AppKit
import SigstopCore
import SwiftUI

/// The dropdown.
///
/// Its job is to answer three questions without the user having to trust anything:
/// how long have I been at this, what does the app think I am doing, and **why does it
/// think that**. The third one is the disclosure, and it is not a debug affordance —
/// CLAUDE.md §4.1 makes "the app must always be able to answer *why do you think that?*"
/// an invariant, and this is where a user meets it.
struct MenuBarView: View {
    let model: AppModel
    /// Supplied by the status item controller. The popover lives outside the scene
    /// graph, so `openWindow` is not available to it.
    var openSettings: () -> Void = {}
    @State private var showEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 10)
            reading
            evidenceDisclosure
            if let reason = model.gateReason {
                gateNote(reason)
            }
            Divider().padding(.vertical, 10)
            actions
            Divider().padding(.vertical, 10)
            summary
            footer
        }
        .padding(14)
        .frame(width: 330)
        .onAppear { model.refreshRollup(force: true) }
    }

    // MARK: Header — the session clock

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                // The clock is continuous *active* work, not elapsed wall time. It is
                // driven by a timeline so it ticks smoothly between samples, but the value
                // itself only ever comes from the tracker.
                Text(Format.clock(model.continuousWork))
                    .font(.system(size: 30, weight: .light, design: .monospaced))
                    .monospacedDigit()
                Spacer()
                stateBadge
            }
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        if let until = model.pausedUntil {
            return "paused until \(until.formatted(date: .omitted, time: .shortened))"
        }
        if let until = model.snoozeUntil, until > .now {
            return "SIGALRM — asking again at \(until.formatted(date: .omitted, time: .shortened))"
        }
        if let ends = model.breakEndsAt {
            return "on a break until \(ends.formatted(date: .omitted, time: .shortened))"
        }
        if let since = model.timeSinceLastBreak {
            return "continuous active work · \(DurationText.short(since)) since your last break"
        }
        return "continuous active work · no break recorded yet"
    }

    private var stateBadge: some View {
        Text(model.engineStateName)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }

    // MARK: Reading — app, activity, confidence

    private var reading: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(model.applicationName).font(.system(size: 13, weight: .medium))
                Text("·").foregroundStyle(.tertiary)
                Text(model.activityLabel).font(.system(size: 13))
            }
            HStack(spacing: 6) {
                ConfidenceBar(value: model.confidence)
                // The number is shown, always. A confidence the user cannot see is a
                // confidence the app can quietly overstate.
                Text("\(Format.percent(model.confidence)) confident")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var evidenceDisclosure: some View {
        DisclosureGroup(isExpanded: $showEvidence) {
            VStack(alignment: .leading, spacing: 6) {
                if model.evidenceLines.isEmpty {
                    Text("No evidence either way yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                ForEach(model.evidenceLines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Format.logOdds(line.logOdds))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(line.logOdds >= 0 ? .secondary : .tertiary)
                            .frame(width: 38, alignment: .trailing)
                        Text(line.summary)
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(model.caveats, id: \.self) { caveat in
                    Text(caveat)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Why do you think that?").font(.system(size: 11))
        }
        .padding(.top, 8)
    }

    private func gateNote(_ reason: String) -> some View {
        Text("Holding off — \(reason).")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 4) {
            if model.isOnBreak {
                MenuRow(title: "Resume (SIGCONT)", shortcut: nil) { model.endBreak() }
            } else {
                MenuRow(title: "Take a break now", shortcut: nil) { model.takeBreakNow() }
                // Only offered when there is actually a question to defer. A snooze with
                // no open cycle does nothing, and a button that does nothing teaches
                // people that the buttons do nothing.
                if model.canSnooze {
                    MenuRow(title: "Snooze (SIGALRM)", shortcut: nil) { model.snooze() }
                }
            }
            if model.pausedUntil == nil {
                MenuRow(title: "Pause for an hour", shortcut: nil) { model.pause(for: 3600) }
            } else {
                MenuRow(title: "Resume sigstop", shortcut: nil) { model.resume() }
            }
            // Only when there is genuinely an update waiting. A scheduled check runs
            // without any window of its own — the user driver is this app's, not
            // Sparkle's — so this row is the one place a background find can surface.
            // Nothing here starts a check; it opens the pane that has the button.
            if let version = model.updates.state.offeredVersion {
                MenuRow(title: "Update to \(version)…", shortcut: nil) { openSettings() }
            }
            MenuRow(title: "Settings…", shortcut: ",") {
                // A menu bar app has no window to bring forward, so it has to ask for the
                // front itself. This is the one place the app activates, and only because
                // the user clicked a thing that is a window.
                openSettings()
            }
            MenuRow(title: "Quit", shortcut: "q") {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: Today

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("jobs").font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(model.todayLine.isEmpty ? "Nothing recorded yet today." : model.todayLine)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            if !model.todayDetail.isEmpty {
                Text(model.todayDetail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if case .unavailable(let reason) = model.notificationState {
            Text(reason)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        if let error = model.lastStoreError {
            Text(error)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }
}

// MARK: - Pieces

private struct MenuRow: View {
    let title: String
    let shortcut: Character?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                if let shortcut {
                    Text("⌘\(String(shortcut).uppercased())")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ConfidenceBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.secondary)
                    .frame(width: geometry.size.width * min(1, max(0, value)))
            }
        }
        .frame(width: 70, height: 4)
    }
}
