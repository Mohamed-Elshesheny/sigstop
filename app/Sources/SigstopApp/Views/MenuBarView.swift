import AppKit
import SigstopCore
import SwiftUI

/// The dropdown.
///
/// Its job is to answer three questions without the user having to trust anything:
/// how long have I been at this, what does the app think I am doing, and **why does it
/// think that**. The third one is the disclosure, and it is not a debug affordance:
/// CLAUDE.md §4.1 makes "the app must always be able to answer *why do you think that?*"
/// an invariant, and this is where a user meets it.
///
/// The panel is three bands, top to bottom in order of why the panel was opened: the
/// state and the clock; the body, carrying the inference and then the actions; and
/// today's `jobs`, dense and small. The two outer bands are chrome and sit on the back
/// plane, `Brand.chrome`, with the body one step in front of them on `Brand.content`,
/// because a frame that is lighter than the thing it frames reads as sitting on top of
/// it. In dark mode it did, for as long as this panel has existed.
///
/// Amber is spent on the state alone, the kicker, the clock, the command mark and the
/// primary control turn amber together when a break is due and at no other time, so the
/// eye finds the one thing that changed.
struct MenuBarView: View {
    let model: AppModel
    /// Supplied by the status item controller. The panel lives outside the scene graph,
    /// so `openWindow` is not available to it.
    var openSettings: () -> Void = {}

    @State private var showEvidence: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let width: CGFloat = 356
    private static let gutter: CGFloat = 16

