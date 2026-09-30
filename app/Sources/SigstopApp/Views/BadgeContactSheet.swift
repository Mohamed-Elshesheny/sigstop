import AppKit
import SigstopCore
import SwiftUI

struct BadgeContactSheet: View {

    private static let rowSamples: [(Badge, Bool)] = [
        (Badge.badge(.stoppedOnce), true),
        (Badge.badge(.sigDFL), true),
        (Badge.badge(.provablyHalts), false),
        (Badge.badge(.stoppedHundred), false),
        (Badge.badge(.earlyReturn), false),
    ]

    private static let sampleEvidence = BadgeEvidence(
        breaksTaken: 37, cleanDays: 3, reflexAccepts: 2, earlyDays: 2
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            section("earned, 28pt") {
                marks(size: 28, unlocked: true)
            }
            section("locked, 28pt") {
                marks(size: 28, unlocked: false)
            }
            section("56pt, earned") {
                marks(size: 56, unlocked: true)
            }
            section("56pt, locked") {
                marks(size: 56, unlocked: false)
            }
            section("the row, as it ships") {
                VStack(spacing: 0) {
                    ForEach(Array(Self.rowSamples.enumerated()), id: \.offset) { _, sample in
                        BadgeRow(
                            badge: sample.0,
                            earned: sample.1 ? CalendarDay(year: 2026, month: 9, day: 20) : nil,
                            progress: sample.0.progress(Self.sampleEvidence)
                        )
                    }
                }
                .frame(width: 460, alignment: .leading)
                .background(Brand.bgRaised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(28)
        .background(Brand.bg)
        .fixedSize()
    }

    private func marks(size: CGFloat, unlocked: Bool) -> some View {
        HStack(spacing: 16) {
            ForEach(Badge.all) { badge in
                VStack(spacing: 6) {
                    BadgeMark(motif: badge.motif, unlocked: unlocked, size: size)
                    Text(badge.title)
                        .font(Brand.mono(7))
                        .foregroundStyle(Brand.fgFaint)
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(width: max(66, size + 38))
            }
        }
    }

    private func section<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label)
                .font(Brand.mono(9, weight: .medium))
                .foregroundStyle(Brand.fgMuted)
            content()
        }
    }
}

enum PanelRenderer {

    static let sampleSummary = DailySummary(
        day: CalendarDay(year: 2026, month: 9, day: 20),
        totalActiveWork: 6 * 3600 + 12 * 60,
        activeWorkByActivity: [Activity.coding.rawValue: 6 * 3600 + 12 * 60 as TimeInterval],
        applicationDistribution: [
            "com.apple.dt.Xcode": 4 * 3600 + 5 * 60 as TimeInterval,
            "com.google.Chrome": 2 * 3600 + 7 * 60 as TimeInterval,
        ],
        longestContinuousSession: 97 * 60,
        breakCount: 5,
        totalBreakTime: 31 * 60,
        breaksAccepted: 4,
        breaksIdleInferred: 1,
        breakOpportunities: 8,
        honoredOpportunities: 6,
        excludedOpportunities: 1,
        notificationsDelivered: 7,
        sessionCount: 1
    )

    private static let codingEvidence: [AppModel.EvidenceLine] = [
        .init(id: "editor.frontmost", summary: "Xcode is the frontmost app", logOdds: 1.6),
        .init(id: "title.parsed", summary: "the window title names a file, SessionClock.swift", logOdds: 1.1),
        .init(id: "title.project", summary: "the window title names a project, sigstop", logOdds: 0.5),
        .init(id: "input.recent", summary: "you touched the keyboard or trackpad 4s ago", logOdds: 0.4),
    ]

    @MainActor
    private static func stage(_ stage: AppModel.RenderStage) -> AppModel {
        let model = AppModel()
        model.stageForRendering(stage)
        return model
    }

    private static let meetingEvidence: [AppModel.EvidenceLine] = [
        .init(id: "mic.live", summary: "a microphone is live right now (zoom.us)", logOdds: 2.1),
        .init(id: "app.callCapable", summary: "zoom.us is a conferencing app", logOdds: 1.4),
        .init(id: "input.quiet", summary: "no keyboard or trackpad input for 3m", logOdds: -0.3),
    ]

