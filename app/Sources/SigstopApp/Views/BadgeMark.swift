import SigstopCore
import SwiftUI

/// The ten marks, drawn as ten objects.
///
/// The set this replaced was seven regular polygons with a letter knocked out of the
/// middle, one amber fill on all of them, side count rising with difficulty. It read as
/// one thing counted seven ways, which is the one thing a badge set must not be: nobody
/// looks at a hexagon and wants the octagon. So the geometry is gone and each mark is now
/// a small specific object taken from what its badge actually means, built the way an
/// icon set is built. The ten are meant to be told apart by silhouette alone, at 28
/// points, in a vertical list, without reading a single title.
///
/// **Four inks, and that is the whole system.** `body` is the object's structure and is
/// drawn in plain ink. `accent` is the one part of each object that carries the badge's
/// meaning, and it is the only amber in the mark: the suspended job between the brackets,
/// the arm that is out of the way, the arrow that never bent, the rung that cannot be
/// caught. `punch` is a hole through an accent, in the colour that sits on amber. `ghost`
/// is ink for a line that is on the page but is not the subject: the statements after the
/// arrow in `early return` that are never reached, and the scrollback above the brackets
/// in `[100]+ Stopped` that has already printed and scrolled by. Both are present and
/// neither is live, and no other ink says both at once.
///
/// **Locked is the same object with the light off.** Every line is exactly where it will
/// be and at exactly the same weight; only two things change. The structure steps down
/// one level of ink, not four, so a locked mark is as present in the row as an earned one
/// and never reads as faded out. And the accent is drawn as a hollow outline in full
/// strength ink, which makes the empty socket the brightest thing in the mark, so the eye
/// lands on what is missing. Nothing is crossed out, nothing is padlocked, nothing fades
/// toward invisible. A locked mark has to make someone want that specific one, not feel
/// told off for not having it yet.
///
/// **Amber is spent, not sprayed.** One accent per mark, and its share of the object
/// grows with the work: `[1]+ Stopped` spends it on a single bar between the brackets,
/// and `[100]+ Stopped` spends it on all four slots at once. Those two are deliberately
/// the same brackets, because the shell prints the same line both times. What separates
/// them is mass rather than arithmetic: the hundredth carries two ghosted scrollback
/// rules above it, so it is the taller object even in the locked column where there is no
/// amber left to count.

// MARK: - The design space

/// A 100 by 100 space every motif is drawn in, scaled to the size actually asked for.
///
/// Motifs are written in round numbers against a fixed square rather than in fractions of
/// `size`, because the thing being tuned here is a drawing, and a drawing is tuned by
/// nudging a coordinate two units and looking at it again.
struct MarkCanvas {
    let size: CGFloat

    var unit: CGFloat { size / 100 }

    /// A stroke width in design units, floored so a hairline never vanishes at 28pt.
    func width(_ value: CGFloat) -> CGFloat { max(0.75, value * unit) }

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * unit, y: y * unit)
    }

    /// The workhorse: slats, treads, statements, blocks, brackets.
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

    /// A rounded bar laid along an arbitrary segment, for anything not square to the
    /// frame. Only the raised gate arm needs it, and it is why the gate reads instantly:
    /// nothing else in the ten has a long diagonal.
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

    /// The proportion every arrowhead in the set is built to: half-width over length.
    ///
    /// Three of the ten carry a head and they used to be drawn independently, which read
    /// as three slightly different arrows rather than one family. The number is the one
    /// the straight arrow was already tuned to; the other two were moved onto it.
    static let headRatio: CGFloat = 0.62

    /// One arrowhead, pointing from `from` towards `tip`, `length` units deep.
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

// MARK: - Parts

/// One drawn element, and which of the inks it belongs to.
///
/// A motif is a list of these and nothing else, which is what stops the two states from
/// being two drawings: locked and earned are the same parts resolved differently, so a
/// motif cannot be tuned in one state and left wrong in the other.
struct MarkPart {
    enum Ink {
        /// The object's structure. Plain ink, strong when earned, faint when not.
        case body
        /// The one part that means something. The only amber in the mark.
        case accent
        /// Deliberately not there. Faint in both states, because it is not a thing being
        /// withheld until you earn it, it is a thing that does not happen.
        case ghost
        /// A hole punched through an accent, in the colour that sits on amber. There is
        /// nothing to punch through when the accent is a hollow outline, so it is skipped
        /// while the badge is locked.
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

// MARK: - The ten objects

extension BadgeMotif {

