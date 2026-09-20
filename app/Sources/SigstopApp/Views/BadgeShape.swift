import SigstopCore
import SwiftUI

/// The ten marks, drawn.
///
/// A mark is built, not filled. Each one is three things in a fixed relationship: an
/// **edge**, an amber-ink stroke laid down one side at a time with the corners left open,
/// so a triangle is three bars meeting at nothing, an octagon is eight short dashes, and
/// a circle is a ring broken once at the top, the standby glyph, which is what `SIGSTOP`
/// is; a **field**, the same polygon set inside the edge with a sliver of the pane showing
/// between them, filled in the vivid amber; and the **glyph**, knocked out of the field
/// in near-black and sized to the field it actually has rather than to the frame. Side
/// count still rises with difficulty, and the construction is what makes six sides read
/// as a different object from none.
///
/// Every colour is `Brand`'s. Amber is spent on the edge and the field of an earned mark
/// and nowhere on an unearned one. Depth, where it exists, is a single engraved line
/// inside the field at the larger size; there is no gradient, no gloss and no shadow,
/// because this pane sits next to a `TerminalSwitch` and has to look like it does.
///
/// The polygons are not all inscribed in the same circle. Inscribed that way the triangle
/// holds a third of the octagon's area and its field would be too small for any glyph
/// once an edge and a gap are taken out of it; each shape gets its own radius so the ten
/// carry similar visual mass and every field has room for its letter.

// MARK: - Geometry

/// The construction of one mark at one size: where its edge runs, where its field lies,
/// and how much room the glyph has.
struct BadgeGeometry {
    let shape: BadgeShape
    let size: CGFloat

    /// Outer radius: the circumradius for a polygon, the radius for the circle.
    var radius: CGFloat { size * shape.radiusFactor }
    /// The edge stroke. Thick enough to be a component, not an outline.
    var edgeWidth: CGFloat { max(1.5, size * 0.085) }
    /// The pane showing between the edge and the field.
    var gap: CGFloat { max(1, size * 0.045) }
    /// How much of each side is left open at a vertex, measured along the side.
    var cornerGap: CGFloat { size * 0.11 }
    var center: CGPoint { CGPoint(x: size / 2, y: size / 2) }

    /// The field's circumradius. The edge and the gap are measured perpendicular to the
    /// sides, which for a polygon shortens the circumradius by `1/cos(π/n)` times that.
    var fieldRadius: CGFloat {
        let inward = edgeWidth + gap
        guard let sides = shape.sides else { return radius - inward }
        return radius - inward / cos(.pi / CGFloat(sides))
    }

    /// The largest disc inside the field. Every glyph is sized from this.
    var fieldInradius: CGFloat {
        guard let sides = shape.sides else { return fieldRadius }
        return fieldRadius * cos(.pi / CGFloat(sides))
    }

    var glyphSize: CGFloat { fieldInradius * shape.glyphFactor }
    var glyphOffset: CGFloat { size * shape.glyphOffsetFactor }

    // MARK: Paths

    /// The edge, as open subpaths: one per side, each stopping short of both vertices,
    /// or for the circle a single arc broken at the top.
    func edgePath() -> Path {
        var path = Path()
        let r = radius - edgeWidth / 2
        guard r > 0 else { return path }
        guard let sides = shape.sides else {
            let opening = Angle.degrees(21)
            path.addArc(
                center: center, radius: r,
                startAngle: .degrees(-90) + opening,
                endAngle: .degrees(270) - opening,
                clockwise: false
            )
            return path
        }
        let corners = vertices(sides: sides, radius: r)
        for index in 0..<sides {
            let a = corners[index]
            let b = corners[(index + 1) % sides]
            let length = hypot(b.x - a.x, b.y - a.y)
            let trim = min(cornerGap, length * 0.3)
            let unit = CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
            path.move(to: CGPoint(x: a.x + unit.x * trim, y: a.y + unit.y * trim))
            path.addLine(to: CGPoint(x: b.x - unit.x * trim, y: b.y - unit.y * trim))
        }
        return path
    }

    /// The field, optionally drawn a little smaller: `inset` is measured perpendicular
    /// to the sides, like the edge and the gap.
    func fieldPath(inset: CGFloat = 0) -> Path {
        var path = Path()
        guard let sides = shape.sides else {
            let r = fieldRadius - inset
            guard r > 0 else { return path }
            path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            return path
        }
        let r = fieldRadius - inset / cos(.pi / CGFloat(sides))
        guard r > 0 else { return path }
        let corners = vertices(sides: sides, radius: r)
        path.move(to: corners[0])
        for corner in corners.dropFirst() { path.addLine(to: corner) }
        path.closeSubpath()
        return path
    }

