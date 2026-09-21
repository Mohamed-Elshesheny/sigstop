import AppKit
import SwiftUI

/// The app's share of the design language it shares with the landing site, whose tokens live
/// in `src/app/globals.css` in the `sigstop-web` repository.
///
/// Every colour here is one of those tokens, resolved per appearance rather than baked in, so
/// the panel, the settings window and the site are one system and not three approximations of
/// one. Nothing reads across at build time: the two are kept in step by hand, and the site is
/// the place the palette is decided.
///
/// The palette is derived from the metaphor: a process is either RUNNING (green) or in state
/// T, suspended (amber). Amber is the single accent. Red is reserved for escalation level 4
/// and nothing else, if everything is amber, nothing is.
enum Brand {

    // MARK: Surfaces and text

    static let bg = dynamic(light: 0xFBFBF9, dark: 0x101317)
    static let bgRaised = dynamic(light: 0xFFFFFF, dark: 0x171A1F)
    static let surface = dynamic(light: 0xF4F4F1, dark: 0x1D2127)
    static let surfaceHi = dynamic(light: 0xE9E9E4, dark: 0x262B32)
    static let line = dynamic(light: 0xE7E7E1, dark: 0x2B313A)
    static let lineHi = dynamic(light: 0xCFCFC7, dark: 0x3A424D)

    static let fg = dynamic(light: 0x17191C, dark: 0xE8EAED)
    static let fgMuted = dynamic(light: 0x53585E, dark: 0x9AA2AD)

    /// Not for text. On `bgRaised` in dark this measures 3.33:1, under the 4.5:1 that
    /// 9 to 12 point type needs, so it is for disabled glyphs, dots, marks and borders
    /// and nothing that has to be read. Quietness in a paragraph is bought with size and
    /// weight instead.
    static let fgFaint = dynamic(light: 0x6B7177, dark: 0x656D78)

    // MARK: Planes

    /// The back plane: chrome that frames content, such as the panel's header and footer.
    ///
    /// A surface that frames content has to be *behind* it. The panel painted its header
    /// and footer one step lighter than the body between them, so in dark mode the chrome
    /// read as sitting in front of the thing it framed, which is backwards. These two
    /// names are roles rather than new colours, and they are roles rather than one token
    /// because the answer differs by appearance: recessed means darker in both, and in
    /// light the body is already the palest thing in the ramp. `chrome` is `surface` in
    /// light and `bg` in dark; `content` is `bg` in light and `bgRaised` in dark.
    static let chrome = dynamic(light: 0xF4F4F1, dark: 0x101317)

    /// The plane content sits on, one step in front of `chrome` in both appearances.
    static let content = dynamic(light: 0xFBFBF9, dark: 0x171A1F)

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
/// fill is how much of it has elapsed, so the mark *is* the timer wherever it appears:
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
/// as one, it is a label on a block of terminal output.
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

/// A control in three weights, of which only one is a box.
///
/// `.filled` is amber with near-black text and is for the one action a surface exists
/// for, `SIGCONT` on the overlay, "Take it" on the prompt. `.outlined` is the ordinary
/// button and is the only other style that draws a container. `.quiet` draws nothing at
/// rest: it is a label at text weight that gains a fill under the pointer, the way a menu
/// item does, so a pane full of secondary actions does not read as a stack of grey slabs.
///
/// **A control that cannot be undone keeps its box.** Delete, and anything else that
/// opens a confirmation it is possible to mean, is `.outlined` wherever it appears.
/// Quiet is discoverable because of where it sits and what it sits next to, and that is
/// a thin thing to be resting the app's one irreversible action on.
///
/// `mark` puts a glyph in a fixed gutter in front of the label and makes the control
/// full width. The panel uses it so its commands share one column with the app's own
/// output line: `→` is the app talking, `❯` is something you can say back. It earns its
/// keep on the styles that have no box, where it is the only standing evidence that a
/// line is pressable rather than printed. Settings never sets it, because nothing there
/// is an answer to a question the app just asked.
///
/// **Which is why `.quiet` is for the panel.** It is legible without a box in exactly two
/// places: a marked line, where the glyph carries it, and the chrome row under the panel's
/// rule, where the rule and the company it keeps carry it. Nowhere else can set a mark and
/// nowhere else has that rule, so a lone quiet control elsewhere is grey caption text
/// standing next to a real button — which is what the second half of a two-option prompt
/// must never look like. Outside the panel, use `.outlined`.
///
/// A quiet control is still a real `Button`, so VoiceOver announces it as a button and
/// Full Keyboard Access reaches it; the focus ring is drawn here rather than by the
/// system, because the system's is the one blue in an otherwise amber product.
struct TerminalButton: View {
    enum Style { case filled, outlined, quiet }

