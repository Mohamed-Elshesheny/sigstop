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

    @MainActor
    static func runAndExit(stem: String) -> Never {
        let base = stem.hasSuffix(".png") ? String(stem.dropLast(4)) : stem
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let url = URL(fileURLWithPath: "\(base)-\(suffix).png")
            do {
                try BadgeSheetRenderer.write(
                    MenuBarView(model: AppModel()), appearance: appearance, to: url
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
    static func runAndExit(stem: String) -> Never {
        let base = stem.hasSuffix(".png") ? String(stem.dropLast(4)) : stem
        let cases: [(String, EscalationLevel, PromptChannel, [TimeInterval])] = [
            ("l1", .first, .notification, [300, 600, 900]),
            ("l1-nosnooze", .first, .notification, []),
            ("l2", .second, .panel, [300]),
            ("l4", .incident, .panel, []),
        ]
        for (suffix, level, channel, snooze) in cases {
            let request = PromptRequest(
                cycle: CycleID.initial, level: level, channel: channel,
                at: Date(timeIntervalSince1970: 1_758_500_000), continuousWork: 47 * 60,
                snoozeOffered: snooze
            )
            let message = RenderedMessage(
                templateID: "render", title: nil,
                text: "You have been at this for 47 minutes. The build will still be broken in five.",
                tone: .sarcastic, category: "render", escalation: level,
                isFallback: false, theatrical: false
            )
            let url = URL(fileURLWithPath: "\(base)-\(suffix).png")
            do {
                try BadgeSheetRenderer.write(
                    FallbackPromptView(request: request, message: message, onTake: {}, onIgnore: {}, onSkip: {})
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
        let hosting = NSHostingView(rootView: view)
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
