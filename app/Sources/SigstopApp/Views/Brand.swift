import AppKit
import SwiftUI

/// The two things the app's own surfaces share with the website: one amber and one mark.
///
/// Pulled out of `MenuBarIcon` so the About pane can draw the same mark at 40pt without
/// either copy of the colour drifting from the other. `MenuBarIcon` keeps its own tuned
/// geometry — a 14pt menu bar glyph and a 40pt identity mark want different stroke weights
/// and corner radii, and sharing the shape would have meant one of them looking wrong.
enum Brand {

    /// Resolved per appearance rather than baked in, for the reason `MenuBarIcon`
    /// documents at length: #f5a524 is the site's amber and reads well on dark, but it is
    /// roughly 1.9:1 on white, which is illegible for small text and thin strokes. Light
    /// mode gets the darker amber the site already uses for amber-on-white.
    static let amber = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.961, green: 0.647, blue: 0.141, alpha: 1)  // #f5a524
            : NSColor(srgbRed: 0.541, green: 0.306, blue: 0.000, alpha: 1)  // #8a4e00
    })

    /// The product's typeface, with a real fallback chain rather than a hope.
    ///
    /// JetBrains Mono is what the site sets and what most of this app's audience already
    /// has installed; the app does not ship or download it, because a font CDN is a
    /// network call and bundling a typeface for a 2 MB utility is not a trade worth
    /// making. `Font.custom(_:size:)` falls back to the system font silently when the
    /// family is absent, which would lose the monospacing, so the fallback is explicit:
    /// try JetBrains Mono, then SF Mono, then whatever the system calls monospaced.
    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        let candidates = ["JetBrains Mono", "JetBrainsMono-Regular", "SF Mono", "SFMono-Regular"]
        for family in candidates {
            if let font = NSFont(name: family, size: size) {
                return Font(NSFontManager.shared.convert(font, toHaveTrait: traits(for: weight)))
            }
        }
        return Font(NSFont.monospacedSystemFont(ofSize: size, weight: weight))
    }

    private static func traits(for weight: NSFont.Weight) -> NSFontTraitMask {
        weight >= .semibold ? .boldFontMask : .unboldFontMask
    }
}

/// The `SIGSTOP` glyph at identity size: two bars, a process paused and intact.
///
/// `fill` is 0…1 and is drawn, not decorative — the About pane shows it half filled
/// because a half-filled pair is what the mark means, and a solid pair would read as
/// "a break is due" to anyone who has watched the menu bar for an afternoon.
struct BrandMark: View {
    var size: CGFloat = 40
    var fill: Double = 0.5

    var body: some View {
        HStack(spacing: size * 0.22) {
            bar
            bar
        }
        .frame(width: size * 0.92, height: size)
        .foregroundStyle(Brand.amber)
        .accessibilityHidden(true)
    }

    private var bar: some View {
        GeometryReader { geometry in
            let shape = RoundedRectangle(cornerRadius: size * 0.1, style: .continuous)
            ZStack(alignment: .bottom) {
                shape.strokeBorder(lineWidth: max(1.5, size * 0.05))
                shape.frame(height: geometry.size.height * min(1, max(0, fill)))
            }
        }
    }
}

/// A flat, dense, amber-on-transparent button.
///
/// `Button(.bordered)` is the thing that made the old About pane look like a system
/// preference pane, so nothing in the redesigned one uses it. This is a rectangle with a
/// 1pt border and monospaced text, which is the same visual grammar as `MenuBarView`'s
/// rows and the site's terminal blocks.
struct TerminalButton: View {
    let title: String
    var prominent: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Brand.mono(11, weight: prominent ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(hovering && enabled ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(
                    prominent && enabled ? AnyShapeStyle(Brand.amber.opacity(0.55)) : AnyShapeStyle(.quaternary),
                    lineWidth: 1
                )
        )
        .onHover { hovering = $0 }
        .disabled(!enabled)
    }

    private var foreground: AnyShapeStyle {
        guard enabled else { return AnyShapeStyle(.tertiary) }
        return prominent ? AnyShapeStyle(Brand.amber) : AnyShapeStyle(.primary)
    }
}

/// A determinate or indeterminate bar in the app's own vocabulary.
///
/// `ProgressView` draws the system's blue capsule, which would be the one non-amber
/// accent in the pane and would read as borrowed. Indeterminate is a slow amber sweep
/// rather than a spinner, and it is static under Reduced Motion — an animation nobody
/// asked for, in a window somebody opened to read two lines, is exactly the kind of thing
/// this app is supposed to not do.
struct TransferBar: View {
    /// `nil` means the length is unknown.
    let fraction: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(.quaternary)
                if let fraction {
                    Rectangle()
                        .fill(Brand.amber)
                        .frame(width: geometry.size.width * min(1, max(0, fraction)))
                } else if reduceMotion {
                    Rectangle().fill(Brand.amber.opacity(0.45))
                } else {
                    Rectangle()
                        .fill(Brand.amber)
                        .frame(width: geometry.size.width * 0.3)
                        .offset(x: sweep ? geometry.size.width * 0.7 : 0)
                        .animation(
                            .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                            value: sweep
                        )
                        .onAppear { sweep = true }
                }
            }
        }
        .frame(height: 3)
        .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
    }
}
