import SigstopCore
import SwiftUI

struct MarkCanvas {
    let size: CGFloat

    var unit: CGFloat { size / 100 }

    func width(_ value: CGFloat) -> CGFloat { max(0.75, value * unit) }

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * unit, y: y * unit)
    }

    func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat = 2) -> Path {
        let rect = CGRect(x: x * unit, y: y * unit, width: w * unit, height: h * unit)
        let limit = min(rect.width, rect.height) / 2
        return Path(
            roundedRect: rect,
            cornerRadius: min(radius * unit, limit),
            style: .continuous
        )
    }

    func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(
            x: (cx - r) * unit, y: (cy - r) * unit,
            width: 2 * r * unit, height: 2 * r * unit
        ))
    }

    func capsule(
        _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, thickness: CGFloat
    ) -> Path {
        let a = point(x1, y1)
        let b = point(x2, y2)
        let length = hypot(b.x - a.x, b.y - a.y)
        let t = thickness * unit
        let path = Path(
            roundedRect: CGRect(x: 0, y: -t / 2, width: length, height: t),
            cornerRadius: t / 2,
            style: .continuous
        )
        return path
            .applying(CGAffineTransform(rotationAngle: atan2(b.y - a.y, b.x - a.x)))
            .applying(CGAffineTransform(translationX: a.x, y: a.y))
    }

    static let headRatio: CGFloat = 0.62

    func arrowHead(tip: (CGFloat, CGFloat), from: (CGFloat, CGFloat), length: CGFloat) -> Path {
        let angle = atan2(tip.1 - from.1, tip.0 - from.0)
        let half = length * MarkCanvas.headRatio
        let base = (tip.0 - cos(angle) * length, tip.1 - sin(angle) * length)
        let normal = (-sin(angle) * half, cos(angle) * half)
        return polygon([
            (tip.0, tip.1),
            (base.0 + normal.0, base.1 + normal.1),
            (base.0 - normal.0, base.1 - normal.1),
        ])
    }

    func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
        var path = polyline(points)
        path.closeSubpath()
        return path
    }

    func polyline(_ points: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: point(first.0, first.1))
        for next in points.dropFirst() { path.addLine(to: point(next.0, next.1)) }
        return path
    }

    func arc(
        from start: (CGFloat, CGFloat), to end: (CGFloat, CGFloat), over control: (CGFloat, CGFloat)
    ) -> Path {
        var path = Path()
        path.move(to: point(start.0, start.1))
        path.addQuadCurve(to: point(end.0, end.1), control: point(control.0, control.1))
        return path
    }
}

struct MarkPart {
    enum Ink {
        case body
        case accent
        case ghost
        case punch
    }

    enum Form {
        case fill
        case line(CGFloat)
    }

    let path: Path
    let ink: Ink
    let form: Form

    static func solid(_ path: Path) -> MarkPart {
        MarkPart(path: path, ink: .body, form: .fill)
    }
    static func stroke(_ path: Path, _ width: CGFloat) -> MarkPart {
        MarkPart(path: path, ink: .body, form: .line(width))
    }
    static func accent(_ path: Path) -> MarkPart {
        MarkPart(path: path, ink: .accent, form: .fill)
    }
    static func ghost(_ path: Path) -> MarkPart {
        MarkPart(path: path, ink: .ghost, form: .fill)
    }
    static func punch(_ path: Path) -> MarkPart {
        MarkPart(path: path, ink: .punch, form: .fill)
    }
}

extension BadgeMotif {

    func parts(on c: MarkCanvas) -> [MarkPart] {
        switch self {
        case .jobLine: return jobLineParts(c, echoed: false)
        case .jobLineFull: return jobLineParts(c, echoed: true)
        case .descent: return descentParts(c)
        case .liftedGate: return liftedGateParts(c)
        case .tombstone: return tombstoneParts(c)
        case .straightThrough: return straightThroughParts(c)
        case .escalation: return escalationParts(c)
        case .handoff: return handoffParts(c)
        case .earlyExit: return earlyExitParts(c)
        case .detached: return detachedParts(c)
        }
    }

