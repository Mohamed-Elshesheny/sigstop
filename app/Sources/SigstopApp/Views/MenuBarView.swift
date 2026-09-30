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
    var openAbout: () -> Void = {}

    @State private var showEvidence: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let width: CGFloat = 356
    private static let gutter: CGFloat = 16
    private static let keyColumn: CGFloat = 70
    private static let meterLabel: CGFloat = 50
    private static let maxMeterCells = 48

    private static let command = "❯"

    init(
        model: AppModel,
        openSettings: @escaping () -> Void = {},
        openAbout: @escaping () -> Void = {},
        expandEvidence: Bool = false
    ) {
        self.model = model
        self.openSettings = openSettings
        self.openAbout = openAbout
        _showEvidence = State(initialValue: expandEvidence)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Self.gutter)
                .padding(.top, 13)
                .padding(.bottom, 15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(headerBackdrop)
            Rule()
            VStack(alignment: .leading, spacing: 14) {
                table
                actions
            }
            .padding(.horizontal, Self.gutter)
            .padding(.top, 13)
            .padding(.bottom, 14)
            Rule()
            uptime
                .padding(.horizontal, Self.gutter)
                .padding(.top, 12)
                .padding(.bottom, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rule()
            commandBar
                .padding(.horizontal, Self.gutter - TerminalButton.quietInset)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.chrome)
        }
        .frame(width: Self.width)
        .background(Brand.content)
    }

    private var headerBackdrop: some View {
        ZStack {
            Brand.chrome
            if breakWanted {
                LinearGradient(
                    colors: [Brand.amberWash, Brand.chrome],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                StateDot(state: status.dot)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
                Text(status.title)
                    .font(Brand.mono(10, weight: .semibold))
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(status.tint)
                Spacer(minLength: 8)
                signal
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(heroClock(at: context.date))
                        .font(Brand.mono(42, weight: .bold))
                        .tracking(-1.6)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(clockInk)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                }
                if let suffix = clockSuffix {
                    Text(suffix)
                        .font(Brand.mono(11))
                        .monospacedDigit()
                        .foregroundStyle(Brand.fgFaint)
                }
                Spacer(minLength: 8)
                BrandMark(size: 28, fill: markFill, resting: model.indicator == .held)
            }
            .padding(.top, 8)

            meter
                .padding(.top, 8)

            claim(model.waiting)
                .padding(.top, 10)
        }
    }

    private var signal: some View {
        Group {
            if status.signal.hasPrefix("state ") {
                Text("state ").foregroundStyle(Brand.fgFaint)
                    + Text(String(status.signal.dropFirst(6)))
                    .font(Brand.mono(10.5, weight: .bold))
                    .foregroundStyle(status.accent ? Brand.amber : Brand.fg)
            } else {
                Text(status.signal)
                    .font(Brand.mono(10.5, weight: .semibold))
                    .foregroundStyle(status.accent ? Brand.amber : Brand.fgMuted)
            }
        }
        .font(Brand.mono(10.5))
        .accessibilityLabel(status.signal)
    }

    private func heroClock(at date: Date) -> String {
        if let ends = model.breakEndsAt {
            return Format.clock(max(0, ends.timeIntervalSince(date)))
        }
        return Format.clock(model.displayedContinuousWork)
    }

    private var clockSuffix: String? {
        if model.isOnBreak { return "left" }
        if model.workTargetInForce { return "/ \(Format.clock(model.workTarget))" }
        return nil
    }

    private var clockInk: Color {
        if breakWanted { return Brand.amber }
        if model.isOnBreak || status.dot == .running { return Brand.fg }
        return Brand.fgMuted
    }

    private var markFill: Double {
        switch model.indicator {
        case .onBreak: return 0
        case .breakDue, .escalating, .held, .backedOff: return 1
        default: return min(1, workRatio)
        }
    }

    private var workRatio: Double {
        guard model.workTarget > 0 else { return 0 }
        return max(0, model.continuousWork / model.workTarget)
    }

    private struct MeterReading {
        let cells: Int
        let lit: Int
        let tint: Color
        let label: String
        let ink: Color
        let spoken: String
    }

    private var meterReading: MeterReading {
        let cells = Self.meterCells(for: model.workTarget)
        if let ends = model.breakEndsAt {
            let length = max(1, model.policy.breakDurationTarget)
            let fraction = min(1, max(0, ends.timeIntervalSinceNow / length))
            return MeterReading(
                cells: cells,
                lit: Int((fraction * Double(cells)).rounded(.up)),
                tint: Brand.fgMuted,
                label: Format.percent(fraction),
                ink: Brand.fgMuted,
                spoken: "\(Format.percent(fraction)) of the break left"
            )
        }
        let ratio = workRatio
        let percent = model.workTargetInForce ? Format.percent(ratio) : "--"
        let spokenPercent = model.workTargetInForce
            ? "\(Format.percent(ratio)) of the work target"
            : "no work target in force"
        if breakWanted {
            let over = model.continuousWork - model.workTarget
            let label = over >= 60 ? "+\(DurationText.short(over))" : "100%"
            return MeterReading(
                cells: cells,
                lit: cells,
                tint: model.indicator == .held ? Brand.amberFill.opacity(0.45) : Brand.amberFill,
                label: label,
                ink: Brand.amber,
                spoken: over >= 60 ? "\(DurationText.short(over)) past the work target" : "at the work target"
            )
        }
        let lit = Int((min(1, ratio) * Double(cells)).rounded(.down))
        if model.indicator == .working {
            return MeterReading(
                cells: cells, lit: lit, tint: Brand.fg.opacity(0.72),
                label: percent, ink: Brand.fgMuted, spoken: spokenPercent
            )
        }
        return MeterReading(
            cells: cells, lit: lit, tint: Brand.fgFaint.opacity(0.5),
            label: percent, ink: Brand.fgFaint, spoken: spokenPercent
        )
    }

    private static func meterCells(for target: TimeInterval) -> Int {
        let minutes = max(1, Int((target / 60).rounded()))
        for step in [1, 2, 3, 5, 10, 15, 30] where minutes <= step * maxMeterCells {
            return Int((Double(minutes) / Double(step)).rounded(.up))
        }
        return maxMeterCells
    }

    private var meter: some View {
        let reading = meterReading
        return HStack(alignment: .center, spacing: 8) {
            CellMeter(cells: reading.cells, lit: reading.lit, tint: reading.tint, brackets: true)
                .frame(height: 12)
            Text(reading.label)
                .font(Brand.mono(10.5, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(reading.ink)
                .frame(width: Self.meterLabel, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.spoken)
    }

    private func claim(_ line: WaitingLine) -> some View {
        let label = line.claim.prefix.isEmpty
            ? Text("")
            : Text("\(line.claim.prefix): ")
                .font(Brand.mono(11, weight: .semibold))
                .foregroundStyle(Self.ink(for: line.claim))
        return (label
            + Text("\(line.body).")
            .font(Brand.mono(11))
            .foregroundStyle(line.claim.prefix.isEmpty ? Brand.fg : Brand.fgMuted))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(line.text)
    }

    private static func ink(for claim: WaitingLine.Claim) -> Color {
        switch claim {
        case .waitingOnYou: return Brand.amber
        case .holdingOff, .notAskingYet: return Brand.fg
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

    private var breakWanted: Bool {
        switch model.indicator {
        case .breakDue, .escalating, .held, .backedOff: return true
        default: return false
        }
    }

    private var sinceRow: (key: String, value: String) {
        if let until = model.pausedUntil {
            let day = Calendar.current.isDate(until, inSameDayAs: .now) ? "" : " tomorrow"
            return ("paused", "until \(Self.clock(until))\(day)")
        }
        if let until = model.snoozeUntil, until > .now {
            return ("snoozed", "asking again at \(Self.clock(until))")
        }
        if let ends = model.breakEndsAt {
            return ("break", "\(Format.clock(model.policy.breakDurationTarget)) planned, until \(Self.clock(ends))")
        }
        if let since = model.timeSinceLastBreak {
            return ("last break", "\(DurationText.short(since)) ago")
        }
        return ("last break", "none recorded yet")
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 7) {
            TableRow(sinceRow.key) {
                Text(sinceRow.value)
                    .font(Brand.mono(11))
                    .foregroundStyle(Brand.fgMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            TableRow("app") {
                if model.applicationName.isEmpty {
                    Text("nothing sampled yet")
                        .font(Brand.mono(11))
                        .foregroundStyle(Brand.fgFaint)
                } else {
                    Text(model.applicationName)
                        .font(Brand.mono(11, weight: .semibold))
                        .foregroundStyle(Brand.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            TableRow("activity") {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        activity
                            .fixedSize()
                        Spacer(minLength: 0)
                        confidence
                            .fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        activity
                            .fixedSize(horizontal: false, vertical: true)
                        confidence
                            .fixedSize()
                    }
                }
            }

            TableRow("") {
                DisclosureLine(open: showEvidence, title: "why do you think that?") {
                    showEvidence.toggle()
                }
            }

            if showEvidence {
                evidence
                    .padding(.bottom, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activity: some View {
        Text(model.activityLabel)
            .font(Brand.mono(11, weight: .medium))
            .foregroundStyle(Brand.fg)
    }

    private var confidence: some View {
        let value = min(max(model.confidence, 0), 1)
        let confident = value >= 0.6
        return HStack(alignment: .center, spacing: 6) {
            Text("conf")
                .font(Brand.mono(10))
                .foregroundStyle(Brand.fgFaint)
            Text(String(format: "%.2f", value))
                .font(Brand.mono(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(confident ? Brand.fg : Brand.fgMuted)
            CellMeter(
                cells: 10,
                lit: Int((value * 10).rounded(.down)),
                tint: confident ? Brand.running : Brand.fgFaint
            )
            .frame(width: 39, height: 7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("confidence \(Format.percent(value))")
    }

    private var evidence: some View {
        VStack(alignment: .leading, spacing: 5) {
            if model.evidenceLines.isEmpty {
                TableRow("") {
                    Text("No evidence either way yet.")
                        .font(Brand.mono(10.5))
                        .foregroundStyle(Brand.fgMuted)
                }
            }
            ForEach(model.evidenceLines) { line in
                evidenceRow(
                    Format.logOdds(line.logOdds),
                    ink: line.logOdds >= 0 ? Brand.running : Brand.fgFaint,
                    line.summary
                )
            }
            ForEach(model.caveats, id: \.self) { caveat in
                evidenceRow("!", ink: Brand.amber, caveat)
            }
            if let finished = model.finishedCommand {
                evidenceRow("\u{21B5}", ink: Brand.fgMuted, "\(finished), a natural pause")
            }
        }
    }

    private func evidenceRow(_ mark: String, ink: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(mark)
                .font(Brand.mono(10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(ink)
                .frame(width: Self.keyColumn, alignment: .leading)
            Text(text)
                .font(Brand.mono(10.5))
                .foregroundStyle(Brand.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    primary
                    meetingControl
                }
                VStack(alignment: .leading, spacing: 6) {
                    primary
                    meetingControl
                }
            }

            if model.pausedUntil != nil, !model.isOnBreak {
                railLink("Take a break now") { model.takeBreakNow() }
            }

            if let version = model.updates.state.offeredVersion {
                railLink("Update to \(version)…") { openAbout() }
            }
        }
    }

    private func railLink(_ title: String, action: @escaping () -> Void) -> some View {
        TerminalButton(title, style: .quiet, mark: Self.command, action: action)
            .padding(.leading, -TerminalButton.markInset)
    }

    @ViewBuilder
    private var primary: some View {
        if model.isOnBreak {
            TerminalButton("Resume · SIGCONT", style: .filled, mark: Self.command) {
                model.endBreak()
            }
        } else if model.pausedUntil != nil {
            TerminalButton("Resume", style: .outlined, mark: Self.command) {
                model.resume()
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
    private var meetingControl: some View {
        if model.callHoldSummary != nil {
            TerminalButton("Not in a meeting", style: .outlined, mark: Self.command) {
                model.clearMeetingHold()
            }
            .overlay(releaseRing)
        } else if model.inputDeviceIsHoldingABreak {
            TerminalButton(model.ignoreInputDeviceLabel, style: .outlined, mark: Self.command) {
                model.clearMeetingHold()
            }
            .overlay(releaseRing)
        } else if model.settings.holdBreaksDuringCalls {
            TerminalButton("I'm in a meeting", style: .outlined, mark: Self.command) {
                model.assertMeeting()
            }
        }
    }

    private var releaseRing: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Brand.amber, lineWidth: 1)
            .allowsHitTesting(false)
    }

    private var commandBar: some View {
        HStack(spacing: 2) {
            if model.pausedUntil == nil {
                TerminalButton("Pause · 1h", style: .quiet) { model.pause(for: AppModel.hourPause) }
                TerminalButton("Pause · today", style: .quiet) { model.pauseUntilTomorrow() }
                    .accessibilityLabel("Pause for the rest of today")
            }
            TerminalButton("Settings…", style: .quiet) { openSettings() }
            Spacer(minLength: 0)
            TerminalButton("Quit", style: .quiet) { NSApp.terminate(nil) }
        }
    }

    private var uptime: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Kicker("uptime · today")
                Spacer(minLength: 0)
                if let summary = recordedToday {
                    (Text(DurationText.short(summary.totalActiveWork))
                        .font(Brand.mono(11, weight: .semibold))
                        .foregroundStyle(Brand.fg)
                        + Text(" active")
                        .font(Brand.mono(10.5))
                        .foregroundStyle(Brand.fgMuted))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }

            if let summary = recordedToday {
                VStack(alignment: .leading, spacing: 6) {
                    if let top = summary.topApplication, top.seconds > 0, summary.totalActiveWork > 0 {
                        share(of: top, in: summary)
                    }
                    stats(for: summary)
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

    private var recordedToday: DailySummary? {
        guard let summary = model.todaySummary, !summary.isEmptyDay else { return nil }
        return summary
    }

    private func share(of top: (bundleID: String, seconds: TimeInterval), in summary: DailySummary) -> some View {
        let name = Self.displayName(for: top.bundleID)
        let fraction = min(1, top.seconds / summary.totalActiveWork)
        return TableRow("top") {
            HStack(alignment: .center, spacing: 8) {
                Text(name.lowercased())
                    .font(Brand.mono(11, weight: .medium))
                    .foregroundStyle(Brand.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 104, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                CellMeter(cells: 20, lit: Int((fraction * 20).rounded()), tint: Brand.fgMuted)
                    .frame(height: 7)
                Text(DurationText.short(top.seconds))
                    .font(Brand.mono(11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Brand.fg)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(name), \(DurationText.short(top.seconds)) of \(DurationText.short(summary.totalActiveWork)) active"
        )
    }

    private func stats(for summary: DailySummary) -> some View {
        let pairs = Self.dayStats(for: summary)
        let rows = stride(from: 0, to: pairs.count, by: 2).map { Array(pairs[$0..<min($0 + 2, pairs.count)]) }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { index, stat in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(stat.label)
                                .font(Brand.mono(10))
                                .foregroundStyle(Brand.fgFaint)
                                .frame(width: index == 0 ? Self.keyColumn : 54, alignment: .leading)
                            Text(stat.value)
                                .font(Brand.mono(11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Brand.fg)
                                .lineLimit(1)
                        }
                        .frame(width: index == 0 ? 162 : nil, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static func dayStats(for summary: DailySummary) -> [(value: String, label: String)] {
        var out: [(value: String, label: String)] = [
            (DurationText.short(summary.longestContinuousSession), "longest"),
            ("\(summary.breakCount)", summary.breakCount == 1 ? "break" : "breaks"),
        ]
        if let average = summary.averageBreakLength {
            out.append((DurationText.short(average), "avg break"))
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
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("*")
                .font(Brand.mono(10, weight: .semibold))
                .foregroundStyle(Brand.amber)
                .frame(width: 12, alignment: .leading)
                .accessibilityHidden(true)
            Text(text)
                .font(Brand.mono(10))
                .foregroundStyle(Brand.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private struct TableRow<Value: View>: View {
        let key: String
        @ViewBuilder let value: Value

        init(_ key: String, @ViewBuilder value: () -> Value) {
            self.key = key
            self.value = value()
        }

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(key)
                    .font(Brand.mono(10))
                    .foregroundStyle(Brand.fgFaint)
                    .frame(width: MenuBarView.keyColumn, alignment: .leading)
                    .accessibilityHidden(key.isEmpty)
                value
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: key.isEmpty ? .contain : .combine)
        }
    }
}

struct CellMeter: View {
    let cells: Int
    let lit: Int
    var tint: Color = Brand.amberFill
    var track: Color = Brand.surfaceHi
    var brackets = false
    var ink: Color = Brand.fgFaint

    @Environment(\.displayScale) private var scale

    nonisolated fileprivate static let bracketWidth: CGFloat = 5
    nonisolated fileprivate static let bracketGap: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let grid = Grid(width: geometry.size.width, cells: cells, brackets: brackets, scale: scale)
            let split = min(max(0, lit), cells)
            ZStack(alignment: .leading) {
                if brackets {
                    Bracket(opening: true)
                        .stroke(ink, lineWidth: 1)
                        .frame(width: Self.bracketWidth)
                    Bracket(opening: false)
                        .stroke(ink, lineWidth: 1)
                        .frame(width: Self.bracketWidth)
                        .offset(x: geometry.size.width - Self.bracketWidth)
                }
                Cells(grid: grid, range: 0..<split)
                    .fill(tint)
                Cells(grid: grid, range: split..<cells)
                    .fill(track)
            }
        }
        .accessibilityHidden(true)
    }

    private struct Grid {
        let pitch: CGFloat
        let cell: CGFloat
        let originX: CGFloat
        let scale: CGFloat

        init(width: CGFloat, cells: Int, brackets: Bool, scale: CGFloat) {
            let margin = brackets ? CellMeter.bracketWidth + CellMeter.bracketGap : 0
            let count = CGFloat(max(1, cells))
            let inner = max(0, width - 2 * margin)
            var gap: CGFloat = 2
            var pitch = (inner + gap) / count
            if pitch < 6 {
                gap = 1
                pitch = (inner + gap) / count
            }
            self.pitch = pitch
            self.cell = max(1, (pitch - gap).rounded())
            self.originX = margin
            self.scale = max(1, scale)
        }

        func x(_ index: Int) -> CGFloat {
            ((originX + CGFloat(index) * pitch) * scale).rounded() / scale
        }
    }

    private struct Cells: Shape {
        let grid: Grid
        let range: Range<Int>

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let radius = min(1.5, grid.cell / 4)
            for index in range {
                path.addRoundedRect(
                    in: CGRect(x: rect.minX + grid.x(index), y: rect.minY, width: grid.cell, height: rect.height),
                    cornerSize: CGSize(width: radius, height: radius),
                    style: .continuous
                )
            }
            return path
        }
    }

    private struct Bracket: Shape {
        let opening: Bool

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let spine = opening ? rect.minX + 0.5 : rect.maxX - 0.5
            let arm = opening ? rect.maxX : rect.minX
            path.move(to: CGPoint(x: arm, y: rect.minY + 0.5))
            path.addLine(to: CGPoint(x: spine, y: rect.minY + 0.5))
            path.addLine(to: CGPoint(x: spine, y: rect.maxY - 0.5))
            path.addLine(to: CGPoint(x: arm, y: rect.maxY - 0.5))
            return path
        }
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
            .foregroundStyle(hovering || open ? Brand.fg : Brand.fgMuted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
