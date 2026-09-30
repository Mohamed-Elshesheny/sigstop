import AppKit
import SigstopCore
import SwiftUI

struct MenuBarView: View {
    static func clock(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = DisplayLocale.english(from: .current)
        return date.formatted(style)
    }

    let model: AppModel
    var openSettings: () -> Void = {}

    @State private var showEvidence: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let width: CGFloat = 356
    private static let gutter: CGFloat = 16

    private static let output = "→"
    private static let command = "❯"

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
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.chrome)
        }
        .frame(width: Self.width)
        .background(Brand.content)
    }

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
                BrandMark(size: 40, fill: markFill, resting: model.indicator == .held)
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
        let accent: Bool

        var tint: Color {
            if accent { return Brand.amber }
            return Brand.fgMuted
        }
    }

    private var status: Status {
        let title = model.statusWord
        if model.pausedUntil != nil {
            return Status(title: title, signal: "state T", dot: .off, accent: false)
        }
        if model.indicator == .backedOff {
            return Status(title: title, signal: "state R", dot: .off, accent: false)
        }
        switch model.engineStateName {
        case "working": return Status(title: title, signal: "state R", dot: .running, accent: false)
        case "breakDue": return Status(title: title, signal: "state R", dot: .suspend, accent: true)
        case "ignored": return Status(title: title, signal: "state R", dot: .suspend, accent: true)
        case "snoozed": return Status(title: title, signal: "SIGALRM", dot: .suspend, accent: true)
        case "breakActive": return Status(title: title, signal: "state T", dot: .suspend, accent: true)
        case "idle": return Status(title: title, signal: "state S", dot: .off, accent: false)
        case "quiet": return Status(title: title, signal: "state S", dot: .off, accent: false)
        default: return Status(title: title, signal: "", dot: .off, accent: false)
        }
    }

    private var subtitle: String {
        if let until = model.pausedUntil {
            let day = until.timeIntervalSinceNow >= 24 * 3600 ? " tomorrow" : ""
            return "paused until \(Self.clock(until))\(day)"
        }
        if let until = model.snoozeUntil, until > .now {
            return "asking again at \(Self.clock(until))"
        }
        if let ends = model.breakEndsAt {
            return "on a break until \(Self.clock(ends))"
        }
        if let since = model.timeSinceLastBreak {
            return "continuous · \(DurationText.short(since)) since your last break"
        }
        return "continuous · no break recorded yet"
    }

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
            if let finished = model.finishedCommand {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\u{21B5}")
                        .font(Brand.mono(10))
                        .foregroundStyle(Brand.fgMuted)
                        .frame(width: 40, alignment: .trailing)
                    Text("\(finished), a natural pause")
                        .font(Brand.sans(11))
                        .foregroundStyle(Brand.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            hold(model.waiting)
                .padding(.bottom, 4)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    breakControl
                    meetingControl(style: .outlined)
                }
                VStack(alignment: .leading, spacing: 6) {
                    breakControl
                    meetingControl(style: .quiet)
                }
            }

            if let version = model.updates.state.offeredVersion {
                TerminalButton("Update to \(version)…", style: .quiet, mark: Self.command) {
                    openSettings()
                }
            }

            Rule()
                .padding(.top, 2)

            QuietRow {
                if model.pausedUntil == nil {
                    TerminalButton("Pause · 1h", style: .quiet) { model.pause(for: AppModel.hourPause) }
                    TerminalButton("Pause · today", style: .quiet) { model.pauseUntilTomorrow() }
                        .accessibilityLabel("Pause for the rest of today")
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

    @ViewBuilder
    private var breakControl: some View {
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
    }

    @ViewBuilder
    private func meetingControl(style: TerminalButton.Style) -> some View {
        if model.callHoldSummary != nil {
            TerminalButton("Not in a meeting", style: style, mark: Self.command) {
                model.clearMeetingHold()
            }
        } else if model.inputDeviceIsHoldingABreak {
            TerminalButton(model.ignoreInputDeviceLabel, style: style, mark: Self.command) {
                model.clearMeetingHold()
            }
        } else if model.settings.holdBreaksDuringCalls {
            TerminalButton("I'm in a meeting", style: style, mark: Self.command) {
                model.assertMeeting()
            }
        }
    }

    private func hold(_ line: WaitingLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(Self.output)
                .frame(width: TerminalButton.markGutter, alignment: .leading)
            (Text(line.claim.prefix).font(Brand.mono(10.5, weight: .medium)).foregroundStyle(Self.ink(for: line.claim))
                + Text(", \(line.body)."))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(Brand.mono(10.5))
        .foregroundStyle(Brand.fgMuted)
        .padding(.horizontal, TerminalButton.markInset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.text)
    }

    private static func ink(for claim: WaitingLine.Claim) -> Color {
        switch claim {
        case .waitingOnYou: return Brand.amber
        case .holdingOff, .notAskingYet: return Brand.fg
        }
    }

    private var breakWanted: Bool {
        switch model.indicator {
        case .breakDue, .escalating, .held, .backedOff: return true
        default: return false
        }
    }

    private var uptime: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Kicker("uptime · today")
                Spacer(minLength: 0)
                if let summary = recordedToday {
                    Self.readout([(DurationText.short(summary.totalActiveWork), "active")])
                        .lineLimit(1)
                }
            }

            if let summary = recordedToday {
                if let top = summary.topApplication, top.seconds > 0, summary.totalActiveWork > 0 {
                    share(of: top, in: summary)
                }
                Self.readout(Self.dayStats(for: summary))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Nothing recorded yet today.")
                    .font(Brand.mono(10.5))
                    .foregroundStyle(Brand.fgMuted)
            }

            footnotes
        }
    }

    private var recordedToday: DailySummary? {
        guard let summary = model.todaySummary, !summary.isEmptyDay else { return nil }
        return summary
    }

    private func share(of top: (bundleID: String, seconds: TimeInterval), in summary: DailySummary) -> some View {
        let name = Self.displayName(for: top.bundleID)
        return HStack(spacing: 10) {
            Text(name.lowercased())
                .font(Brand.mono(10.5))
                .foregroundStyle(Brand.fgMuted)
                .lineLimit(1)
                .frame(maxWidth: 120, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            TransferBar(fraction: min(1, top.seconds / summary.totalActiveWork), animated: false)
                .frame(height: 3)
            Text(DurationText.short(top.seconds))
                .font(Brand.mono(11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Brand.fg)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(name), \(DurationText.short(top.seconds)) of \(DurationText.short(summary.totalActiveWork)) active"
        )
    }

    private static func readout(_ stats: [(value: String, label: String)]) -> Text {
        let glued = { (text: String) in text.replacingOccurrences(of: " ", with: "\u{00A0}") }
        var line = Text("")
        for (index, stat) in stats.enumerated() {
            if index > 0 {
                line = line + Text("\u{00A0}· ").font(Brand.mono(10.5)).foregroundStyle(Brand.fgFaint)
            }
            line = line
                + Text(glued(stat.value)).font(Brand.mono(11, weight: .medium)).foregroundStyle(Brand.fg)
                + Text("\u{00A0}" + glued(stat.label)).font(Brand.mono(10.5)).foregroundStyle(Brand.fgMuted)
        }
        return line.monospacedDigit()
    }

    private static func dayStats(for summary: DailySummary) -> [(value: String, label: String)] {
        var out: [(value: String, label: String)] = [
            (DurationText.short(summary.longestContinuousSession), "longest"),
            ("\(summary.breakCount)", summary.breakCount == 1 ? "break" : "breaks"),
        ]
        if let average = summary.averageBreakLength {
            out.append((DurationText.short(average), "avg"))
        }
        let asked = summary.breakOpportunities - summary.excludedOpportunities
        if asked > 0 {
            out.append(("\(summary.honoredOpportunities) of \(asked)", "kept"))
        }
        return out
    }

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