    @MainActor
    private static func variants() -> [(String, MenuBarView)] {
        let now = Date()
        let due = stage(.init(
            indicator: .breakDue, engineStateName: "breakDue", statusWord: "break due",
            continuousWork: 47 * 60 + 12, sinceLastBreak: 52 * 60,
            application: "Xcode", activity: "coding", confidence: 0.86, evidence: codingEvidence,
            waiting: WaitingLine(.waitingOnYou, "a break is due and nothing is holding it"),
            summary: sampleSummary
        ))
        let working = stage(.init(
            continuousWork: 31 * 60 + 40, sinceLastBreak: 33 * 60,
            application: "Xcode", activity: "coding", confidence: 0.86, evidence: codingEvidence,
            finishedCommand: "swift test finished",
            waiting: WaitingLine(.notAskingYet, "next break in 13m of work"),
            summary: sampleSummary
        ))
        let breakEnds = now.addingTimeInterval(4 * 60 + 37)
        let onBreak = stage(.init(
            indicator: .onBreak, engineStateName: "breakActive", statusWord: "stopped",
            continuousWork: 0, sinceLastBreak: nil,
            application: "Xcode", activity: "coding", confidence: 0.71, evidence: codingEvidence,
            waiting: WaitingLine(.waitingOnYou, "the break runs to \(MenuBarView.clock(breakEnds))"),
            breakEndsAt: breakEnds,
            summary: sampleSummary
        ))
        let snoozeEnds = now.addingTimeInterval(10 * 60)
        let snoozed = stage(.init(
            indicator: .held, engineStateName: "snoozed", statusWord: "snoozed",
            continuousWork: 49 * 60 + 5, sinceLastBreak: 54 * 60,
            application: "Terminal", activity: "in the terminal", confidence: 0.64,
            waiting: WaitingLine(.waitingOnYou, "you snoozed it, asking again at \(MenuBarView.clock(snoozeEnds))"),
            snoozeUntil: snoozeEnds,
            summary: sampleSummary
        ))
        let pauseEnds = now.addingTimeInterval(3600)
        let paused = stage(.init(
            indicator: .quiet, engineStateName: "quiet", statusWord: "paused",
            continuousWork: 12 * 60, sinceLastBreak: 20 * 60,
            application: "Google Chrome", activity: "browsing", confidence: 0.42,
            waiting: WaitingLine(.notAskingYet, "you paused it until \(MenuBarView.clock(pauseEnds))"),
            pausedUntil: pauseEnds, targetInForce: false,
            summary: sampleSummary
        ))
        let meeting = stage(.init(
            indicator: .held, engineStateName: "breakDue", statusWord: "break due",
            continuousWork: 46 * 60 + 30, sinceLastBreak: 58 * 60,
            application: "zoom.us", activity: "in a meeting", confidence: 0.88, evidence: meetingEvidence,
            waiting: WaitingLine(.holdingOff, "you said you are in a meeting"),
            meetingHeld: true,
            summary: sampleSummary
        ))
        let micStops = now.addingTimeInterval(18 * 60)
        let mic = stage(.init(
            indicator: .held, engineStateName: "breakDue", statusWord: "break due",
            continuousWork: 52 * 60 + 10, sinceLastBreak: 61 * 60,
            application: "Slack", activity: "in chat", confidence: 0.58,
            waiting: WaitingLine(
                .holdingOff,
                "the mic has been open 12m with nothing call-shaped running. It stops holding at "
                    + MenuBarView.clock(micStops)
            ),
            inputDeviceHeld: true,
            summary: sampleSummary
        ))
        let long = stage(.init(
            indicator: .escalating, engineStateName: "ignored", statusWord: "escalating",
            continuousWork: 1 * 3600 + 18 * 60 + 44, sinceLastBreak: 83 * 60,
            application: "Visual Studio Code - Insiders",
            activity: "pair-programming with an AI", confidence: 0.55, evidence: codingEvidence,
            caveats: ["Window titles are off, Accessibility is not granted. Everything still works without it."],
            waiting: WaitingLine(.waitingOnYou, "you waved the last one off, and it has been due 33m"),
            footnote: "New badge: SIG_DFL. Settings, Badges has the rest.",
            summary: sampleSummary
        ))
        long.updates.stageForRendering(offering: "0.2.2")
        return [
            ("", MenuBarView(model: AppModel())),
            ("-staged", MenuBarView(model: due)),
            ("-working", MenuBarView(model: working, expandEvidence: true)),
            ("-break", MenuBarView(model: onBreak)),
            ("-snoozed", MenuBarView(model: snoozed)),
            ("-paused", MenuBarView(model: paused)),
            ("-meeting", MenuBarView(model: meeting)),
            ("-mic", MenuBarView(model: mic)),
            ("-long", MenuBarView(model: long, expandEvidence: true)),
        ]
    }