    private func vertices(sides: Int, radius r: CGFloat) -> [CGPoint] {
        let step = 2 * CGFloat.pi / CGFloat(sides)
        let start = -CGFloat.pi / 2 + CGFloat(shape.rotation.radians)
        return (0..<sides).map { index in
            let angle = start + step * CGFloat(index)
            return CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
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

    /// Outer radius as a fraction of the frame, chosen so the ten look the same weight.
    ///
    /// A triangle inscribed in the frame's circle is a small, low object with a big
    /// empty crown above it; it is drawn larger, and lets its base corners run a point
    /// past the frame, which the row's spacing absorbs. The circle and the octagon are
    /// the roundest and fill their circle, so they take the frame exactly.
    var radiusFactor: CGFloat {
        switch self {
        case .triangle: return 0.58
        case .square: return 0.54
        case .diamond: return 0.52
        case .pentagon: return 0.54
        case .hexagon: return 0.52
        case .circle, .octagon: return 0.50
        }
    }

    /// Glyph point size as a multiple of the field's inradius.
    ///
    /// The inradius is the only disc guaranteed inside the field, but a letter is not a
    /// disc: a lowercase glyph is wider than it is tall and a capital is taller than it
    /// is wide, and both may run past the incircle where the field's sides leave room.
    /// The triangle's does, because the field is widest where the letter's base sits.
    var glyphFactor: CGFloat {
        switch self {
        case .triangle: return 1.95
        case .diamond: return 1.45
        case .pentagon: return 1.5
        case .square: return 1.45
        case .hexagon, .octagon, .circle: return 1.5
        }
    }

    /// Where the glyph's centre sits relative to the frame's, as a fraction of the size.
    /// A triangle's mass is below its centre and the letter belongs with the mass.
    var glyphOffsetFactor: CGFloat {
        switch self {
        case .triangle: return 0.06
        case .pentagon: return 0.02
        default: return 0
        }
    }
}

// MARK: - The mark

/// One badge at one size, in one of two states.
///
/// **Unlocked** is edge, field and glyph as the file comment describes them: amber ink
/// edge, vivid amber field, near-black glyph. From 40 points up the field also carries
/// one engraved line just inside its boundary, the one concession to depth, so the
/// larger mark reads as a made object rather than a scaled-up icon.
///
/// **Locked** is the same construction with the amber withheld: the edge in muted ink,
/// the field drawn only as a dotted guide where the fill would go, and the glyph set in
/// muted ink on nothing. It says *not yet* three ways at once, the shape is there, the
/// letter is there, the fill is not, and none of them can be read as broken: nothing is
/// crossed out, greyed to invisibility or replaced by a lock.
struct BadgeMark: View {
    let shape: BadgeShape
    let glyph: String
    let unlocked: Bool
    var size: CGFloat = 28

    var body: some View {
        let geometry = BadgeGeometry(shape: shape, size: size)
        ZStack {
            if unlocked {
                earned(geometry)
            } else {
                pending(geometry)
            }
            Text(glyph)
                .font(Brand.mono(geometry.glyphSize, weight: unlocked ? .bold : .medium))
                .foregroundStyle(unlocked ? Brand.onAmber : Brand.fgMuted)
                .lineLimit(1)
                .fixedSize()
                .offset(y: geometry.glyphOffset)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func earned(_ geometry: BadgeGeometry) -> some View {
        ZStack {
            geometry.fieldPath()
                .fill(Brand.amberFill)
            if size >= 40 {
                geometry.fieldPath(inset: size * 0.055)
                    .stroke(Brand.onAmber.opacity(0.22), lineWidth: max(1, size * 0.02))
            }
            geometry.edgePath()
                .stroke(Brand.amber, style: StrokeStyle(lineWidth: geometry.edgeWidth, lineCap: .butt))
        }
    }

    private func pending(_ geometry: BadgeGeometry) -> some View {
        ZStack {
            geometry.fieldPath(inset: size * 0.02)
                .stroke(
                    Brand.fgMuted.opacity(0.45),
                    style: StrokeStyle(lineWidth: max(1, size * 0.03), dash: [1, max(2, size * 0.09)])
                )
            geometry.edgePath()
                .stroke(
                    Brand.fgMuted.opacity(0.6),
                    style: StrokeStyle(lineWidth: geometry.edgeWidth, lineCap: .butt)
                )
        }
    }
}
