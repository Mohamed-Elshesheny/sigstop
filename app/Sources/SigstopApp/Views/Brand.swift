import AppKit
import SigstopCore
import SwiftUI

enum Brand {

    static let bg = dynamic(light: 0xFBFBF9, dark: 0x101317)
    static let bgRaised = dynamic(light: 0xFFFFFF, dark: 0x171A1F)
    static let surface = dynamic(light: 0xF4F4F1, dark: 0x1D2127)
    static let surfaceHi = dynamic(light: 0xE9E9E4, dark: 0x262B32)
    static let line = dynamic(light: 0xE7E7E1, dark: 0x2B313A)
    static let lineHi = dynamic(light: 0xCFCFC7, dark: 0x3A424D)

    static let fg = dynamic(light: 0x17191C, dark: 0xE8EAED)
    static let fgMuted = dynamic(light: 0x53585E, dark: 0x9AA2AD)

    static let fgFaint = dynamic(light: 0x6B7177, dark: 0x656D78)

    static let chrome = dynamic(light: 0xF4F4F1, dark: 0x101317)

    static let content = dynamic(light: 0xFBFBF9, dark: 0x171A1F)

    static let running = dynamic(light: 0x15803D, dark: 0x3FB950)

    static let amber = dynamic(light: 0x8A4E00, dark: 0xF5A524)

    static let amberFill = dynamic(light: 0xF0A020, dark: 0xF5A524)
    static let onAmber = dynamic(light: 0x1B1206, dark: 0x000000)

    static let alert = dynamic(light: 0xC0322B, dark: 0xF85149)

    enum Dark {
        static let fg = fixed(0xE8EAED)
        static let fgMuted = fixed(0x9AA2AD)
        static let fgFaint = fixed(0x656D78)
        static let line = fixed(0x2D343D)
        static let amber = fixed(0xF5A524)
        static let onAmber = fixed(0x000000)
    }

    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        if let font = NSFont(name: "JetBrainsMono-\(jetBrainsStyle(for: weight))", size: size) {
            return Font(font)
        }
        return Font(NSFont.monospacedSystemFont(ofSize: size, weight: weight))
    }

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

    @MainActor
    static func apply(_ preference: AppearancePreference, pinning statusButton: NSStatusBarButton?) {
        switch preference {
        case .system:
            NSApp.appearance = nil
            statusButton?.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
            statusButton?.appearance = systemAppearance()
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
            statusButton?.appearance = systemAppearance()
        }
    }

    static func systemAppearance() -> NSAppearance? {
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        return NSAppearance(named: dark ? .darkAqua : .aqua)
    }

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

struct BrandMark: View {
    var size: CGFloat = 40
    var fill: Double = 0.5
    var tint: Color = Brand.amber
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

struct Rule: View {
    var body: some View {
        Rectangle()
            .fill(Brand.line)
            .frame(height: 1)
    }
}

struct TerminalButton: View {
    enum Style { case filled, outlined, quiet }

    static let quietInset: CGFloat = 8

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

    var weight: NSFont.Weight {
        switch self {
        case .filled: return .semibold
        case .outlined: return .medium
        case .quiet: return .regular
        }
    }

    var boxed: Bool { self != .quiet }
}

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

        @ViewBuilder
        private var content: some View {
            if let mark {
                HStack(spacing: 0) {
                    Text(mark)
                        .font(Brand.mono(11, weight: .medium))
                        .foregroundStyle(markInk)
                        .frame(width: TerminalButton.markGutter, alignment: .leading)
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
            } else {
                configuration.label.frame(maxWidth: style.boxed ? .infinity : nil)
            }
        }

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

        private var foreground: Color {
            switch style {
            case .filled: return Brand.onAmber
            case .outlined: return Brand.fg
            case .quiet:
                if marked { return Brand.fg }
                return hot || pressed ? Brand.fg : Brand.fgMuted
            }
        }

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

struct QuietRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 4) {
            content
        }
        .padding(.leading, -TerminalButton.quietInset)
    }
}

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

struct TerminalSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 {
                    Rectangle().fill(Brand.lineHi).frame(width: 1, height: 24)
                }
                cell(option.value, option.label)
            }
        }
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Brand.lineHi, lineWidth: 1)
        )
    }

    private func cell(_ value: Value, _ label: String) -> some View {
        let on = value == selection
        return Button { selection = value } label: {
            Text(label)
                .font(Brand.mono(12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Brand.fg : Brand.fgMuted)
                .frame(minWidth: 58)
                .frame(height: 24)
                .background(on ? Brand.surfaceHi : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

struct TransferBar: View {
    let fraction: Double?
    var animated: Bool = true
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
                        .animation(reduceMotion || !animated ? nil : .easeOut(duration: 0.4), value: fraction)
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
