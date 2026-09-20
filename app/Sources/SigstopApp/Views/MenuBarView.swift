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
///
/// The layout follows the site's `MenuBarPanel` mock, which is the design of record: a
/// process-state line, the clock as the hero with the mark beside it, a `dt/dd` list for
/// the inference, the evidence trail, then the actions and today's `jobs`. Everything
/// machine-shaped is monospaced; only the day's sentence is set in the system sans.
struct MenuBarView: View {
    let model: AppModel
    /// Supplied by the status item controller. The panel lives outside the scene graph,
    /// so `openWindow` is not available to it.
    var openSettings: () -> Void = {}

    @State private var showEvidence: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let width: CGFloat = 356
    private static let gutter: CGFloat = 18

    /// `expandEvidence` opens the "why do you think that?" trail from the first frame.
    /// The panel never passes it; it exists so a preview or a render check can show the
    /// expanded state without a click.
    init(model: AppModel, openSettings: @escaping () -> Void = {}, expandEvidence: Bool = false) {
        self.model = model
        self.openSettings = openSettings
        _showEvidence = State(initialValue: expandEvidence)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.top, 16)
                .padding(.bottom, 16)
            Rule()
            inference
                .padding(.vertical, 12)
            Rule()
            actions
                .padding(.vertical, 10)
            Rule()
            jobs
                .padding(.top, 12)
                .padding(.bottom, 14)
            footer
        }
        .padding(.horizontal, Self.gutter)
        .frame(width: Self.width)
        .background(Brand.bgRaised)
        .onAppear { model.refreshRollup(force: true) }
    }

    // MARK: Header — the process state and the session clock

    /// The clock is continuous *active* work, not elapsed wall time. The value only ever
    /// comes from the tracker; nothing here interpolates between samples, because a
    /// number that is guessed for four seconds out of five is not a measurement.
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Kicker(status.title)
                Spacer()
                HStack(spacing: 6) {
                    StateDot(state: status.dot)
                    Text(status.signal)
                        .font(Brand.mono(11))
                        .foregroundStyle(Brand.fgFaint)
                }
            }

            HStack(alignment: .center, spacing: 14) {
                BrandMark(size: 44, fill: markFill)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Format.clock(model.continuousWork))
                            .font(Brand.mono(40, weight: .bold))
                            .tracking(-1.4)
                            .monospacedDigit()
                            .foregroundStyle(clockColour)
                            .contentTransition(reduceMotion ? .identity : .numericText())
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: model.continuousWork)
                        Text("/ \(Format.clock(TimeInterval(model.settings.workIntervalMinutes * 60)))")
                            .font(Brand.mono(11))
                            .foregroundStyle(Brand.fgFaint)
                    }
                    Text(subtitle)
                        .font(Brand.mono(10.5))
                        .foregroundStyle(Brand.fgMuted)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Mirrors the menu bar icon's fill rule so the two marks never disagree: empty on a
    /// break, full once a break is due, and the fraction of the interval otherwise.
    private var markFill: Double {
        switch model.indicator {
        case .onBreak: return 0
        case .breakDue, .escalating: return 1
        default: return min(1, max(0, model.workFraction))
        }
    }

    /// Amber only when the number is the reason to act. Colouring it all the time would
    /// make "break due" look like every other minute of the day.
    private var clockColour: Color {
        switch model.indicator {
        case .breakDue, .escalating: return Brand.amber
        default: return Brand.fg
        }
    }

    private struct Status {
        let title: String
        let signal: String
        let dot: StateDot.State
    }

    /// The engine's state named the way `ps` would name it. `R` is running, `T` is
    /// stopped, `S` is sleeping; `SIGALRM` is the snooze the user asked for. The dot's
    /// colour is the product's two-state palette: green while the process runs, amber
    /// while a stop is pending or in effect, and faint when nothing is being measured.
    private var status: Status {
        if model.pausedUntil != nil {
            return Status(title: "paused", signal: "state T", dot: .off)
        }
        switch model.engineStateName {
        case "working": return Status(title: "running", signal: "state R", dot: .running)
        case "breakDue": return Status(title: "break due", signal: "state R", dot: .suspend)
        case "ignored": return Status(title: "escalating", signal: "state R", dot: .suspend)
        case "snoozed": return Status(title: "snoozed", signal: "SIGALRM", dot: .suspend)
        case "breakActive": return Status(title: "stopped", signal: "state T", dot: .suspend)
        case "idle": return Status(title: "idle", signal: "state S", dot: .off)
        case "quiet": return Status(title: "quiet hours", signal: "state S", dot: .off)
        default: return Status(title: model.engineStateName, signal: "", dot: .off)
        }
    }

    private var subtitle: String {
        if let until = model.pausedUntil {
            return "paused until \(until.formatted(date: .omitted, time: .shortened))"
        }
        if let until = model.snoozeUntil, until > .now {
            return "asking again at \(until.formatted(date: .omitted, time: .shortened))"
        }
        if let ends = model.breakEndsAt {
            return "on a break until \(ends.formatted(date: .omitted, time: .shortened))"
        }
        if let since = model.timeSinceLastBreak {
            return "continuous · \(DurationText.short(since)) since your last break"
        }
        return "continuous · no break recorded yet"
    }

    // MARK: Inference — app, activity, confidence, and why

    private var inference: some View {
        VStack(alignment: .leading, spacing: 0) {
            Kicker("inference")
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 5) {
                fact("app", value: model.applicationName)
                fact("activity", value: model.activityLabel)
                confidenceRow
            }

            evidenceDisclosure
                .padding(.top, 10)

            if let reason = model.gateReason {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("→").foregroundStyle(Brand.fgFaint)
                    Text("holding off — \(reason).")
                        .foregroundStyle(Brand.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Brand.mono(10.5))
                .padding(.top, 8)
            }
        }
    }

    private func fact(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(Brand.fgFaint)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(Brand.fg)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(Brand.mono(11))
    }

    /// The number is shown, always, and in the unit the model actually works in. A
    /// confidence the user cannot see is a confidence the app can quietly overstate.
    /// Green above the site's 0.6 threshold, amber below it, so "this is a guess" is
    /// legible before the digits are read.
    private var confidenceRow: some View {
        let confident = model.confidence >= 0.6
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("confidence")
                .foregroundStyle(Brand.fgFaint)
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(String(format: "%.2f", min(max(model.confidence, 0), 1)))
                    .foregroundStyle(confident ? Brand.running : Brand.amber)
                Text("(\(Format.percent(model.confidence)))")
                    .foregroundStyle(Brand.fgFaint)
            }
        }
        .font(Brand.mono(11))
        .monospacedDigit()
    }

    private var evidenceDisclosure: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { showEvidence.toggle() }) {
                HStack(spacing: 6) {
                    Text(showEvidence ? "▾" : "▸")
                        .foregroundStyle(Brand.fgFaint)
                        .frame(width: 8)
                    Text("why do you think that?")
                        .foregroundStyle(Brand.fgMuted)
                    Spacer()
                }
                .font(Brand.mono(11))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showEvidence {
                VStack(alignment: .leading, spacing: 6) {
                    if model.evidenceLines.isEmpty {
                        Text("No evidence either way yet.")
                            .font(Brand.sans(11))
                            .foregroundStyle(Brand.fgMuted)
                    }
                    ForEach(model.evidenceLines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Format.logOdds(line.logOdds))
                                .font(Brand.mono(10))
                                .foregroundStyle(line.logOdds >= 0 ? Brand.fgMuted : Brand.fgFaint)
                                .frame(width: 40, alignment: .trailing)
                            Text(line.summary)
                                .font(Brand.sans(11))
                                .foregroundStyle(Brand.fgMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach(model.caveats, id: \.self) { caveat in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("!")
                                .font(Brand.mono(10))
                                .foregroundStyle(Brand.fgFaint)
                                .frame(width: 40, alignment: .trailing)
                            Text(caveat)
                                .font(Brand.sans(11))
                                .foregroundStyle(Brand.fgFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.leading, 14)
            }
        }
    }

    // MARK: Actions

    /// One prominent control, then a list. The prominent one is filled amber only while
    /// a break is due or in progress, which is when it is the point of opening the panel;
    /// the rest of the day it is outlined, so amber keeps meaning "act now".
    private var actions: some View {
        VStack(spacing: 2) {
            Group {
                if model.isOnBreak {
                    TerminalButton("Resume · SIGCONT", style: .filled) { model.endBreak() }
                } else {
                    TerminalButton("Take a break now", style: breakWanted ? .filled : .outlined) {
                        model.takeBreakNow()
                    }
                }
            }
            .padding(.bottom, 6)

            if !model.isOnBreak, model.canSnooze {
                MenuRow("Snooze", hint: "SIGALRM") { model.snooze() }
            }
            if model.pausedUntil == nil {
                MenuRow("Pause for an hour", hint: "1h") { model.pause(for: 3600) }
            } else {
                MenuRow("Resume sigstop", hint: nil) { model.resume() }
            }
            if let version = model.updates.state.offeredVersion {
                MenuRow("Update to \(version)…", hint: "new", accent: true) { openSettings() }
            }
            MenuRow("Settings…", hint: "⌘,") { openSettings() }
            MenuRow("Quit", hint: "⌘Q") { NSApp.terminate(nil) }
        }
    }

    private var breakWanted: Bool {
        switch model.indicator {
        case .breakDue, .escalating: return true
        default: return false
        }
    }

    // MARK: jobs — today

    private var jobs: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Kicker("jobs")
                Spacer()
                Text("today")
                    .font(Brand.mono(10))
                    .foregroundStyle(Brand.fgFaint)
            }
            Text(model.todayLine.isEmpty ? "Nothing recorded yet today." : model.todayLine)
                .font(Brand.sans(12.5))
                .foregroundStyle(Brand.fg)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if !model.todayDetail.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(Array(detailParts.enumerated()), id: \.offset) { _, part in
                        StatChip(part)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    /// The narrator joins its facts with ` · `; shown as tags they pack into two lines
    /// where the joined sentence needed three and read as a log line.
    private var detailParts: [String] {
        model.todayDetail.components(separatedBy: " · ")
    }

    @ViewBuilder
    private var footer: some View {
        if case .unavailable(let reason) = model.notificationState {
            footnote(reason)
        }
        if let failure = model.promptDeliveryFailure {
            footnote(failure)
        }
        if let error = model.lastStoreError {
            footnote(error)
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(Brand.mono(10))
            .foregroundStyle(Brand.fgFaint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 12)
    }
}

// MARK: - Pieces

/// A command in the list: monospaced title on the left, the signal or shortcut it maps
/// to on the right, in the faint colour so it reads as an annotation and not a second
/// label.
private struct MenuRow: View {
    let title: String
    let hint: String?
    var accent = false
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, hint: String?, accent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.hint = hint
        self.accent = accent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(Brand.mono(12))
                    .foregroundStyle(accent ? Brand.amber : Brand.fg)
                Spacer()
                if let hint {
                    Text(hint)
                        .font(Brand.mono(10))
                        .foregroundStyle(Brand.fgFaint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(hovering ? Brand.surfaceHi : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One fact from the day, as a tag.
private struct StatChip: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Brand.mono(10))
            .foregroundStyle(Brand.fgMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Brand.line, lineWidth: 1)
            )
    }
}
