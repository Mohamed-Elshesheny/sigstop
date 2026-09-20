import AppKit
import SigstopCore
import SwiftUI

/// The menu bar label. Two bars, which is the `SIGSTOP` glyph and the product's whole
/// idea in fourteen points: a process paused, intact, ready to continue.
///
/// Drawn with shapes rather than an SF Symbol for two reasons. The first is that the
/// symbol set has nothing that fills continuously, and the fill *is* the information —
/// the bars rise with real continuous work, so the icon answers "how long have I been at
/// this" without opening anything. The second is that a symbol would have to be swapped
/// for a different symbol at each state, and swapping glyphs in the menu bar reads as a
/// glitch where a level rising reads as a measurement.
///
/// The colour is resolved per menu bar appearance rather than baked in, which is what
/// gives it the property a template image would have had: legible on a light menu bar and
/// on a dark one, and correct when the menu is open and the bar inverts. It is a dynamic
/// `NSColor` rather than `Color.primary` because the mark is the same amber here as on the
/// site, and one mark everywhere is worth more than automatic monochrome.
struct MenuBarIcon: View {
    let fraction: Double
    let indicator: IndicatorState

    /// The brand amber, so the menu bar and the website are visibly the same mark.
    ///
    /// It has to resolve per appearance rather than being one hex value: #f5a524 is the
    /// site's amber and reads well on a dark menu bar, but it is roughly 1.9:1 against a
    /// light one, which is illegible for a 1pt stroke. The light appearance therefore gets
    /// the darker amber the site already uses for amber-on-white text.
    private static let brand = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.961, green: 0.647, blue: 0.141, alpha: 1)  // #f5a524
            : NSColor(srgbRed: 0.541, green: 0.306, blue: 0.000, alpha: 1)  // #8a4e00
    })

    /// Always the brand colour. State is carried by the FILL LEVEL, not by hue: a full
    /// pair of bars means a break is due, a half pair means half a session. Swapping the
    /// colour as well would be saying the same thing twice and would cost the mark its
    /// identity at the one moment people actually look at it.
    private var tint: Color {
        switch indicator {
        case .idle, .quiet: return Self.brand.opacity(0.4)
        default:            return Self.brand
        }
    }

    /// On a break the bars read empty: the clock is stopped, so claiming a level would be
    /// claiming work that is not happening.
    private var level: Double {
        switch indicator {
        case .onBreak: return 0
        case .breakDue, .escalating: return 1
        default: return min(1, max(0, fraction))
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Bar(level: level)
            Bar(level: level)
        }
        .frame(width: 13, height: 14)
        .foregroundStyle(tint)
        .accessibilityLabel(Text(Self.label(for: indicator)))
    }

    static func label(for indicator: IndicatorState) -> String {
        switch indicator {
        case .working:    return "sigstop — working"
        case .breakDue:   return "sigstop — a break is due"
        case .escalating: return "sigstop — a break is overdue"
        case .onBreak:    return "sigstop — on a break"
        case .idle:       return "sigstop — idle"
        case .quiet:      return "sigstop — quiet"
        }
    }
}

private struct Bar: View {
    let level: Double

    var body: some View {
        GeometryReader { geometry in
            let shape = RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            ZStack(alignment: .bottom) {
                shape.strokeBorder(lineWidth: 1)
                shape.frame(height: geometry.size.height * min(1, max(0, level)))
            }
        }
    }
}
