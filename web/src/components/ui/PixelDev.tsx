"use client";

import { useEffect, useState } from "react";

/**
 * A pixel art developer who reacts to the session.
 *
 * Drawn as string art rather than a sprite sheet or a PNG, so the character is
 * readable and editable directly in source, and so it re-themes with the rest
 * of the site instead of being an image that only works on one background.
 *
 * Frames are composed as a base pose plus row overrides. Authoring four full
 * 44-column grids by hand invites off-by-one shearing; overriding the six rows
 * that actually change does not.
 */

const PALETTE: Record<string, string> = {
  K: "var(--px-hair)",
  k: "var(--px-hair-hi)",
  S: "var(--px-skin)",
  s: "var(--px-skin-sh)",
  G: "var(--px-frame)",   // glasses frame
  L: "var(--px-lens)",    // lens, catches the screen
  m: "var(--px-mouth)",
  A: "var(--px-pod)",     // AirPods
  T: "var(--px-shirt)",
  P: "var(--px-print)",   // the </> on the shirt
  D: "var(--px-desk)",
  C: "var(--px-key)",
  U: "var(--px-mug)",
  u: "var(--px-mug-sh)",
};

const W = 44;

// Hands resting on the keyboard.
const BASE = [
  "............................................",
  "............................................",
  "...............KKKKKKKKKKKKK................",
  ".............KKKKKKKKKKKKKKKKK..............",
  "............KKKKKKKKKKKKKKKKKKK.............",
  "............KKkkkkkkkkkkkkkkKKK.............",
  "............KKSSSSSSSSSSSSSSSKK.............",
  "...........AKSSSSSSSSSSSSSSSSSKA............",
  "...........ASSSSSSSSSSSSSSSSSSSA............",
  "...........AGGGGGGGSGGGGGGGGGGGA............",
  "...........AGLLLLLGSGGLLLLLGGGGA............",
  "...........AGLLLLLGSGGLLLLLGGGGA............",
  "...........AAGGGGGGSSGGGGGGGGGAA............",
  "............SSSSSSSSSSSSSSSSSS..............",
  ".............SSSSSSmmmmSSSSSSS..............",
  "..............SSSSSSSSSSSSSSS...............",
  "................SSSSSSSSSSS.................",
  "..................sSSSSSs...................",
  "...........TTTTTTTTTTTTTTTTTTTT.............",
  "..........TTTTTTTTTTTTTTTTTTTTTT............",
  ".........TTTTTTTTTTTTTTTTTTTTTTTT...........",
  ".........TTTTTTTTTTTTTTTTTTTTTTTT...........",
  ".........TTTTTTPTTTTTTPTTPTTTTTTT...........",
  ".........TTTTPTTTTTTTPTTTTTPTTTTT...........",
  ".........TTPTTTTTTTTPTTTTTTTTPTTT...........",
  ".........TTTTPTTTTTPTTTTTTTPTTTTT...........",
  ".........TTTTTTPTTPTTTTTTPTTTTTTT...........",
  "........STTTTTTTTTTTTTTTTTTTTTTTTS..........",
  ".......SSTTTTTTTTTTTTTTTTTTTTTTTTSS.........",
  ".......SSSTTTTTTTTTTTTTTTTTTTTTTSSS.........",
  "....DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD.UUUU...",
  "....DCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCD.UuuU...",
  "....DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD.UUUU...",
  "............................................",
];

/** Only the two hand rows move while typing. */
const TYPING_B: Record<number, string> = {
  27: ".........TTTTTTTTTTTTTTTTTTTTTTTTT..........",
  28: ".......SSTTTTTTTTTTTTTTTTTTTTTTTTSS.........",
};