    @MainActor
    static func runAndExit(stem: String) -> Never {
        let base = stem.hasSuffix(".png") ? String(stem.dropLast(4)) : stem
        for (variant, view) in variants() {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let url = URL(fileURLWithPath: "\(base)\(variant)-\(suffix).png")
                do {
                    try BadgeSheetRenderer.write(view, appearance: appearance, to: url)
                    FileHandle.standardOutput.write(Data("\(url.path)\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                    exit(1)
                }
            }
        }
        exit(0)
    }
}

enum IconRenderer {

    private static let states: [(IndicatorState, Double)] = [
        (.working, 0), (.working, 0.5), (.working, 0.9), (.breakDue, 1), (.escalating, 1),
        (.held, 1), (.backedOff, 1), (.onBreak, 0), (.idle, 0.4), (.quiet, 0.4),
    ]

    @MainActor
    static func runAndExit(stem: String) -> Never {
        let base = stem.hasSuffix(".png") ? String(stem.dropLast(4)) : stem
        for (suffix, dark) in [("light", false), ("dark", true)] {
            let url = URL(fileURLWithPath: "\(base)-\(suffix).png")
            let renderer = ImageRenderer(content: sheet(dark: dark))
            renderer.scale = 8
            guard let image = renderer.cgImage else {
                FileHandle.standardError.write(Data("render failed: no image\n".utf8))
                exit(1)
            }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("render failed: no png\n".utf8))
                exit(1)
            }
            do {
                try data.write(to: url)
                FileHandle.standardOutput.write(Data("\(url.path)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                exit(1)
            }
        }
        exit(0)
    }

    private static func sheet(dark: Bool) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                VStack(spacing: 4) {
                    MenuBarIcon(fraction: state.1, indicator: state.0, dark: dark)
                        .frame(width: 18, height: 18)
                    Text(state.0.rawValue)
                        .font(.system(size: 4))
                        .foregroundStyle(dark ? Color.white : Color.black)
                }
            }
        }
        .padding(8)
        .background(dark ? Color(white: 0.12) : Color(white: 0.93))
    }
}

enum SettingsPaneRenderer {

    @MainActor
    static func runAndExit(pane: String, stem: String) -> Never {
        guard let chosen = SettingsView.Pane(rawValue: pane) else {
            let names = SettingsView.Pane.allCases.map(\.rawValue).joined(separator: ", ")
            FileHandle.standardError.write(Data("no pane named '\(pane)'; one of: \(names)\n".utf8))
            exit(2)
        }
        let base = stem.hasSuffix(".png") ? String(stem.dropLast(4)) : stem
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let url = URL(fileURLWithPath: "\(base)-\(suffix).png")
            do {
                try BadgeSheetRenderer.write(
                    SettingsView(model: AppModel(), initialPane: chosen)
                        .frame(width: SettingsView.size.width, height: SettingsView.size.height),
                    appearance: appearance,
                    to: url
                )
                FileHandle.standardOutput.write(Data("\(url.path)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                exit(1)
            }
        }
        exit(0)
    }
}

enum PromptRenderer {

