"use client";

import { useId } from "react";
import { cn } from "@/lib/cn";

/**
 * The ten badge marks, as SVG.
 *
 * This is a port, not a redesign. `app/Sources/SigstopApp/Views/BadgeMark.swift`
 * draws every motif in a fixed 100 by 100 design space, in round numbers, and
 * that file's header carries the reasoning for each object. The numbers below
 * are the same numbers, so the site and the app are one drawing rendered twice
 * rather than two drawings that will drift. If a mark changes there, change it
 * here in the same commit.
 *
 * Four inks and that is the whole system. `body` is structure. `accent` is the
 * one part that carries the badge's meaning and is the only amber in the mark.
 * `ghost` is a line that is on the page but is not live: the statements after
 * the early return that never run, the scrollback above the brackets that has
 * already printed. `punch` is a hole through an accent, in the colour that sits
 * on amber.
 *
 * Locked is the same object with the light off. Every line is exactly where it
 * will be and at exactly the same weight. The structure steps down one level of
 * ink, not four, and the accent becomes a hollow outline in full strength ink,
 * so the empty socket is the brightest thing in the mark and the eye lands on
 * what is missing. Nothing is crossed out and nothing fades toward invisible.
 */

export type Motif =
  | "job-line"
  | "descent"
  | "lifted-gate"
  | "tombstone"
  | "straight-through"
  | "escalation"
  | "handoff"
  | "early-exit"
  | "detached"
  | "job-line-full";

type Ink = "body" | "accent" | "ghost" | "punch";

/** One drawn element. `w` present means it is a stroked line rather than a fill. */
type Part = { d: string; ink: Ink; w?: number; transform?: string };

// ── The design space ──────────────────────────────────────────────────────
// Everything is written against a 100 unit square and scaled by the viewBox,
// so a stroke quoted in units stays proportional at any rendered size.

/** The workhorse: slats, treads, statements, blocks, brackets. */
function bar(x: number, y: number, w: number, h: number, r = 2): string {
  const k = Math.min(r, Math.min(w, h) / 2);
  return [
    `M${x + k},${y}`,
    `H${x + w - k}`,
    `A${k},${k} 0 0 1 ${x + w},${y + k}`,
    `V${y + h - k}`,
    `A${k},${k} 0 0 1 ${x + w - k},${y + h}`,
    `H${x + k}`,
    `A${k},${k} 0 0 1 ${x},${y + h - k}`,
    `V${y + k}`,
    `A${k},${k} 0 0 1 ${x + k},${y}`,
    "Z",
  ].join("");
}

function circle(cx: number, cy: number, r: number): string {
  return `M${cx - r},${cy}a${r},${r} 0 1 0 ${r * 2},0a${r},${r} 0 1 0 ${-r * 2},0Z`;
}

/**
 * A rounded bar laid along an arbitrary segment. Only the raised gate arm needs
 * it, and it is why the gate reads instantly: nothing else in the ten has a
 * long diagonal.
 */
function capsule(x1: number, y1: number, x2: number, y2: number, t: number): string {
  const length = Math.hypot(x2 - x1, y2 - y1);
  return bar(0, -t / 2, length, t, t / 2);
}

function capsuleTransform(x1: number, y1: number, x2: number, y2: number): string {
  const deg = (Math.atan2(y2 - y1, x2 - x1) * 180) / Math.PI;
  return `translate(${x1} ${y1}) rotate(${deg})`;
}

/** The proportion every arrowhead in the set is built to: half-width over length. */
const HEAD_RATIO = 0.62;

function arrowHead(
  tip: [number, number],
  from: [number, number],
  length: number,
): string {
  const angle = Math.atan2(tip[1] - from[1], tip[0] - from[0]);
  const half = length * HEAD_RATIO;
  const base: [number, number] = [
    tip[0] - Math.cos(angle) * length,
    tip[1] - Math.sin(angle) * length,
  ];
  const normal: [number, number] = [-Math.sin(angle) * half, Math.cos(angle) * half];
  return [
    `M${tip[0]},${tip[1]}`,
    `L${base[0] + normal[0]},${base[1] + normal[1]}`,
    `L${base[0] - normal[0]},${base[1] - normal[1]}`,
    "Z",
  ].join("");
}

