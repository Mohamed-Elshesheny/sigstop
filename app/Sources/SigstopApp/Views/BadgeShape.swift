import SigstopCore
import SwiftUI

/// The ten marks, drawn.
///
/// Flat geometry and nothing else: no gradient, no bevel, no gloss, no drop shadow. A
/// shiny trophy would be the single most off-brand object in a terminal-native product,
/// and the pane it lives in is a settings page, not a prize cabinet. The whole visual
/// vocabulary is the one `Brand` already defines — amber fill, near-black glyph, a muted
/// outline — so a badge sits next to a `TerminalSwitch` without either looking borrowed.
///
/// Side count rises with difficulty, which is the only thing carrying "this one is
/// harder" and is why the shapes are fixed per badge rather than assigned by the view.

// MARK: - Geometry

/// A regular polygon inscribed in the frame's shorter side.
///
/// `rotation` is applied on top of "first vertex at the top", so a four-sided polygon at
/// 0° is a diamond — a square standing on its point — and the same polygon at 45° is an
/// axis-aligned square. That is exactly the distinction the catalogue draws between
/// `unmasked` and `EINVAL`, so it is one type and one parameter rather than two shapes.
///
/// `InsettableShape` is the reason the locked state can be drawn with `strokeBorder`: a
/// plain `stroke` centres the line on the path and spills half its width outside the
/// frame, which at 28 points is a visible difference in how big the locked and unlocked
/// marks look.
struct RegularPolygon: InsettableShape {
    let sides: Int
    var rotation: Angle = .zero
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2 - insetAmount
        guard sides >= 3, radius > 0 else { return Path() }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let step = 2 * Double.pi / Double(sides)
        let start = -Double.pi / 2 + rotation.radians

        var path = Path()
        for index in 0..<sides {
            let angle = start + step * Double(index)
            let point = CGPoint(
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle)
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> RegularPolygon {
        RegularPolygon(sides: sides, rotation: rotation, insetAmount: insetAmount + amount)
    }
}

extension BadgeShape {
    /// How far the polygon is turned from "vertex at the top".
    ///
    /// The square, the hexagon and the octagon are turned to sit flat, because a flat top
    /// is what makes them read as those shapes rather than as a tilted something; the
    /// triangle, the pentagon and the diamond point up, which is what makes *them* read.
    var rotation: Angle {
        switch self {
        case .square: return .degrees(45)
        case .hexagon: return .degrees(30)
        case .octagon: return .degrees(22.5)
        default: return .zero
        }
    }

    /// The glyph's point size as a fraction of the mark's width.
    ///
    /// Every one of these polygons is inscribed in the same circle, so they are the same
    /// *height* and nothing like the same *area*: the triangle encloses a little under a
    /// third of what the octagon does. One font size across all seven therefore does not
    /// read as one family — the octagon looks roomy and the triangle looks stuffed, which
    /// is exactly what the first render showed.
    ///
    /// What these numbers hold constant is the margin between the glyph and the edge, not
    /// the glyph. The ceiling on each is the shape's inscribed circle, which is the only
    /// disc guaranteed to be inside a convex polygon whichever way the glyph leans: at
    /// radius `R` that is `R/2` for the triangle, `R·cos(π/n)` for the rest, and `R` for
    /// the circle. Each value below is set so a bold monospace capital clears it.
    var glyphScale: CGFloat {
        switch self {
        case .triangle: return 0.30
        case .diamond: return 0.34
        case .pentagon, .square: return 0.38
        case .hexagon, .octagon: return 0.42
        case .circle: return 0.40
        }
    }

    /// The fraction of the mark's width a glyph may occupy.
    ///
    /// A backstop for the two-character glyph, and only for that: `[100]+ Stopped` puts
    /// `00` inside the octagon, which is the one mark whose glyph can be wider than it is
    /// tall. Every single-character glyph is far inside this and is sized by `glyphScale`.
    var glyphWidthFraction: CGFloat {
        switch self {
        case .triangle: return 0.46
        case .diamond: return 0.50
        case .pentagon: return 0.56
        case .square, .circle: return 0.62
        case .hexagon, .octagon: return 0.68
        }
    }
}

// MARK: - The mark

/// One badge at one size, in one of two states.
///
/// **Unlocked** is the shape filled in the brand amber with the glyph knocked out in
/// `Brand.onAmber` — the same pairing the primary button uses, so the contrast is the
/// one already verified in both appearances.
///
/// **Locked** is the same outline with nothing inside, at reduced opacity. It has to
/// read as *not yet*: no cross, no lock icon, no grey slab, nothing that could be
/// mistaken for a control that failed or an image that did not load. An empty outline is
/// the most that can be said without saying something wrong.
///
/// The locked outline is drawn in `Brand.fgFaint`, which is a deliberate departure from
/// the hairline colours and is worth the two lines it takes to justify.
///
/// `Brand.line` and `Brand.lineHi` are *divider* colours. They are tuned to disappear —
/// `line` measures about 1.2:1 against the light background and `lineHi` about 1.5:1,
/// and against the near-black dark background `lineHi` is 1.6:1 before the row's own
/// dimming takes it below 1.5:1. That is right for a one-point rule the eye is supposed
/// to read past and wrong for a polygon the eye is supposed to read *as a shape*. The
/// first render of this pane confirmed it: on dark, the locked marks were present but
/// only just, and a mark nobody can see does not say "not yet", it says "this pane is
/// broken" — the one thing locked must never say.
///
/// `fgFaint` at the row's dimming lands near 3:1 on light and 2.6:1 on dark: plainly a
/// shape, plainly secondary to the amber, and the same colour the row already uses for
/// its "not yet" date, so the outline and the words carry identical weight.
struct BadgeMark: View {
    let shape: BadgeShape
    let glyph: String
    let unlocked: Bool
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            if unlocked {
                filled
                Text(glyph)
                    .font(Brand.mono(size * shape.glyphScale, weight: .bold))
                    .foregroundStyle(Brand.onAmber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: size * shape.glyphWidthFraction)
            } else {
                outlined
            }
        }
        .frame(width: size, height: size)
        .opacity(unlocked ? 1 : 0.75)
        .accessibilityHidden(true)
    }

    private var lineWidth: CGFloat { max(1, size * 0.045) }

    @ViewBuilder
    private var filled: some View {
        if let sides = shape.sides {
            RegularPolygon(sides: sides, rotation: shape.rotation).fill(Brand.amberFill)
        } else {
            Circle().fill(Brand.amberFill)
        }
    }

    @ViewBuilder
    private var outlined: some View {
        if let sides = shape.sides {
            RegularPolygon(sides: sides, rotation: shape.rotation)
                .strokeBorder(Brand.fgFaint, lineWidth: lineWidth)
        } else {
            Circle().strokeBorder(Brand.fgFaint, lineWidth: lineWidth)
        }
    }
}