    /// The two glyphs of the action block. They are here rather than at each call site
    /// because the whole point of them is that there are exactly two.
    private static let output = "→"
    private static let command = "❯"

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
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.chrome)
            Rule()
            VStack(alignment: .leading, spacing: 22) {
                inference
                actions
            }
            .padding(.horizontal, Self.gutter)
            .padding(.vertical, 14)
            Rule()
            uptime
                .padding(.horizontal, Self.gutter)
                .padding(.vertical, 12)
                /// The band has to be the panel's width, not the text's.
                ///
                /// Without this the chrome fill took the content's intrinsic size, so on a
                /// short day the footer was a paler rectangle over about half the panel
                /// with a hard vertical edge down the middle of nothing.
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.chrome)
        }
        .frame(width: Self.width)
        .background(Brand.content)
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
                        /// Hidden while no work threshold is in force at all. During the
                        /// cooldown after an unanswered opportunity the clock is not
                        /// counting towards anything, and the header drew `169:00 / 5:00`
                        /// with the mark pinned full, every number on screen contradicting
                        /// the one sentence under it that was right. The wait is a
                        /// wall-clock one and it is on that line.
                        if model.workTargetInForce {
                            Text("/ \(Format.clock(model.workTarget))")
                                .font(Brand.mono(11))
                                .foregroundStyle(Brand.fgMuted)
                        }
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
        case .breakDue, .escalating, .held, .backedOff: return 1
        default:
            guard model.workTarget > 0 else { return 0 }
            return min(1, max(0, model.continuousWork / model.workTarget))
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
        /// A break is owed and the app has decided not to ask. The engine state under this
        /// is `working`, which is why it drew as "running" with a running dot for the
        /// whole of a twenty-five minute deliberate silence.
        if model.indicator == .backedOff {
            return Status(title: "stood down", signal: "state R", dot: .off, accent: false)
        }
        switch model.engineStateName {
        case "working": return Status(title: "running", signal: "state R", dot: .running, accent: false)
        case "breakDue": return Status(title: "break due", signal: "state R", dot: .suspend, accent: true)
        case "ignored": return Status(title: "escalating", signal: "state R", dot: .suspend, accent: true)
        case "snoozed": return Status(title: "snoozed", signal: "SIGALRM", dot: .suspend, accent: true)
        case "breakActive": return Status(title: "stopped", signal: "state T", dot: .suspend, accent: true)
        case "idle": return Status(title: "idle", signal: "state S", dot: .off, accent: false)
        case "quiet":
            // Not every quiet is quiet hours. `dailyCapReached` and `sustainedFocusMode`
            // are the other two a user can actually sit in, and both used to draw with
            // this label whether or not quiet hours were even switched on.
            return Status(
                title: model.quietCause?.title ?? "quiet",
                signal: "state S", dot: .off, accent: false
            )
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
                if !model.applicationName.isEmpty {
                    Text(model.applicationName)
                        .font(Brand.mono(14, weight: .semibold))
                        .foregroundStyle(Brand.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·")
                        .font(Brand.mono(13))
                        .foregroundStyle(Brand.fgMuted)
                }
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
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: Actions, a short transcript with one button in it

    /// Exactly one control in this panel is drawn as a button, and it is the one the
    /// panel exists to offer. It is outlined while nothing is owed and filled amber the
    /// moment a break is due, which is the only colour change in the body.
    ///
    /// Everything else is a quiet control: a label at text weight that fills under the
    /// pointer, like a menu item. They were rectangles of the same value as the primary,
    /// so five things asked for attention equally and the panel read as a stack of slabs.
    /// Nothing is hidden by this, the labels are all still there at 7:1 against the
    /// background, and each one is still a real button to VoiceOver and to the keyboard.
    ///
    /// What replaces the box is the mark column. The block reads as a session: `→` is
    /// the app's line, `❯` is a line you can give it, and the two glyphs sit on one
    /// vertical rule so the difference between them is the only thing that moves. A
    /// borderless control needs standing evidence that it is a control, and brightness
    /// alone was carrying that on its own.
    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            /// Always. Not sometimes.
            ///
            /// A panel that says nothing when it is quiet is indistinguishable from a
            /// panel that is broken, and the user who cannot tell those apart deletes the
            /// app rather than filing a bug. The claim in front of the sentence says
            /// which kind of quiet this is; `WaitingLine` owns both.
            ///
            /// It reads before the button because it is the reason for it.
            hold(model.waiting.text)

            if model.isOnBreak {
                TerminalButton("Resume · SIGCONT", style: .filled, mark: Self.command) {
                    model.endBreak()
                }
            } else {
                TerminalButton(
                    "Take a break now",
                    style: breakWanted ? .filled : .outlined,
                    mark: Self.command
                ) { model.takeBreakNow() }
            }

            /// The answers that are not "yes", each on its own line under the one that
            /// is. They were a wrapping row, which meant "Snooze · SIGALRM" beside
            /// "Ignore this input device · 20m" either wrapped anyway or squeezed; a
            /// command per line is both the honest shape and the one that never squeezes.
            if !model.isOnBreak, model.canSnooze {
                TerminalButton("Snooze · SIGALRM", style: .quiet, mark: Self.command) {
                    model.snooze()
                }
            }
            meetingControl
            if let version = model.updates.state.offeredVersion {
                TerminalButton("Update to \(version)…", style: .quiet, mark: Self.command) {
                    openSettings()
                }
            }

            /// Everything below the rule is app chrome rather than an answer to the
            /// prompt, and it is separated so the eye stops at the button first.
            Rule()
                .padding(.top, 2)

            QuietRow {
                if model.pausedUntil == nil {
                    TerminalButton("Pause · 1h", style: .quiet) { model.pause(for: 3600) }
                } else {
                    TerminalButton("Resume", style: .quiet) { model.resume() }
                }
                TerminalButton("Settings…", style: .quiet) { openSettings() }
                Spacer(minLength: 0)
                TerminalButton("Quit", style: .quiet) { NSApp.terminate(nil) }
            }
            .padding(.trailing, -TerminalButton.quietInset)
        }
    }

    /// One control with three names. Which one is showing depends on what the app
    /// currently believes, and offering "I'm in a meeting" while the line above says a
    /// device is already holding a break is the panel contradicting itself in two
    /// adjacent rows.
    @ViewBuilder
    private var meetingControl: some View {
        if model.callHoldSummary != nil {
            TerminalButton("Not in a meeting", style: .quiet, mark: Self.command) {
                model.clearMeetingHold()
            }
        } else if model.inputDeviceIsHoldingABreak {
            TerminalButton(model.ignoreInputDeviceLabel, style: .quiet, mark: Self.command) {
                model.clearMeetingHold()
            }
        } else {
            TerminalButton("I'm in a meeting", style: .quiet, mark: Self.command) {
                model.assertMeeting()
            }
        }
    }

    /// The one muted line saying what the app is waiting for.
    ///
    /// The three claims it can carry are different and stay different. "holding off"
    /// means something is blocking a prompt right now; "not asking yet" means nothing is,
    /// and the engine is waiting on its own clock; "waiting on you" means the ask is out
    /// and the silence is the user's. Collapsing any two of them would put the app back
    /// where it was, telling a user it was running while it had no intention of saying
    /// anything for an hour.
    private func hold(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(Self.output)
                .frame(width: TerminalButton.markGutter, alignment: .leading)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(Brand.mono(10.5))
        .foregroundStyle(Brand.fgMuted)
        .padding(.horizontal, TerminalButton.markInset)
    }

    private var breakWanted: Bool {
        switch model.indicator {
        case .breakDue, .escalating, .held, .backedOff: return true
        default: return false
        }
    }

    // MARK: uptime, today, dense and quiet

    /// The numbers are rendered here from the rollup, not from the narrator's detail
    /// string, so the top application can be shown by its display name rather than the
    /// last component of its bundle id.
    private var uptime: some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker("uptime · today")

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