    private func jobLineParts(_ c: MarkCanvas, echoed: Bool) -> [MarkPart] {
        let top: CGFloat = echoed ? 28 : 15
        let height: CGFloat = 70
        var parts: [MarkPart] = []

        if echoed {
            var echo = c.bar(12, 3, 76, 6, radius: 2)
            echo.addPath(c.bar(12, 14, 76, 6, radius: 2))
            parts.append(.ghost(echo))
        }

        var left = c.bar(6, top, 7, height, radius: 1.5)
        left.addPath(c.bar(6, top, 20, 7, radius: 1.5))
        left.addPath(c.bar(6, top + height - 7, 20, 7, radius: 1.5))

        var right = c.bar(87, top, 7, height, radius: 1.5)
        right.addPath(c.bar(74, top, 20, 7, radius: 1.5))
        right.addPath(c.bar(74, top + height - 7, 20, 7, radius: 1.5))

        parts.append(.solid(left))
        parts.append(.solid(right))

        if c.size >= 40 {
            var ticks = Path()
            for index in 0..<3 {
                let y = top + 18 + CGFloat(index) * 17
                ticks.addPath(c.bar(14.5, y, 4, 2, radius: 0.8))
                ticks.addPath(c.bar(81.5, y, 4, 2, radius: 0.8))
            }
            parts.append(.solid(ticks))
        }

        let slotTop = top + 13
        let slotHeight = height - 26
        if echoed {
            var slots = Path()
            for index in 0..<3 {
                slots.addPath(
                    c.bar(20 + CGFloat(index) * 22.5, slotTop, 15, slotHeight, radius: 2.5)
                )
            }
            parts.append(.accent(slots))
        } else {
            parts.append(.accent(c.bar(41, slotTop, 18, slotHeight, radius: 3)))
        }
        return parts
    }

    private func descentParts(_ c: MarkCanvas) -> [MarkPart] {
        var stair = Path()
        for index in 0..<3 {
            let x = 8 + CGFloat(index) * 20
            let y = 20 + CGFloat(index) * 18
            stair.addPath(c.bar(x, y, 26, 8, radius: 2))
            stair.addPath(c.bar(x + 18, y, 8, 18, radius: 2))
        }
        return [.solid(stair), .accent(c.bar(66, 74, 29, 10, radius: 2.5))]
    }

    private func liftedGateParts(_ c: MarkCanvas) -> [MarkPart] {
        [
            .solid(c.bar(6, 87, 88, 6, radius: 3)),
            .solid(c.bar(18, 44, 11, 46, radius: 2)),
            .accent(c.capsule(23.5, 48, 73, 12, thickness: 12)),
            .punch(c.circle(23.5, 48, 3.6)),
        ]
    }

    private func tombstoneParts(_ c: MarkCanvas) -> [MarkPart] {
        var proof = Path()
        let rules: [(CGFloat, CGFloat)] = [(3, 94), (16, 68), (30, 26)]
        for (index, rule) in rules.enumerated() {
            proof.addPath(c.bar(rule.0, 12 + CGFloat(index) * 18, rule.1, 9, radius: 2.5))
        }
        return [.solid(proof), .accent(c.bar(60, 42, 21, 21, radius: 2))]
    }

    private func straightThroughParts(_ c: MarkCanvas) -> [MarkPart] {
        var posts = c.bar(45, 3, 10, 29, radius: 2)
        posts.addPath(c.bar(45, 68, 10, 29, radius: 2))
        var arrow = c.bar(5, 44, 61, 12, radius: 0)
        arrow.addPath(c.arrowHead(tip: (97, 50), from: (65, 50), length: 32))
        return [.solid(posts), .accent(arrow)]
    }

    private func escalationParts(_ c: MarkCanvas) -> [MarkPart] {
        var rails = c.bar(26, 5, 8, 90, radius: 2)
        rails.addPath(c.bar(66, 5, 8, 90, radius: 2))
        var rungs = Path()
        for index in 0..<3 {
            rungs.addPath(c.bar(26, 75 - CGFloat(index) * 21, 48, 9, radius: 2))
        }
        return [.solid(rails), .solid(rungs), .accent(c.bar(16, 11, 68, 13, radius: 3))]
    }

    private func handoffParts(_ c: MarkCanvas) -> [MarkPart] {
        var queued = c.bar(28.5, 61, 17.5, 28, radius: 3.5)
        queued.addPath(c.bar(52, 61, 17.5, 28, radius: 3.5))
        return [
            .stroke(c.bar(5, 61, 17.5, 28, radius: 3.5), 5),
            .solid(queued),
            .stroke(c.arc(from: (13.7, 55), to: (78, 57), over: (26, -10)), 5),
            .solid(c.arrowHead(tip: (84.2, 68), from: (70, 46), length: 14)),
            .accent(c.bar(75.5, 61, 17.5, 28, radius: 3.5)),
        ]
    }