function arc(
  from: [number, number],
  to: [number, number],
  over: [number, number],
): string {
  return `M${from[0]},${from[1]}Q${over[0]},${over[1]} ${to[0]},${to[1]}`;
}

const solid = (d: string): Part => ({ d, ink: "body" });
const stroke = (d: string, w: number): Part => ({ d, ink: "body", w });
const accent = (d: string): Part => ({ d, ink: "accent" });
const ghost = (d: string): Part => ({ d, ink: "ghost" });
const punch = (d: string): Part => ({ d, ink: "punch" });

// ── The ten objects ───────────────────────────────────────────────────────

/**
 * `[1]+ Stopped` and `[100]+ Stopped`: the same brackets, printed once or
 * printed so often that the earlier lines have scrolled up behind it. One
 * function draws both, because two would let the brackets drift a unit apart
 * and lose the rhyme. What the hundredth adds is mass, not a bigger number.
 */
function jobLine(echoed: boolean): Part[] {
  const top = echoed ? 28 : 15;
  const height = 70;
  const parts: Part[] = [];

  if (echoed) {
    parts.push(ghost(bar(12, 3, 76, 6, 2)), ghost(bar(12, 14, 76, 6, 2)));
  }

  parts.push(
    solid(bar(6, top, 7, height, 1.5)),
    solid(bar(6, top, 20, 7, 1.5)),
    solid(bar(6, top + height - 7, 20, 7, 1.5)),
    solid(bar(87, top, 7, height, 1.5)),
    solid(bar(74, top, 20, 7, 1.5)),
    solid(bar(74, top + height - 7, 20, 7, 1.5)),
  );

  for (let i = 0; i < 3; i += 1) {
    const y = top + 18 + i * 17;
    parts.push(solid(bar(14.5, y, 4, 2, 0.8)), solid(bar(81.5, y, 4, 2, 0.8)));
  }

  const slotTop = top + 13;
  const slotHeight = height - 26;
  if (echoed) {
    for (let i = 0; i < 3; i += 1) {
      parts.push(accent(bar(20 + i * 22.5, slotTop, 15, slotHeight, 2.5)));
    }
  } else {
    parts.push(accent(bar(41, slotTop, 18, slotHeight, 3)));
  }
  return parts;
}

/** `ten down`: a staircase going down, and the tread you end up on is amber. */
function descent(): Part[] {
  const parts: Part[] = [];
  for (let i = 0; i < 3; i += 1) {
    const x = 8 + i * 20;
    const y = 20 + i * 18;
    parts.push(solid(bar(x, y, 26, 8, 2)), solid(bar(x + 18, y, 8, 18, 2)));
  }
  parts.push(accent(bar(66, 74, 29, 10, 2.5)));
  return parts;
}

/**
 * `nothing blocked`: the barrier is up. An absence is hard to draw, so it is
 * drawn as the blocker, parked somewhere it plainly is not in the way.
 */
function liftedGate(): Part[] {
  return [
    solid(bar(6, 87, 88, 6, 3)),
    solid(bar(18, 44, 11, 46, 2)),
    { ...accent(capsule(23.5, 48, 73, 12, 12)), transform: capsuleTransform(23.5, 48, 73, 12) },
    punch(circle(23.5, 48, 3.6)),
  ];
}

/** `always halts`: an argument narrowing to the block that closes it. */
function tombstone(): Part[] {
  const rules: [number, number][] = [
    [3, 94],
    [16, 68],
    [30, 26],
  ];
  return [
    ...rules.map(([x, w], i) => solid(bar(x, 12 + i * 18, w, 9, 2.5))),
    accent(bar(60, 42, 21, 21, 2)),
  ];
}