    /// How far a quiet control's hover fill reaches past its label. `QuietRow` hands it
    /// back to the layout so the words, not the highlights, make the straight edge.
    static let quietInset: CGFloat = 8

    /// The mark column. `markInset` is the boxed styles' own horizontal padding, so a
    /// boxed command and an unboxed one put their glyphs on the same vertical line, and
    /// `markGutter` is wide enough that their labels do too.
    static let markInset: CGFloat = 12
    static let markGutter: CGFloat = 15

    let title: String
    var style: Style = .outlined
    var mark: String? = nil
    var enabled: Bool = true
    var shortcut: KeyboardShortcut? = nil
    let action: () -> Void

    @FocusState private var focused: Bool

    init(
        _ title: String,
        style: Style = .outlined,
        mark: String? = nil,
        enabled: Bool = true,
        shortcut: KeyboardShortcut? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.style = style
        self.mark = mark
        self.enabled = enabled
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        let button = Button(action: action) {
            Text(title)
                .font(Brand.mono(11, weight: style.weight))
        }
        .buttonStyle(
            TerminalButtonStyle(style: style, mark: mark, enabled: enabled, focused: focused)
        )
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
        .focusable(enabled)
        .focusEffectDisabled()
        .focused($focused)

        if let shortcut {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }
}

extension TerminalButton.Style {

    /// Weight is the hierarchy now that two of the three styles have no container: the
    /// primary is semibold on amber, the ordinary button is medium in a box, and a quiet
    /// control is set at the same weight as the text around it.
    var weight: NSFont.Weight {
        switch self {
        case .filled: return .semibold
        case .outlined: return .medium
        case .quiet: return .regular
        }
    }

    var boxed: Bool { self != .quiet }
}

/// Draws the three styles, and is a `ButtonStyle` rather than a modifier stack so the
/// pressed state is real. A control with no border at rest has to answer the click
/// somehow, and dimming it on press is the only feedback left once the box is gone.
private struct TerminalButtonStyle: ButtonStyle {
    let style: TerminalButton.Style
    let mark: String?
    let enabled: Bool
    let focused: Bool

    func makeBody(configuration: Configuration) -> some View {
        Face(
            configuration: configuration,
            style: style,
            mark: mark,
            enabled: enabled,
            focused: focused
        )
    }

    private struct Face: View {
        let configuration: TerminalButtonStyle.Configuration
        let style: TerminalButton.Style
        let mark: String?
        let enabled: Bool
        let focused: Bool

        @State private var hovering = false

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
        }

        private var pressed: Bool { configuration.isPressed && enabled }
        private var hot: Bool { hovering && enabled }

        var body: some View {
            content
                .padding(.horizontal, marked || style.boxed
                    ? TerminalButton.markInset
                    : TerminalButton.quietInset)
                .padding(.vertical, style.boxed ? 6 : 5)
                .frame(maxWidth: marked || style.boxed ? .infinity : nil, alignment: .leading)
                .contentShape(Rectangle())
                .foregroundStyle(foreground)
                .background(background, in: shape)
                .overlay(shape.strokeBorder(border, lineWidth: 1))
                .overlay(focusRing)
                .onHover { hovering = $0 }
        }