    @MainActor
    static func runAndExit(stem: String, templateID: String) -> Never {
        let base = stem.hasSuffix(".png") ? String(stem.dropLast(4)) : stem
        guard let corpus = try? Corpus.loadBundled(),
              let template = corpus.templates.first(where: { $0.id == templateID })
        else {
            FileHandle.standardError.write(Data("no corpus line with id '\(templateID)'\n".utf8))
            exit(2)
        }
        let cases: [(String, EscalationLevel, PromptChannel, [TimeInterval], TimeInterval, PromptFollowUp)] = [
            ("l1", .first, .notification, [300, 600, 900], 3, .anotherRung),
            ("l1-armed", .first, .notification, [300, 600, 900], 0, .anotherRung),
            ("l1-nosnooze", .first, .notification, [], 3, .cooldown),
            ("l1-capped", .first, .notification, [], 3, .quietForTheDay),
            ("l2", .second, .notification, [], 3, .anotherRung),
            ("l2-last", .second, .notification, [], 3, .cooldown),
            ("l3", .third, .notificationWithSound, [], 3, .anotherRung),
            ("l4", .incident, .panel, [], 3, .cooldown),
            ("l4-battery", .incident, .notification, [], 3, .cooldown),
        ]
        let minutes = SigstopSettings.default.breakDurationMinutes
        let text = template.text
            .replacingOccurrences(of: "{breakLength}", with: SlotResolver.spokenLength(minutes: minutes))
            .replacingOccurrences(of: "{breakSeconds}", with: String(minutes * 60))
        for (suffix, level, channel, snooze, skipArmsAfter, ifIgnored) in cases {
            let request = PromptRequest(
                cycle: CycleID.initial, level: level, channel: channel,
                at: Date(timeIntervalSince1970: 1_758_500_000), continuousWork: 47 * 60,
                snoozeOffered: snooze, ifIgnored: ifIgnored
            )
            let message = RenderedMessage(
                templateID: template.id, title: nil, text: text,
                tone: template.tone, category: template.category, escalation: level,
                isFallback: false
            )
            let url = URL(fileURLWithPath: "\(base)-\(suffix).png")
            do {
                try BadgeSheetRenderer.write(
                    FallbackPromptView(
                        request: request, message: message, skipArmsAfter: skipArmsAfter,
                        onTake: {}, onIgnore: {}, onSkip: {}
                    )
                    .frame(width: 1280, height: 800),
                    appearance: .darkAqua,
                    to: url
                )
                FileHandle.standardOutput.write(Data("\(url.path)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                exit(1)
            }
        }
        exit(0)
    }
}

struct FaceContactSheet: View {

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            section("72pt, the prompt and the break screen") {
                faces(size: 72)
            }
        }
        .padding(28)
        .background(Brand.bg)
        .fixedSize()
    }

    private func faces(size: CGFloat) -> some View {
        HStack(spacing: 24) {
            ForEach(FaceMood.allCases, id: \.self) { mood in
                VStack(spacing: 10) {
                    FaceMark(mood: mood, size: size)
                    Text(mood.rawValue)
                        .font(Brand.mono(9))
                        .foregroundStyle(Brand.fgMuted)
                }
                .frame(width: max(96, size + 24))
            }
        }
    }

    private func section<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label)
                .font(Brand.mono(9, weight: .medium))
                .foregroundStyle(Brand.fgMuted)
            content()
        }
    }
}

enum BreakRenderer {

    @MainActor
    static func runAndExit(stem: String) -> Never {
        let base = stem.hasSuffix(".png") ? String(stem.dropLast(4)) : stem
        let content = BreakContent(prompt: "Stand up. The stack is saved.", quest: "Refill your water.")
        let cases: [(String, TimeInterval)] = [("start", 4 * 60 + 37), ("last-minute", 42)]
        for (suffix, remaining) in cases {
            let url = URL(fileURLWithPath: "\(base)-\(suffix).png")
            do {
                try BadgeSheetRenderer.write(
                    BreakScreen(
                        endsAt: Date().addingTimeInterval(remaining),
                        duration: 5 * 60,
                        content: content,
                        onResume: {}
                    )
                    .frame(width: 1280, height: 800),
                    appearance: .darkAqua,
                    to: url
                )
                FileHandle.standardOutput.write(Data("\(url.path)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                exit(1)
            }
        }
        let faces = URL(fileURLWithPath: "\(base)-faces.png")
        do {
            try BadgeSheetRenderer.write(FaceContactSheet(), appearance: .darkAqua, to: faces)
            FileHandle.standardOutput.write(Data("\(faces.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}

enum BadgeSheetRenderer {

    @MainActor
    static func runAndExit(stem: String) -> Never {
        let base = stem.hasSuffix(".png") ? String(stem.dropLast(4)) : stem
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let url = URL(fileURLWithPath: "\(base)-\(suffix).png")
            do {
                try write(BadgeContactSheet(), appearance: appearance, to: url)
                FileHandle.standardOutput.write(Data("\(url.path)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                exit(1)
            }
        }
        exit(0)
    }

    @MainActor
    static func write(_ view: some View, appearance name: NSAppearance.Name, to url: URL) throws {
        let hosting = NSHostingView(rootView: view.environment(\.locale, DisplayLocale.english(from: .current)))
        hosting.appearance = NSAppearance(named: name)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: name)
        window.contentView = hosting
        window.displayIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}