/**
 * `no handler`: the default disposition runs, so the arrow goes straight
 * through the gap where a handler would have sat. No bend, nothing to catch it.
 */
function straightThrough(): Part[] {
  return [
    solid(bar(45, 3, 10, 29, 2)),
    solid(bar(45, 68, 10, 29, 2)),
    accent(bar(5, 44, 61, 12, 0)),
    accent(arrowHead([97, 50], [65, 50], 32)),
  ];
}

/**
 * `uncatchable`: the escalation ladder from `CLAUDE.md` §0 with the top rung
 * lit. SIGSTOP is wider than the three below it and overhangs both rails,
 * because the rung that cannot be caught is not the same kind of rung.
 */
function escalation(): Part[] {
  const parts: Part[] = [solid(bar(26, 5, 8, 90, 2)), solid(bar(66, 5, 8, 90, 2))];
  for (let i = 0; i < 3; i += 1) {
    parts.push(solid(bar(26, 75 - i * 21, 48, 9, 2)));
  }
  parts.push(accent(bar(16, 11, 68, 13, 3)));
  return parts;
}

/**
 * `yielded`: the front slot of the run queue is empty because whoever held it
 * stepped out, and the arc carries them round to the back. The apex sits left
 * of centre on purpose. A symmetric dome over four cells is a pair of
 * headphones, which is the joke landing on the product.
 */
function handoff(): Part[] {
  return [
    stroke(bar(5, 61, 17.5, 28, 3.5), 5),
    solid(bar(28.5, 61, 17.5, 28, 3.5)),
    solid(bar(52, 61, 17.5, 28, 3.5)),
    stroke(arc([13.7, 55], [78, 57], [26, -10]), 5),
    solid(arrowHead([84.2, 68], [70, 46], 14)),
    accent(bar(75.5, 61, 17.5, 28, 3.5)),
  ];
}

/**
 * `early return`: two statements ran, the arrow left, and the rest of the
 * function is still sitting there in ghost ink having never been reached.
 * Those faint lines are the badge. Without them it is only an arrow.
 */
function earlyExit(): Part[] {
  return [
    solid(bar(41, 6, 54, 10, 2.5)),
    solid(bar(41, 24, 43, 10, 2.5)),
    ghost(bar(41, 56, 50, 10, 2.5)),
    ghost(bar(41, 74, 37, 10, 2.5)),
    accent(bar(13, 41, 31, 11, 0)),
    accent(bar(13, 18, 11, 30, 0)),
    accent(arrowHead([18.5, 3], [18.5, 19], 16)),
  ];
}

/**
 * `still running`: the terminal is gone and the job did not notice. The
 * severance is the size of the silhouette rather than a detail inside it. The
 * link leaves the right wall horizontally the way a cable does, goes slack, and
 * droops into open space with nothing to mate with. Slack is the tell.
 */
function detached(): Part[] {
  return [
    stroke(bar(3, 25, 36, 40, 6), 6),
    solid(bar(9, 32, 18, 5, 2)),
    solid(bar(9, 43, 11, 5, 2)),
    stroke(arc([37, 42], [53, 65], [51, 44]), 7),
    accent(bar(64, 15, 34, 68, 9)),
    punch(bar(70, 28, 22, 7, 3)),
    punch(bar(70, 45, 15, 7, 3)),
    punch(bar(70, 62, 20, 7, 3)),
  ];
}

function partsFor(motif: Motif): Part[] {
  switch (motif) {
    case "job-line":
      return jobLine(false);
    case "job-line-full":
      return jobLine(true);
    case "descent":
      return descent();
    case "lifted-gate":
      return liftedGate();
    case "tombstone":
      return tombstone();
    case "straight-through":
      return straightThrough();
    case "escalation":
      return escalation();
    case "handoff":
      return handoff();
    case "early-exit":
      return earlyExit();
    case "detached":
      return detached();
  }
}

// ── Inks ──────────────────────────────────────────────────────────────────