        private var marked: Bool { mark != nil }

        /// An unmarked control centres its label, because that is what every other pane
        /// in the app expects of a button. A marked one cannot: the glyph column only
        /// means anything if the labels start at the same x as well.
        @ViewBuilder
        private var content: some View {
            if let mark {
                HStack(spacing: 0) {
                    Text(mark)
                        .font(Brand.mono(11, weight: .medium))
                        .foregroundStyle(markInk)
                        .frame(width: TerminalButton.markGutter, alignment: .leading)
                        // SwiftUI builds a Button's accessibility label out of the Text
                        // in its rendered content, and a ButtonStyle's body *is* that
                        // content — so an unhidden glyph gets read out in front of every
                        // label in the column. The arrow/chevron distinction is drawn for
                        // the eye; the title already says what the control does.
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
            } else {
                configuration.label.frame(maxWidth: style.boxed ? .infinity : nil)
            }
        }

        /// The one place in the body where amber is spent while nothing is due: a single
        /// glyph on the single offered command. When that command becomes the amber block
        /// the glyph is punched out of it instead.
        ///
        /// Every other mark is at the tone the app's own output line uses, so the column
        /// reads as one column and the shape of the glyph, not its brightness, is what
        /// separates a line you can give from a line the app printed. `fgFaint` was the
        /// first try and measured 3.33:1 in dark, which is a thin thing to rest the only
        /// standing evidence that a borderless line is pressable on.
        private var markInk: Color {
            switch style {
            case .filled: return Brand.onAmber.opacity(0.55)
            case .outlined: return Brand.amber
            case .quiet: return Brand.fgMuted
            }
        }

        @ViewBuilder
        private var focusRing: some View {
            if focused, enabled {
                shape.inset(by: -2).strokeBorder(Brand.amber, lineWidth: 1.5)
            }
        }

        /// A marked quiet control is at full text strength, because it is an answer to
        /// the question the panel just asked and it has a glyph saying so. An unmarked
        /// one is chrome, the row of housekeeping under the rule, and chrome that is as
        /// black as the thing it sits under is the loudest thing on a panel where
        /// nothing is happening. It brightens to full strength under the pointer.
        private var foreground: Color {
            switch style {
            case .filled: return Brand.onAmber
            case .outlined: return Brand.fg
            case .quiet:
                if marked { return Brand.fg }
                return hot || pressed ? Brand.fg : Brand.fgMuted
            }
        }

        /// Quiet has no fill at rest and the same two fills as everything else once the
        /// pointer is on it, so the whole panel highlights in one language.
        private var background: Color {
            switch style {
            case .filled:
                if pressed { return Brand.amberFill.opacity(0.78) }
                return hot ? Brand.amberFill.opacity(0.88) : Brand.amberFill
            case .outlined:
                if pressed { return Brand.lineHi }
                return hot ? Brand.surfaceHi : Brand.surface
            case .quiet:
                if pressed { return Brand.lineHi }
                return hot ? Brand.surfaceHi : .clear
            }
        }

        private var border: Color {
            switch style {
            case .filled: return .clear
            case .outlined: return Brand.fgFaint
            case .quiet: return .clear
            }
        }
    }
}

/// A row of quiet controls whose *labels* line up with the margin.
///
/// A quiet control pads itself so the fill it draws under the pointer is bigger than the
/// word inside it. Left unattended that padding pushes the label 8 points right of the
/// button above it, which is the ragged edge these panes have already been fixed for
/// once. The row bleeds that padding back out: the highlight still has its margin, it
/// just takes it from the gutter. A row of one is the right way to place a lone quiet
/// control, which is why this is not called a row of two or more.
/// A marked quiet control does not need this: its own leading inset is the mark column's,
/// which already lines up with the boxed control above it.
struct QuietRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 4) {
            content
        }
        .padding(.leading, -TerminalButton.quietInset)
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
/// rather than a spinner, and it is static under Reduced Motion, an animation nobody
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
