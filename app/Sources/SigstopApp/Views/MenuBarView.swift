import AppKit
import SigstopCore
import SwiftUI

/// The dropdown.
///
/// Its job is to answer three questions without the user having to trust anything:
/// how long have I been at this, what does the app think I am doing, and **why does it
/// think that**. The third one is the disclosure, and it is not a debug affordance ,
/// CLAUDE.md §4.1 makes "the app must always be able to answer *why do you think that?*"
/// an invariant, and this is where a user meets it.
///
/// The panel is four blocks at three surface values, top to bottom in order of why the
/// panel was opened: the state and the clock on a `surface` strip; the inference as a
/// raised card on the `bg`; the actions as one primary control and a quiet row; and
/// today's `jobs` on a second `surface` strip, dense and small. Amber is spent on the
/// state alone, the kicker, the clock and the primary control turn amber together when
/// a break is due and at no other time, so the eye finds the one thing that changed.
struct MenuBarView: View {
    let model: AppModel
    /// Supplied by the status item controller. The panel lives outside the scene graph,
    /// so `openWindow` is not available to it.
    var openSettings: () -> Void = {}

    @State private var showEvidence: Bool
    @State private var showNarration = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let width: CGFloat = 356
    private static let gutter: CGFloat = 16
    private static let cardRadius: CGFloat = 8

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
                .padding(.horizontal, Self.gutter)
                .padding(.top, 14)
                .padding(.bottom, 14)
                .background(Brand.surface)
            Rule()
            VStack(alignment: .leading, spacing: 12) {
                inference
                actions
            }
            .padding(.horizontal, Self.gutter)
            .padding(.vertical, 14)
            Rule()
            jobs
                .padding(.horizontal, Self.gutter)
                .padding(.vertical, 12)
                .background(Brand.surface)
        }
        .frame(width: Self.width)
        .background(Brand.bg)
        .onAppear { model.refreshRollup(force: true) }
    }

    // MARK: Header, the state and the session clock

    /// The clock is continuous *active* work, not elapsed wall time. The value only ever
    /// comes from the tracker; nothing here interpolates between samples, because a
    /// number that is guessed for four seconds out of five is not a measurement.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                StateDot(state: status.dot)
                Text(status.title)
                    .font(Brand.mono(10, weight: .medium))
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(status.tint)
                Spacer()
                Text(status.signal)
                    .font(Brand.mono(10.5))
                    .foregroundStyle(Brand.fgMuted)
            }

            HStack(alignment: .center, spacing: 12) {
                BrandMark(size: 40, fill: markFill)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(Format.clock(model.displayedContinuousWork))
                                .font(Brand.mono(40, weight: .bold))
                                .tracking(-1.4)
                                .monospacedDigit()
                                .foregroundStyle(status.accent ? Brand.amber : Brand.fg)
                                .contentTransition(reduceMotion ? .identity : .numericText())
                        }
                        Text("/ \(Format.clock(TimeInterval(model.settings.workIntervalMinutes * 60)))")
                            .font(Brand.mono(11))
                            .foregroundStyle(Brand.fgMuted)
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
    /// Driven by the MEASURED clock, not the per-second display value.
    ///
    /// `workFraction` now carries the display clock forward every second, and the mark
    /// animates its fill, so feeding it that value made the bars creep continuously and
    /// visibly re-animate whenever the panel re-laid out, which is what opening the
    /// evidence disclosure does. The mark moves on real samples only.
    private var markFill: Double {
        switch model.indicator {
        case .onBreak: return 0
        case .breakDue, .escalating: return 1
        default:
            let target = model.settings.workInterval
            guard target > 0 else { return 0 }
            return min(1, max(0, model.continuousWork / target))
        }
    }

    private struct Status {
        let title: String
        let signal: String
        let dot: StateDot.State
        /// True in every state where the process is stopped or a stop is pending. It is
        /// the one condition under which the panel uses amber.
        let accent: Bool

        var tint: Color {
            if accent { return Brand.amber }
            return Brand.fgMuted
        }
    }

    /// The engine's state named the way `ps` would name it. `R` is running, `T` is
    /// stopped, `S` is sleeping; `SIGALRM` is the snooze the user asked for.
    private var status: Status {
        if model.pausedUntil != nil {
            return Status(title: "paused", signal: "state T", dot: .off, accent: false)
        }
        switch model.engineStateName {
        case "working": return Status(title: "running", signal: "state R", dot: .running, accent: false)
        case "breakDue": return Status(title: "break due", signal: "state R", dot: .suspend, accent: true)
        case "ignored": return Status(title: "escalating", signal: "state R", dot: .suspend, accent: true)
        case "snoozed": return Status(title: "snoozed", signal: "SIGALRM", dot: .suspend, accent: true)
        case "breakActive": return Status(title: "stopped", signal: "state T", dot: .suspend, accent: true)
        case "idle": return Status(title: "idle", signal: "state S", dot: .off, accent: false)
        case "quiet": return Status(title: "quiet hours", signal: "state S", dot: .off, accent: false)
        default: return Status(title: model.engineStateName, signal: "", dot: .off, accent: false)
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

    // MARK: Inference, one card: what, how sure, and why

    private var inference: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Kicker("inference")
                Spacer()
                confidence
            }
            .padding(.bottom, 8)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(model.applicationName)
                    .font(Brand.mono(14, weight: .semibold))
                    .foregroundStyle(Brand.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("·")
                    .font(Brand.mono(13))
                    .foregroundStyle(Brand.fgMuted)
                Text(model.activityLabel)
                    .font(Brand.mono(13))
                    .foregroundStyle(Brand.fgMuted)
                    .lineLimit(1)
            }

            DisclosureLine(open: showEvidence, title: "why do you think that?") {
                showEvidence.toggle()
            }
            .padding(.top, 8)

            if showEvidence {
                evidence
                    .padding(.top, 8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.bgRaised, in: RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                .strokeBorder(Brand.line, lineWidth: 1)
        )
    }

    /// The number is shown, always, and in the unit the model actually works in. A
    /// confidence the user cannot see is a confidence the app can quietly overstate.
    /// Green at or above the site's 0.6 threshold; below it the number is simply muted.
    /// Amber is not used here, a low confidence is information, not a state.
    private var confidence: some View {
        let confident = model.confidence >= 0.6
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("conf")
                .foregroundStyle(Brand.fgMuted)
            Text(String(format: "%.2f", min(max(model.confidence, 0), 1)))
                .font(Brand.mono(10.5, weight: .semibold))
                .foregroundStyle(confident ? Brand.running : Brand.fgMuted)
            Text("(\(Format.percent(model.confidence)))")
                .foregroundStyle(Brand.fgMuted)
        }
        .font(Brand.mono(10.5))
        .monospacedDigit()
    }

    private var evidence: some View {
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
                        .foregroundStyle(Brand.fgMuted)
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
                        .foregroundStyle(Brand.fgMuted)
                        .frame(width: 40, alignment: .trailing)
                    Text(caveat)
                        .font(Brand.sans(11))
                        .foregroundStyle(Brand.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Actions, one primary control, one quiet row

    /// The primary control is filled amber only while a break is due or in progress,
    /// which is when it is the point of opening the panel; the rest of the day it is
    /// outlined. Everything else is a quiet button in one row, in the same vocabulary,
    /// with Quit set apart on the right so leaving never sits next to acting.
    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if model.isOnBreak {
                    TerminalButton("Resume · SIGCONT", style: .filled) { model.endBreak() }
                } else {
                    TerminalButton("Take a break now", style: breakWanted ? .filled : .outlined) {
                        model.takeBreakNow()
                    }
                    if model.canSnooze {
                        TerminalButton("Snooze · SIGALRM") { model.snooze() }
                            .fixedSize()
                    }
                }
            }

            if let version = model.updates.state.offeredVersion {
                TerminalButton("Update to \(version)…") { openSettings() }
            }

            if let reason = model.gateReason {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("→")
                    Text("holding off, \(reason).")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Brand.mono(10.5))
                .foregroundStyle(Brand.fgMuted)
            }

            HStack(spacing: 4) {
                if model.pausedUntil == nil {
                    TerminalButton("Pause · 1h", style: .quiet) { model.pause(for: 3600) }
                        .fixedSize()
                } else {
                    TerminalButton("Resume", style: .quiet) { model.resume() }
                        .fixedSize()
                }
                TerminalButton("Settings…", style: .quiet) { openSettings() }
                    .fixedSize()
                Spacer(minLength: 0)
                TerminalButton("Quit", style: .quiet) { NSApp.terminate(nil) }
                    .fixedSize()
            }
        }
    }

    private var breakWanted: Bool {
        switch model.indicator {
        case .breakDue, .escalating: return true
        default: return false
        }
    }

    // MARK: jobs, today, dense and quiet

    /// The numbers are rendered here from the rollup, not from the narrator's detail
    /// string, so the top application can be shown by its display name rather than the
    /// last component of its bundle id. The narrator's sentence is behind a disclosure:
    /// it is the product's voice, but nobody opens the panel to read prose.
    private var jobs: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Kicker("jobs · today")
                Spacer()
                if !model.todayLine.isEmpty {
                    DisclosureLine(open: showNarration, title: "in words") {
                        showNarration.toggle()
                    }
                }
            }

            if let summary = model.todaySummary, !summary.isEmptyDay {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Self.stats(for: summary), id: \.label) { stat in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stat.value)
                                .font(Brand.mono(13, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Brand.fg)
                            Text(stat.label)
                                .font(Brand.mono(9))
                                .tracking(0.4)
                                .foregroundStyle(Brand.fgMuted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 2)
            } else {
                Text("Nothing recorded yet today.")
                    .font(Brand.mono(10.5))
                    .foregroundStyle(Brand.fgMuted)
            }

            if showNarration, !model.todayLine.isEmpty {
                Text(model.todayLine)
                    .font(Brand.sans(11.5))
                    .foregroundStyle(Brand.fgMuted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            footnotes
        }
    }

    /// Four figures, each with its label underneath.
    ///
    /// The previous version ran them together into one `·`-separated line, which put the
    /// numbers and their labels at the same weight and made the row a paragraph to read
    /// rather than a panel to scan. "honored 0 of 9" is now "0 of 9" under "kept", because
    /// the jargon was doing no work that the label does not do.
    private static func stats(for summary: DailySummary) -> [(value: String, label: String)] {
        var out: [(value: String, label: String)] = [
            (DurationText.short(summary.totalActiveWork), "active"),
            (DurationText.short(summary.longestContinuousSession), "longest"),
        ]
        let asked = summary.breakOpportunities - summary.excludedOpportunities
        out.append(asked > 0
            ? ("\(summary.honoredOpportunities) of \(asked)", "kept")
            : ("\(summary.breakCount)", "breaks"))
        if let top = summary.topApplication, top.seconds > 0 {
            out.append((DurationText.short(top.seconds), displayName(for: top.bundleID).lowercased()))
        }
        return out
    }

    /// `com.anthropic.claudefordesktop` → `Claude`. The running application's localized
    /// name when it is running, the bundle's name on disk when it is installed, and the
    /// last component of the identifier when it is neither, which is what the narrator
    /// prints, so the two never disagree by more than a capital letter.
    private static func displayName(for bundleID: String) -> String {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = running.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    @ViewBuilder
    private var footnotes: some View {
        if case .unavailable(let reason) = model.notificationState {
            footnote(reason)
        }
        if let failure = model.promptDeliveryFailure {
            footnote(failure)
        }
        if let error = model.lastStoreError {
            footnote(error)
        }
        if let note = model.badgeNote {
            footnote(note)
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(Brand.mono(10))
            .foregroundStyle(Brand.fgMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }
}

// MARK: - Pieces

/// A disclosure control that looks like one: a small triangle and a muted label, never a
/// heading. Used for the evidence trail and for the narrator's sentence.
private struct DisclosureLine: View {
    let open: Bool
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(open ? "▾" : "▸")
                    .frame(width: 8)
                Text(title)
            }
            .font(Brand.mono(10.5))
            .foregroundStyle(hovering ? Brand.fg : Brand.fgMuted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