    /// The object, in drawing order: structure first and amber last, so an accent is
    /// never covered by the thing it is attached to.
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

    /// `[1]+ Stopped` and `[100]+ Stopped`: the same brackets, printed once or printed so
    /// often that the earlier lines have scrolled up behind it.
    ///
    /// The rhyme is the whole idea and one function draws both, because two would let the
    /// brackets drift a unit apart and lose it. What the hundredth adds is not a bigger
    /// number, it is *mass*: two ghosted scrollback rules above and the frame filled with
    /// jobs instead of holding one, so the pair is told apart by outline and not only by
    /// count. That matters most in the locked column, where there is no amber to count at
    /// all and the two would otherwise be one hollow socket against a row of them.
    ///
    /// **The slot pitch is a legibility budget, not a taste question.** This drew four
    /// slots inside brackets that spanned 14 to 86, which left each slot 9.5 units wide
    /// with 5 unit gaps and 2.5 units of air before the bracket verticals. At the size
    /// that actually ships that is a 2.7pt bar, a 1.4pt gap and 0.7pt of clearance, and it
    /// did exactly what those numbers predict: the four fused into one hatched block, the
    /// locked version became the loudest mark on the page — louder than the earned ones
    /// above it, which inverts the whole hierarchy — and the hundred-break prize ended up
    /// the muddiest thing in the set. The brackets now span the full frame and carry
    /// three slots instead of four, which buys every slot 4.2pt of width, 2.1pt of gap and
    /// 2pt of clearance inside the brackets. Three countable jobs beat four uncountable
    /// ones; the count was never the point, the mass is, and the scrollback rules above
    /// say "and many before these" better than a fourth 1pt stripe ever did.
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

    /// `ten down`: a staircase going down, and the tread you end up on is the amber one.
    /// Lowering your own priority is a thing with a direction, so the object has one too.
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

    /// `nothing blocked`: the barrier is up. Nothing blocking a signal is hard to draw as an
    /// absence, so it is drawn as the blocker, parked somewhere it plainly is not in the
    /// way any more.
    private func liftedGateParts(_ c: MarkCanvas) -> [MarkPart] {
        [
            .solid(c.bar(6, 87, 88, 6, radius: 3)),
            .solid(c.bar(18, 44, 11, 46, radius: 2)),
            .accent(c.capsule(23.5, 48, 73, 12, thickness: 12)),
            .punch(c.circle(23.5, 48, 3.6)),
        ]
    }

    /// `always halts`: an argument narrowing to the block that closes it.
    ///
    /// This was a left-aligned stack of shortening lines, which was typographically the
    /// honest way to draw a proof and visually the wrong one: `early return` is also a
    /// stack of horizontal bars, and in the locked column, where neither has any amber,
    /// the two were the likeliest pair in the ten to be mistaken for each other. Centring
    /// the lines turns the same idea into a wedge, which is a silhouette nothing else in
    /// the set has. The wedge stays; what changed is where the block sits.
    ///
    /// **A tombstone is a thing that goes at the end of a line, not under a stack.** It
    /// was drawn centred, large, and hanging below the wedge, which made it the subject of
    /// the mark rather than the full stop of an argument, and the whole thing read as a
    /// funnel or a text-align glyph. Nobody derives QED from a big centred box. It is now
    /// a small square set at the right-hand end of the shortest, lowest rule, on that
    /// rule's own baseline and about twice its height — which is literally how the mark is
    /// set in print, and reads instantly to anyone who has seen a proof end. The set is
    /// also no longer forked by size: the old fork dropped the middle rule below 40 points
    /// and cost the mark its wedge at exactly the size that ships, leaving two rules over a
    /// block. Nine-unit rules on an eighteen-unit pitch are 2.5pt and 2.5pt at 28 points,
    /// so all three fit, and one drawing is now tuned at both sizes instead of two being
    /// tuned at one each.
    private func tombstoneParts(_ c: MarkCanvas) -> [MarkPart] {
        var proof = Path()
        let rules: [(CGFloat, CGFloat)] = [(3, 94), (16, 68), (30, 26)]
        for (index, rule) in rules.enumerated() {
            proof.addPath(c.bar(rule.0, 12 + CGFloat(index) * 18, rule.1, 9, radius: 2.5))
        }
        return [.solid(proof), .accent(c.bar(60, 42, 21, 21, radius: 2))]
    }

