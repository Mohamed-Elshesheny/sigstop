import AppKit
import SwiftUI

/// The app's share of the design language the website defines in `web/src/app/globals.css`.
///
/// Every colour here is a token from that file, resolved per appearance rather than baked
/// in, so the panel, the settings window and the site are one system and not three
/// approximations of one. The palette is derived from the metaphor: a process is either
/// RUNNING (green) or in state T, suspended (amber). Amber is the single accent. Red is
/// reserved for escalation level 4 and nothing else — if everything is amber, nothing is.
enum Brand {

    // MARK: Surfaces and text

    static let bg = dynamic(light: 0xFBFBF9, dark: 0x08090B)
    static let bgRaised = dynamic(light: 0xFFFFFF, dark: 0x0E1013)
    static let surface = dynamic(light: 0xF4F4F1, dark: 0x131619)
    static let surfaceHi = dynamic(light: 0xE9E9E4, dark: 0x1A1E23)
    static let line = dynamic(light: 0xE7E7E1, dark: 0x21262D)
    static let lineHi = dynamic(light: 0xCFCFC7, dark: 0x2D343D)

    static let fg = dynamic(light: 0x17191C, dark: 0xE8EAED)
    static let fgMuted = dynamic(light: 0x53585E, dark: 0x9AA2AD)
    static let fgFaint = dynamic(light: 0x6B7177, dark: 0x656D78)

    // MARK: Signal colours

    /// A process that is alive. The terminal's own "this is running" green.
    static let running = dynamic(light: 0x15803D, dark: 0x3FB950)

    /// Amber as **ink**: text, strokes, thin bars. #f5a524 is the site's amber and reads
    /// on dark, but it is roughly 1.9:1 on white, which is illegible for small text and
    /// 1pt strokes, so light mode gets the darker amber the site uses for amber-on-white.
    static let amber = dynamic(light: 0x8A4E00, dark: 0xF5A524)

    /// Amber as a **fill**: buttons, the filled part of the mark. Stays vivid in both
    /// themes, because muting it to a brown loses the brand; contrast is solved by
    /// drawing near-black text on top (`onAmber`) instead of darkening the fill.
    static let amberFill = dynamic(light: 0xF0A020, dark: 0xF5A524)
    static let onAmber = dynamic(light: 0x1B1206, dark: 0x000000)

    /// Escalation level 4, `SIGSTOP`. The only red in the product.
    static let alert = dynamic(light: 0xC0322B, dark: 0xF85149)

    /// The dark palette as fixed values, for surfaces drawn over a dimmed screen. The
    /// break overlay sits on black whatever the system appearance is, so resolving its
    /// colours per appearance would give light-mode users grey-on-black text.
    enum Dark {
        static let fg = fixed(0xE8EAED)
        static let fgMuted = fixed(0x9AA2AD)
        static let fgFaint = fixed(0x656D78)
        static let line = fixed(0x2D343D)
        static let amber = fixed(0xF5A524)
        static let onAmber = fixed(0x000000)
    }

    // MARK: Type

