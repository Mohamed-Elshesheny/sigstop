import AppKit
import SigstopCore
import SwiftUI

struct MenuBarIcon: View {
    let fraction: Double
    let indicator: IndicatorState

    var dark: Bool = true

    private var brand: Color {
        dark
            ? Color(.sRGB, red: 0.961, green: 0.647, blue: 0.141, opacity: 1)
            : Color(.sRGB, red: 0.541, green: 0.306, blue: 0.000, opacity: 1)
    }

    private var tint: Color {
        switch indicator {
        case .idle, .quiet, .backedOff: return brand.opacity(0.4)
        default:                        return brand
        }
    }

    private var level: Double {
        switch indicator {
        case .onBreak: return 0
        case .breakDue, .escalating, .held, .backedOff: return 1
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
        case .working:    return "sigstop, working"
        case .breakDue:   return "sigstop, a break is due"
        case .escalating: return "sigstop, a break is overdue"
        case .held:       return "sigstop, a break is due and being held for a call"
        case .backedOff:  return "sigstop, a break is owed and it has stood down for now"
        case .onBreak:    return "sigstop, on a break"
        case .idle:       return "sigstop, idle"
        case .quiet:      return "sigstop, quiet"
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