    /// `no handler`: the default disposition runs, so the arrow goes straight through the gap
    /// where a handler would have sat. One unbroken shaft, no bend, nothing to catch it.
    private func straightThroughParts(_ c: MarkCanvas) -> [MarkPart] {
        var posts = c.bar(45, 3, 10, 29, radius: 2)
        posts.addPath(c.bar(45, 68, 10, 29, radius: 2))
        var arrow = c.bar(5, 44, 61, 12, radius: 0)
        arrow.addPath(c.arrowHead(tip: (97, 50), from: (65, 50), length: 32))
        return [.solid(posts), .accent(arrow)]
    }

    /// `uncatchable`: the escalation ladder from `CLAUDE.md` §0, with the top rung lit.
    ///
    /// The mark here used to be a rubber stamp and its impression, which was legible and
    /// meant nothing: a stamp says "refused", and this badge is not about being refused,
    /// it is about letting a prompt climb all four rungs to `SIGSTOP`. The ladder is the
    /// product's own escalation table drawn as an object, so the badge's one line of copy
    /// and its picture finally say the same thing. `SIGSTOP` is the amber rung and it is
    /// wider than the three below it, overhanging both rails, because the rung that
    /// cannot be caught is not the same kind of rung as the ones that can.
    private func escalationParts(_ c: MarkCanvas) -> [MarkPart] {
        var rails = c.bar(26, 5, 8, 90, radius: 2)
        rails.addPath(c.bar(66, 5, 8, 90, radius: 2))
        var rungs = Path()
        for index in 0..<3 {
            rungs.addPath(c.bar(26, 75 - CGFloat(index) * 21, 48, 9, radius: 2))
        }
        return [.solid(rails), .solid(rungs), .accent(c.bar(16, 11, 68, 13, radius: 3))]
    }

    /// `yielded`: the front slot of the run queue is empty because whoever held it
    /// stepped out, and the arc carries them round to the back. Voluntary is the point, so
    /// nothing is pushing.
    ///
    /// **The arc is asymmetric because a symmetric one is a headband.** This drew an even
    /// dome spanning all four cells and terminating level with the top of the last one,
    /// and it dropped the arrowhead below 40 points because four dark points on the amber
    /// cell read as a blot. Both decisions were locally right and together they produced
    /// headphones: at the size that ships, in both themes, the silhouette was a band over
    /// two earcups, and a badge for yielding captioning a picture of headphones is the joke
    /// landing on the product. Symmetry was the culprit, so the apex now sits left of
    /// centre, rising off the empty slot the yielder just vacated and diving steeply into
    /// the back of the queue — which is also a truer picture of the operation than an even
    /// hop was. The head comes back at every size, made narrower than one cell and aimed
    /// so it breaks the last cell's top edge rather than capping it: entering the queue,
    /// not sitting on it. Nothing was pushing before and nothing is pushing now.
    ///
    /// The cells are spaced six units apart rather than four, so four slots stay four
    /// slots instead of merging into one striped block.
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

    /// `early return`: two statements ran, the arrow left, and the rest of the function is
    /// still sitting there in ghost ink having never been reached. Those faint lines are
    /// the badge. Without them it is only an arrow.
    ///
    /// The elbow used to run its shaft the full width of the mark, underneath the
    /// statements, which put a fifth horizontal bar through a stack of four and turned the
    /// whole thing to mush at 28 points: the amber stopped reading as the exit and started
    /// reading as one more line of code. It now lives entirely to the left of the block
    /// and touches it only at the point it leaves, so the statements are a column and the
    /// exit is a separate object beside them.
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