    /// Monospaced, for everything machine-shaped: chrome, labels, numerals, signal names.
    ///
    /// JetBrains Mono is what the site sets and what most of this app's audience already
    /// has installed; the app does not ship or download it, because a font CDN is a
    /// network call and bundling a typeface for a 2 MB utility is not a trade worth
    /// making. `Font.custom(_:size:)` falls back to the system font silently when the
    /// family is absent, which would lose the monospacing, so the fallback is explicit:
    /// the JetBrains face for this weight, then the system's monospaced font at the same
    /// weight, which is what the menu bar clock and Terminal.app already use.
    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        if let font = NSFont(name: "JetBrainsMono-\(jetBrainsStyle(for: weight))", size: size) {
            return Font(font)
        }
        return Font(NSFont.monospacedSystemFont(ofSize: size, weight: weight))
    }

    /// The system sans, for prose: help text, the joke, anything meant to be read as a
    /// sentence rather than scanned as a value.
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    private static func jetBrainsStyle(for weight: NSFont.Weight) -> String {
        switch weight {
        case ..<NSFont.Weight.light: return "ExtraLight"
        case ..<NSFont.Weight.regular: return "Light"
        case ..<NSFont.Weight.medium: return "Regular"
        case ..<NSFont.Weight.semibold: return "Medium"
        case ..<NSFont.Weight.bold: return "SemiBold"
        default: return "Bold"
        }
    }

    // MARK: Resolution

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(isDark ? dark : light)
        })
    }

    private static func fixed(_ hex: UInt32) -> Color {
        Color(nsColor: nsColor(hex))
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - The mark

/// The `SIGSTOP` glyph: two bars, a process paused and intact.
///
/// `fill` is 0…1 and is drawn, not decorative. The outline is the whole session and the
/// fill is how much of it has elapsed, so the mark *is* the timer wherever it appears —
/// at 14pt in the menu bar, at 44pt beside the clock, at 40pt on the About pane. The
/// About pane shows it half filled because a half-filled pair is what the mark means; a
/// solid pair would read as "a break is due" to anyone who has watched the menu bar for
/// an afternoon.
struct BrandMark: View {
    var size: CGFloat = 40
    var fill: Double = 0.5
    /// The stroke colour: amber ink, so the outline keeps its contrast on white. The
    /// overlay passes the fixed dark amber because it draws on black.
    var tint: Color = Brand.amber
    /// The fill colour. Vivid in both themes, as the site draws it, because a mark that
    /// is a solid brown block in light mode has lost the brand; the ink-dark stroke around
    /// it is what carries the contrast. Identical to `tint` in dark mode.
    var fillTint: Color = Brand.amberFill

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: size * 0.22) {
            bar
            bar
        }
        .frame(width: size * 0.92, height: size)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: fill)
        .accessibilityHidden(true)
    }

    private var bar: some View {
        GeometryReader { geometry in
            let shape = RoundedRectangle(cornerRadius: size * 0.09, style: .continuous)
            ZStack(alignment: .bottom) {
                shape
                    .fill(fillTint)
                    .frame(height: geometry.size.height * min(1, max(0, fill)))
                shape.strokeBorder(tint, lineWidth: max(1.5, size * 0.045))
            }
        }
    }
}

// MARK: - Labels

/// A section marker in the site's grammar: 10pt monospaced, uppercase, letterspaced,
/// muted. It is not a heading in the System Settings sense and is not meant to be read
/// as one — it is a label on a block of terminal output.
struct Kicker: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Brand.mono(10, weight: .medium))
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(Brand.fgMuted)
    }
}

/// A dot that reads as a process state indicator, paired with text that says the same
/// thing. It never carries meaning alone.
struct StateDot: View {
    enum State { case running, suspend, alert, off }
    let state: State
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var colour: Color {
        switch state {
        case .running: return Brand.running
        case .suspend: return Brand.amber
        case .alert: return Brand.alert
        case .off: return Brand.fgFaint.opacity(0.6)
        }
    }
}

/// A hairline in the palette's own line colour. `Divider` draws the system separator,
/// which is a different grey in both themes and the one thing that most quickly makes
/// a designed pane look borrowed.
struct Rule: View {
    var body: some View {
        Rectangle()
            .fill(Brand.line)
            .frame(height: 1)
    }
}

// MARK: - Controls

/// A flat, dense, monospaced button in three weights.
///
/// `.filled` is amber with near-black text and is for the one action a surface exists
/// for — `SIGCONT` on the overlay, "Take it" on the prompt. `.outlined` is the ordinary
/// button. `.quiet` has no border at rest and is for a third action that should not
/// compete with the first two. `Button(.bordered)` is the thing that made the old panes
/// look like a system preference pane, so nothing here uses it.
struct TerminalButton: View {
    enum Style { case filled, outlined, quiet }

    let title: String
    var style: Style = .outlined
    var enabled: Bool = true
    var shortcut: KeyboardShortcut? = nil
    let action: () -> Void

    @State private var hovering = false