/** Head and shoulders sink; the jaw pushes forward. Same person, worse hour. */
const SLUMPED: Record<number, string> = {
  2: "............................................",
  3: "...............KKKKKKKKKKKKK................",
  4: ".............KKKKKKKKKKKKKKKKK..............",
  5: "............KKKKKKKKKKKKKKKKKKK.............",
  6: "............KKkkkkkkkkkkkkkkKKK.............",
  7: "...........AKSSSSSSSSSSSSSSSSSKA............",
  8: "...........ASSSSSSSSSSSSSSSSSSSA............",
  9: "...........AGGGGGGGSGGGGGGGGGGGA............",
  10: "...........AGLLLLLGSGGLLLLLGGGGA............",
  11: "...........AGLLLLLGSGGLLLLLGGGGA............",
  12: "...........AAGGGGGGSSGGGGGGGGGAA............",
  13: "............SSSSSSSSSSSSSSSSSS..............",
  14: ".............SSSSSmmmmmmSSSSSS..............",
  15: "..............SSSSSSSSSSSSSSS...............",
  16: "................SSSSSSSSSSS.................",
};

/** Arms up. The only frame where the hands leave the keyboard. */
const STRETCHING: Record<number, string> = {
  18: "....SSS....TTTTTTTTTTTTTTTTTTTT....SSS......",
  19: "....SSS...TTTTTTTTTTTTTTTTTTTTTT...SSS......",
  20: "....SSS..TTTTTTTTTTTTTTTTTTTTTTTT..SSS......",
  21: "....SSS..TTTTTTTTTTTTTTTTTTTTTTTT..SSS......",
  27: ".....SSSSTTTTTTTTTTTTTTTTTTTTTTTTSSSS.......",
  28: "......SSSTTTTTTTTTTTTTTTTTTTTTTTTSSS........",
  29: ".........TTTTTTTTTTTTTTTTTTTTTTTT...........",
};

function compose(overrides: Record<number, string> = {}): string[] {
  return BASE.map((row, i) => (overrides[i] ?? row).padEnd(W, ".").slice(0, W));
}

const FRAMES = {
  typingA: compose(),
  typingB: compose(TYPING_B),
  slumped: compose(SLUMPED),
  stretching: compose(STRETCHING),
};

export type PixelDevState = "typing" | "slumped" | "stretching";

function Sprite({ rows }: { rows: string[] }) {
  return (
    <svg
      viewBox={`0 0 ${W} ${rows.length}`}
      shapeRendering="crispEdges"
      className="h-full w-full"
      role="img"
      aria-label="A pixel art developer at a desk, wearing glasses and AirPods"
    >
      {rows.flatMap((row, y) =>
        [...row].map((ch, x) =>
          ch === "." ? null : (
            <rect key={`${x}-${y}`} x={x} y={y} width={1} height={1} fill={PALETTE[ch]} />
          ),
        ),
      )}
    </svg>
  );
}

export function PixelDev({
  state = "typing",
  className,
}: {
  state?: PixelDevState;
  className?: string;
}) {
  const [tick, setTick] = useState(0);
  const [reduced, setReduced] = useState(false);

  useEffect(() => {
    const mq = window.matchMedia("(prefers-reduced-motion: reduce)");
    setReduced(mq.matches);
    if (mq.matches) return;
    // ~4 keystrokes a second: reads as typing without strobing.
    const id = setInterval(() => setTick((t) => t + 1), 250);
    return () => clearInterval(id);
  }, []);

  const rows =
    state === "stretching"
      ? FRAMES.stretching
      : state === "slumped"
        ? FRAMES.slumped
        : reduced || tick % 2 === 0
          ? FRAMES.typingA
          : FRAMES.typingB;

  return (
    <div
      className={className}
      style={
        {
          "--px-hair": "#2f2620",
          "--px-hair-hi": "#43362c",
          "--px-skin": "#e8b489",
          "--px-skin-sh": "#c9946c",
          "--px-frame": "#14171a",
          // The lenses pick up the screen, which is the only light in the room.
          "--px-lens": "color-mix(in srgb, var(--color-suspend) 75%, #000)",
          "--px-mouth": "#9c5a45",
          "--px-pod": "#f2f3f5",
          "--px-shirt": "#2b3440",
          "--px-print": "var(--color-running)",
          "--px-desk": "var(--color-line-hi)",
          "--px-key": "var(--color-surface-hi)",
          "--px-mug": "var(--color-suspend)",
          "--px-mug-sh": "color-mix(in srgb, var(--color-suspend) 60%, #000)",
        } as React.CSSProperties
      }
    >
      <Sprite rows={rows} />
    </div>
  );
}
