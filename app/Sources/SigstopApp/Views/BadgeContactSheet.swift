import AppKit
import SigstopCore
import SwiftUI

/// A contact sheet of every mark in every state, rendered to a file by
/// `sigstop --render-badges <path>`.
///
/// Badge art is the one part of this app that cannot be judged from source. A polygon
/// with a letter knocked out of it reads fine in a diff and looks like a sticker on
/// screen, and the only way anyone found that out was by looking. So looking is a
/// command now rather than a favour: build, run one line, open a PNG, and see all
/// twenty states at both sizes next to the real row layout they ship in.
///
/// The two sections at 28pt are the important ones, because 28 is what ships and because
/// ten objects laid side by side is the only view that answers the question the set has
/// to pass: can you tell them apart without reading the titles under them.
///
/// It renders through a real off-screen window rather than `ImageRenderer` because
/// `Brand`'s colours are `NSColor` values that resolve per appearance, and an
/// `ImageRenderer` has no appearance to resolve against: it silently picks one and the
/// light sheet comes out wearing the dark palette. A window has an `appearance`, and
/// `cacheDisplay` draws the hierarchy under it.
struct BadgeContactSheet: View {

    /// A pair of badges, one earned and one not, for the row-layout section.
    private static let rowSamples: [(Badge, Bool)] = [
        (Badge.badge(.stoppedOnce), true),
        (Badge.badge(.sigDFL), true),
        (Badge.badge(.provablyHalts), false),
        (Badge.badge(.stoppedHundred), false),
    ]

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
                            earned: sample.1 ? CalendarDay(year: 2026, month: 9, day: 20) : nil
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

/// Renders the menu bar panel to a file. Same reason as the others: it is the surface the
/// user sees most and the hardest one to look at, because it only exists while the status
/// item is clicked.
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

/// Renders a Settings pane to a file, the same way and for the same reason.
///
/// The About pane shipped two thirds empty with two of its own URLs rendered nowhere, and
/// nobody noticed because looking at it meant launching the app, clicking through to the
/// last tab and taking a screenshot by hand. One command is cheap enough to do every time.
enum SettingsPaneRenderer {

    @MainActor
    static func runAndExit(pane: String, stem: String) -> Never {
        let chosen = SettingsView.Pane(rawValue: pane) ?? .about
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

/// Renders the contact sheet in both appearances and writes two PNGs.
enum BadgeSheetRenderer {

    /// `--render-badges <path>` writes `<path>-light.png` and `<path>-dark.png`, or, if
    /// the path already ends in `.png`, `<stem>-light.png` and `<stem>-dark.png`.
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