    init(
        _ title: String,
        style: Style = .outlined,
        enabled: Bool = true,
        shortcut: KeyboardShortcut? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.style = style
        self.enabled = enabled
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        let button = Button(action: action) {
            Text(title)
                .font(Brand.mono(11, weight: weight))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .background(background, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        )
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .disabled(!enabled)

        if let shortcut {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }

    /// Quiet buttons are the site's ghost links: regular weight, muted on a surface at rest, and only
    /// as bright as ordinary text under the pointer. They must never weigh as much as the
    /// primary control they sit under.
    private var weight: NSFont.Weight {
        switch style {
        case .filled: return .semibold
        case .outlined: return .medium
        case .quiet: return .regular
        }
    }

    private var foreground: Color {
        switch style {
        case .filled: return Brand.onAmber
        case .outlined: return Brand.fg
        case .quiet: return hovering ? Brand.fg : Brand.fgMuted
        }
    }

    private var background: Color {
        switch style {
        case .filled: return hovering && enabled ? Brand.amberFill.opacity(0.88) : Brand.amberFill
        case .outlined: return hovering && enabled ? Brand.surfaceHi : Brand.surface
        case .quiet: return hovering && enabled ? Brand.surfaceHi : Brand.surface
        }
    }

    private var border: Color {
        switch style {
        case .filled: return .clear
        case .outlined: return hovering && enabled ? Brand.fgFaint : Brand.lineHi
        case .quiet: return .clear
        }
    }
}

/// A switch in the palette rather than the system's tinted pill. Square-cornered on
/// purpose: the capsule is the one shape that most quickly says "iOS".
struct TerminalSwitch: View {
    @Binding var isOn: Bool
    var enabled: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: { isOn.toggle() }) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isOn ? Brand.amberFill : Brand.surfaceHi)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(isOn ? Color.clear : Brand.lineHi, lineWidth: 1)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isOn ? Brand.onAmber : Brand.fgFaint)
                    .frame(width: 12, height: 12)
                    .padding(3)
            }
            .frame(width: 34, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isOn)
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
        .accessibilityRepresentation {
            Toggle("", isOn: $isOn)
        }
    }
}

/// `[ − ]  45 min  [ + ]`. A stepper whose number is the thing you look at: the value is
/// set in 13pt semibold mono between the two controls instead of in a label beside a
/// pair of 8pt arrows.
struct TerminalStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    var unit: String = ""

    var body: some View {
        HStack(spacing: 0) {
            control("−", enabled: value - step >= range.lowerBound) {
                value = max(range.lowerBound, value - step)
            }
            Rectangle().fill(Brand.lineHi).frame(width: 1, height: 24)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value)")
                    .font(Brand.mono(13, weight: .semibold))
                    .foregroundStyle(Brand.fg)
                    .monospacedDigit()
                if !unit.isEmpty {
                    Text(unit)
                        .font(Brand.mono(10))
                        .foregroundStyle(Brand.fgMuted)
                }
            }
            .frame(minWidth: 62)
            .padding(.horizontal, 6)
            Rectangle().fill(Brand.lineHi).frame(width: 1, height: 24)
            control("+", enabled: value + step <= range.upperBound) {
                value = min(range.upperBound, value + step)
            }
        }
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Brand.lineHi, lineWidth: 1)
        )
        .accessibilityRepresentation {
            Stepper(value: $value, in: range, step: step) { Text("\(value) \(unit)") }
        }
    }

    private func control(_ glyph: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(Brand.mono(13, weight: .medium))
                .foregroundStyle(enabled ? Brand.fg : Brand.fgFaint.opacity(0.5))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
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
    var tint: Color = Brand.amberFill
    var track: Color = Brand.surfaceHi
    var height: CGFloat = 3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(track)
                if let fraction {
                    Rectangle()
                        .fill(tint)
                        .frame(width: geometry.size.width * min(1, max(0, fraction)))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: fraction)
                } else if reduceMotion {
                    Rectangle().fill(tint.opacity(0.45))
                } else {
                    Rectangle()
                        .fill(tint)
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
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
    }
}

// MARK: - Layout

/// Left-to-right, wrapping. Used for the `jobs` statistics, which are a handful of short
/// monospaced facts that should pack like tags rather than stack like paragraphs.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return arrange(in: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(in: bounds.width, subviews: subviews)
        for (index, origin) in arrangement.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(in width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