/**
 * The dark amber edge that keeps a vivid fill from washing out on white, and
 * the hollow outline a locked accent is drawn as. Both are quoted in design
 * units, the way the app quotes them in points at the size that ships.
 *
 * The socket is deliberately neutral rather than a tinted amber. Amber at low
 * opacity is a warm tan on the light page, which made the locked marks read as
 * aged and dirty rather than as waiting. It also puts amber on twenty marks
 * instead of ten, and if every mark is amber to some degree then no mark is a
 * reward.
 */
const EDGE = 1.6;
const SOCKET = 3.6;
/** An inner rim engraved into every amber fill, and the only depth in the set. */
const ENGRAVING = 3.5;

export function BadgeMark({
  motif,
  earned,
  className,
}: {
  motif: Motif;
  earned: boolean;
  className?: string;
}) {
  // useId can contain characters that are awkward inside a url(#...) reference.
  const uid = useId().replace(/[^a-zA-Z0-9]/g, "");
  const parts = partsFor(motif);
  const bodyInk = earned ? "var(--color-fg)" : "var(--color-fg-muted)";
  const ghostOpacity = earned ? 0.62 : 0.45;

  return (
    <svg
      viewBox="0 0 100 100"
      className={cn("shrink-0 overflow-visible", className)}
      aria-hidden
      focusable="false"
    >
      {parts.map((part, i) => {
        const key = `${uid}-${i}`;
        const common = { d: part.d, transform: part.transform };

        if (part.ink === "ghost") {
          return part.w === undefined ? (
            <path key={key} {...common} fill="var(--color-fg-faint)" opacity={ghostOpacity} />
          ) : (
            <path
              key={key}
              {...common}
              fill="none"
              stroke="var(--color-fg-faint)"
              strokeWidth={part.w}
              strokeLinecap="round"
              strokeLinejoin="round"
              opacity={ghostOpacity}
            />
          );
        }

        if (part.ink === "punch") {
          // There is nothing to punch through when the accent is a hollow
          // outline, so the hole is skipped while the badge is locked.
          if (!earned) return null;
          return <path key={key} {...common} fill="var(--color-accent-fg)" opacity={0.85} />;
        }

        if (part.ink === "body") {
          return part.w === undefined ? (
            <path key={key} {...common} fill={bodyInk} />
          ) : (
            <path
              key={key}
              {...common}
              fill="none"
              stroke={bodyInk}
              strokeWidth={part.w}
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          );
        }

        // Accent. The only amber in the mark.
        if (!earned) {
          return (
            <path
              key={key}
              {...common}
              fill="none"
              stroke="var(--color-fg)"
              strokeWidth={part.w === undefined ? SOCKET : Math.max(SOCKET, part.w * 0.85)}
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          );
        }

        if (part.w !== undefined) {
          return (
            <g key={key} transform={part.transform}>
              <path
                d={part.d}
                fill="none"
                stroke="var(--color-suspend-ink)"
                strokeWidth={part.w + EDGE * 2}
                strokeLinecap="round"
                strokeLinejoin="round"
              />
              <path
                d={part.d}
                fill="none"
                stroke="var(--color-suspend)"
                strokeWidth={part.w}
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            </g>
          );
        }

        return (
          <g key={key} transform={part.transform}>
            <clipPath id={`${key}-clip`}>
              <path d={part.d} />
            </clipPath>
            <path d={part.d} fill="var(--color-suspend)" />
            {/* The stroke is clipped to its own path so only the inside half
                survives, which reads as a pressed edge. */}
            <path
              d={part.d}
              fill="none"
              stroke="var(--color-accent-fg)"
              strokeOpacity={0.16}
              strokeWidth={ENGRAVING * 2}
              clipPath={`url(#${key}-clip)`}
            />
            <path d={part.d} fill="none" stroke="var(--color-suspend-ink)" strokeWidth={EDGE} />
          </g>
        );
      })}
    </svg>
  );
}