    /// `still running`: the terminal is gone and the job did not notice.
    ///
    /// Four earlier attempts put the two objects near each other and asked a stub about a
    /// point long to carry "these are no longer joined", which at 28 points is nothing at
    /// all: the mark said "two boxes" and left the meaning to the title. The severance is
    /// now the size of the silhouette rather than a detail inside it. The link leaves the
    /// terminal, is cut off square in open space, and then there is nothing for a sixth
    /// of the frame before the job starts. The job is also the bigger of the two objects
    /// and the only solid one, against a terminal drawn as an empty outline, which is the
    /// other half of the sentence: the window is finished and the work is not. A fifth
    /// attempt ran the job off the right edge of the frame to say "still going". It read
    /// as a rendering fault at 28 points and its locked outline, clipped, was the letter
    /// C, so the job was brought back inside and the gap was made to carry the meaning on
    /// its own.
    ///
    /// **What is punched out of the job is a log, not a pause.** It was the app's own
    /// pause pair — two vertical bars in a rounded capsule — argued for as "suspended,
    /// intact". That was wrong twice over. It is the universal media pause glyph and read
    /// as one at every size, and this is the single badge in the set that is *not* about
    /// suspending: the blurb says the job has stopped caring whether the terminal is still
    /// there, which means it is still running. It also collided head-on with
    /// `[1]+ Stopped`, where an amber bar in a frame is the set's own token for a
    /// suspended job, so one bar meant "job" and two meant "paused" in the same row. Three
    /// short rules instead: a log still being written, which is what a surviving job
    /// leaves behind, and which no longer borrows a token that means the opposite.
    ///
    /// **The cut hangs, and it hangs off the wall rather than the corner.** The link used
    /// to leave the terminal as a square-ended horizontal stub aimed straight at the
    /// capsule's vertical centre, which at silhouette scale is a plug seating into a
    /// socket — connected, the exact opposite of the word the mark exists to carry. The
    /// first redraw made it a straight diagonal falling from the box's bottom-right
    /// corner, which fixed the plug and immediately bought a worse read: a stick at the
    /// corner of a rounded square is a magnifying glass, and `still running` captioned with a
    /// search icon is no better than the same mark captioned with a pause button. It is now a
    /// curve, not a stick, and it leaves from the middle of the right wall: it exits
    /// horizontally the way a cable does, goes slack, and droops away into open space
    /// below the job's centreline with nothing to mate with. Slack is the tell. A taut
    /// line is attached to something at both ends; a hanging one is not, and that reads at
    /// any size because it is a shape rather than a detail.
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

// MARK: - The mark

/// One badge's object, at one size, earned or not.
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

    /// The dark amber edge that keeps a vivid fill from washing out on white. Hairline on
    /// purpose: at 28 points an edge any heavier eats a three point bar whole and the
    /// amber turns brown, which is the exact failure the two amber tokens exist to avoid.
    private var edge: CGFloat { max(0.6, size * 0.016) }

    /// The hollow outline a locked accent is drawn as, in plain ink rather than amber.
    ///
    /// It carries its own absolute floor instead of scaling off `edge`, because the empty
    /// socket is the single thing the locked state exists to show and it must not be the
    /// first detail the rasteriser eats. Anything derived from the earned hairline thins
    /// with the canvas and disappears at exactly the size that ships.
    ///
    /// Tinting this outline amber instead of neutralising it is the obvious next idea and
    /// it was rendered and rejected, so: amber at low opacity is a warm tan on the light
    /// page, and the locked marks came out reading as aged and dirty rather than as
    /// waiting, which is the one feeling this state must not produce. It also puts amber
    /// on twenty marks instead of ten, and if every mark in the pane is amber to some
    /// degree then no mark in the pane is a reward. Neutral is what keeps amber meaning
    /// exactly one thing: this one is yours.
    private var socket: CGFloat { max(1.1, size * 0.036) }

    /// An inner rim engraved into every amber fill, and the only depth in the whole set.
    ///
    /// It exists because a mark at 56 points has to look like it was made at 56 points
    /// rather than enlarged from 28, and this is the cheapest honest way to get that: the
    /// stroke is clipped to its own path so only the inside half survives, which reads as
    /// a pressed edge. It is switched off below 40 points, where the rim would be a third
    /// of the bar it is supposed to be edging and would only look like mud.
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