    private func earlyExitParts(_ c: MarkCanvas) -> [MarkPart] {
        var ran = c.bar(41, 6, 54, 10, radius: 2.5)
        ran.addPath(c.bar(41, 24, 43, 10, radius: 2.5))
        var unreached = c.bar(41, 56, 50, 10, radius: 2.5)
        unreached.addPath(c.bar(41, 74, 37, 10, radius: 2.5))
        var exit = c.bar(13, 41, 31, 11, radius: 0)
        exit.addPath(c.bar(13, 18, 11, 30, radius: 0))
        exit.addPath(c.arrowHead(tip: (18.5, 3), from: (18.5, 19), length: 16))
        return [.solid(ran), .ghost(unreached), .accent(exit)]
    }

    private func detachedParts(_ c: MarkCanvas) -> [MarkPart] {
        var screen = c.bar(9, 32, 18, 5, radius: 2)
        screen.addPath(c.bar(9, 43, 11, 5, radius: 2))
        var log = c.bar(70, 28, 22, 7, radius: 3)
        log.addPath(c.bar(70, 45, 15, 7, radius: 3))
        log.addPath(c.bar(70, 62, 20, 7, radius: 3))
        return [
            .stroke(c.bar(3, 25, 36, 40, radius: 6), 6),
            .solid(screen),
            .stroke(c.arc(from: (37, 42), to: (53, 65), over: (51, 44)), 7),
            .accent(c.bar(64, 15, 34, 68, radius: 9)),
            .punch(log),
        ]
    }
}

struct BadgeMark: View {
    let motif: BadgeMotif
    let unlocked: Bool
    var size: CGFloat = 28

    var body: some View {
        let canvas = MarkCanvas(size: size)
        ZStack {
            ForEach(Array(motif.parts(on: canvas).enumerated()), id: \.offset) { _, part in
                draw(part, on: canvas)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Rectangle())
        .accessibilityHidden(true)
    }

    private var edge: CGFloat { max(0.6, size * 0.016) }

    private var socket: CGFloat { max(1.1, size * 0.036) }

    private var engraving: CGFloat { size >= 40 ? size * 0.035 : 0 }

    @ViewBuilder
    private func draw(_ part: MarkPart, on canvas: MarkCanvas) -> some View {
        switch part.form {
        case .fill:
            fillView(part)
        case .line(let units):
            lineView(part, width: canvas.width(units))
        }
    }

    @ViewBuilder
    private func fillView(_ part: MarkPart) -> some View {
        switch part.ink {
        case .body:
            part.path.fill(unlocked ? Brand.fg : Brand.fgMuted)
        case .ghost:
            part.path.fill(Brand.fgFaint.opacity(unlocked ? 0.62 : 0.45))
        case .accent:
            if unlocked {
                ZStack {
                    part.path.fill(Brand.amberFill)
                    if engraving > 0 {
                        part.path
                            .stroke(Brand.onAmber.opacity(0.16), lineWidth: engraving * 2)
                            .clipShape(part.path)
                    }
                    part.path.stroke(Brand.amber, lineWidth: edge)
                }
            } else {
                part.path.stroke(Brand.fg, lineWidth: socket)
            }
        case .punch:
            if unlocked {
                part.path.fill(Brand.onAmber.opacity(0.85))
            }
        }
    }

    @ViewBuilder
    private func lineView(_ part: MarkPart, width: CGFloat) -> some View {
        switch part.ink {
        case .body:
            part.path.stroke(unlocked ? Brand.fg : Brand.fgMuted, style: style(width))
        case .ghost:
            part.path.stroke(
                Brand.fgFaint.opacity(unlocked ? 0.62 : 0.45),
                style: style(width)
            )
        case .accent:
            if unlocked {
                ZStack {
                    part.path.stroke(Brand.amber, style: style(width + edge * 2))
                    part.path.stroke(Brand.amberFill, style: style(width))
                }
            } else {
                part.path.stroke(Brand.fg, style: style(max(socket, width * 0.85)))
            }
        case .punch:
            EmptyView()
        }
    }

    private func style(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }
}
