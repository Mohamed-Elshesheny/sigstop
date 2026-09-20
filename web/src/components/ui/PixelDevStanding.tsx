"use client";

import { useEffect, useState } from "react";

/**
 * The small figure that gets up and stretches, in the hero.
 *
 * Two things this went through several bad versions to learn:
 *
 *  1. The outline must be a FIXED dark value, not a theme token. Bound to
 *     --color-fg it turned near-white in dark mode and drew a halo.
 *  2. Going straight from arms-down to arms-up is a jump cut, not a motion.
 *     `reachHalf` is the in-between frame that makes it read as a raise, and
 *     `backArch` sweeps the arms wider so it does not share a silhouette with
 *     `reachUp`.
 *
 * Generated string art; the layout script is committed next to this file.
 */

const PALETTE: Record<string, string> = {
  O: "var(--px-line)",
  K: "#3c2b1f", k: "#57402d",
  S: "#f2c39d", s: "#d49e76",
  G: "#1b1c21", L: "var(--px-lens)", E: "#201508",
  m: "#9e5541",
  A: "#f8f9fb",
  T: "#3c4759", d: "#2b3341",
  P: "var(--px-print)",
  J: "#232a36",
  B: "#222429",
};

const SIT = [
  "..........................",
  "..........................",
  "..........................",
  "..........................",
  "..........................",
  "..........................",
  ".........OOOOOOO..........",
  "........OkkkkkkkOO........",
  ".......OKKKKKKKKKKO.......",
  ".......OKKKKKKKKKKO.......",
  "......OKKKKKKKKKKKKO......",
  "......OKSSSSSSSSSSKO......",
  "......OKSSSSSSSSSSKO......",
  ".....OAKGGGGSSGGGGKAO.....",
  ".....OAOGLEGGGGELGOAO.....",
  "......OOSSSSSSSSSSOO......",
  ".......OSSSmmmmSSSO.......",
  ".......OSSSSSSSSSsO.......",
  "........OOOSSSSOOO........",
  ".....OOOddTTTTTTTTOOO.....",
  "....OTTTOdTTTTTTTOTTTO....",
  "....OTTTOdTTTTTTTOTTTO....",
  "....OTTTOdTTTTTTTOTTTO....",
  "....OTTTOdTTPTPTTOTTTO....",
  "....OTTTOdTPTTTPTOTTTO....",
  "....OTTTOdPTTTTTPOTTTO....",
  "....OTTTOdTPTTTPTOTTTO....",
  "....OTTTOdTTPTPTTOTTTO....",
  "....OTTTOdTTTTTTTOTTTO....",
  "....OSSSddTTTTTTTTSSSO....",
  "....OSSSJJJJOOJJJJSSSO....",
  ".....OOOJJJJOOJJJJOOO.....",
  ".......OJJJJOOJJJJO.......",
  ".......OJJJJOOJJJJO.......",
  ".......OJJJJOOJJJJO.......",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  ".......OBBBBBBBBBBO.......",
  ".......OBBBBBBBBBBO.......",
  "........OOOOOOOOOO........",
];

const RISING = [
  "..........................",
  "..........................",
  "..........................",
  "..........OOOOOOO.........",
  ".........OkkkkkkkOO.......",
  "........OKKKKKKKKKKO......",
  "........OKKKKKKKKKKO......",
  ".......OKKKKKKKKKKKKO.....",
  ".......OKSSSSSSSSSSKO.....",
  ".......OKSSSSSSSSSSKO.....",
  "......OAKGGGGSSGGGGKAO....",
  "......OAOGLEGGGGELGOAO....",
  ".......OOSSSSSSSSSSOO.....",
  "........OSSSmmmmSSSO......",
  "........OSSSSSSSSSsO......",
  ".........OOOSSSSOOO.......",
  "......OOOddTTTTTTTTOOO....",
  ".....OTTTOdTTTTTTTOTTTO...",
  ".....OTTTOdTTTTTTTOTTTO...",
  ".....OTTTOdTTTTTTTOTTTO...",
  ".....OTTTOdTTPTPTTOTTTO...",
  ".....OTTTOdTPTTTPTOTTTO...",
  ".....OTTTOdPTTTTTPOTTTO...",
  ".....OTTTOdTPTTTPTOTTTO...",
  ".....OTTTOdTTPTPTTOTTTO...",
  ".....OTTTOdTTTTTTTOTTTO...",
  ".....OSSSddTTTTTTTTSSSO...",
  ".....OSSJJJJOOJJJJOSSSO...",
  "......OOJJJJOOJJJJOOOO....",
  ".......OJJJJOOJJJJO.......",
  ".......OJJJJOOJJJJO.......",
  ".......OJJJJOOJJJJO.......",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  ".......OBBBBBBBBBBO.......",
  ".......OBBBBBBBBBBO.......",
  "........OOOOOOOOOO........",
];

const STANDING = [
  "..........................",
  ".........OOOOOOO..........",
  "........OkkkkkkkOO........",
  ".......OKKKKKKKKKKO.......",
  ".......OKKKKKKKKKKO.......",
  "......OKKKKKKKKKKKKO......",
  "......OKSSSSSSSSSSKO......",
  "......OKSSSSSSSSSSKO......",
  ".....OAKGGGGSSGGGGKAO.....",
  ".....OAOGLEGGGGELGOAO.....",
  "......OOSSSSSSSSSSOO......",
  ".......OSSSmmmmSSSO.......",
  ".......OSSSSSSSSSsO.......",
  "........OOOSSSSOOO........",
  ".....OOOddTTTTTTTTOOO.....",
  "....OTTTOdTTTTTTTOTTTO....",
  "....OTTTOdTTTTTTTOTTTO....",
  "....OTTTOdTTTTTTTOTTTO....",
  "....OTTTOdTTPTPTTOTTTO....",
  "....OTTTOdTPTTTPTOTTTO....",
  "....OTTTOdPTTTTTPOTTTO....",
  "....OTTTOdTPTTTPTOTTTO....",
  "....OTTTOdTTPTPTTOTTTO....",
  "....OTTTOdTTTTTTTOTTTO....",
  "....OSSSddTTTTTTTTSSSO....",
  "....OSSSOJJJOOJJJOSSSO....",
  ".....OOOOJJJOOJJJOOOO.....",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  ".......OBBBBBBBBBBO.......",
  ".......OBBBBBBBBBBO.......",
  "........OOOOOOOOOO........",
];

const REACHHALF = [
  "..........................",
  ".........OOOOOOO..........",
  "........OkkkkkkkOO........",
  ".......OKKKKKKKKKKO.......",
  ".......OKKKKKKKKKKO.......",
  "......OKKKKKKKKKKKKO......",
  "......OKSSSSSSSSSSKO......",
  "......OKSSSSSSSSSSKO......",
  ".....OAKGGGGSSGGGGKAO.....",
  "...OOOAOGLEGGGGELGOAOOO...",
  "..OSSSOOSSSSSSSSSSOOSSSO..",
  "..OSSSOOSSSmmmmSSSOOSSSO..",
  "..OTTTOOSSSSSSSSSsOOTTTO..",
  "..OTTTO.OOOSSSSOOO.OTTTO..",
  "..OTTTOOddTTTTTTTTOOTTTO..",
  "..OTTTTTOdTTTTTTTOTTTTTO..",
  "..OTTTTTOdTTTTTTTOTTTTTO..",
  "...OOOOOOdTTTTTTTOOOOOO...",
  "........OdTTPTPTTO........",
  "........OdTPTTTPTO........",
  "........OdPTTTTTPO........",
  "........OdTPTTTPTO........",
  "........OdTTPTPTTO........",
  "........OdTTTTTTTO........",
  ".......OddTTTTTTTTO.......",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  ".......OBBBBBBBBBBO.......",
  ".......OBBBBBBBBBBO.......",
  "........OOOOOOOOOO........",
];

const REACHUP = [
  "....OSSSO........OSSSO....",
  "....OTTTOOOOOOOO.OTTTO....",
  "....OTTTOkkkkkkkOOTTTO....",
  "....OTTTKKKKKKKKKKTTTO....",
  "....OTTTKKKKKKKKKKTTTO....",
  "....OTTTKKKKKKKKKKTTTO....",
  "....OTTTSSSSSSSSSSTTTO....",
  "....OTTTSSSSSSSSSSTTTO....",
  "....OTTTGGGGSSGGGGTTTO....",
  "....OTTTGLEGGGGELGTTTO....",
  "....OTTTSSSSSSSSSSTTTO....",
  "....OTTTSSSmmmmSSSTTTO....",
  "....OTTTSSSSSSSSSsTTTO....",
  "....OTTTOOOSSSSOOOTTTO....",
  "....OTTTddTTTTTTTTTTTO....",
  "....OTTTddTTTTTTTTTTTO....",
  ".....OOOddTTTTTTTTOOO.....",
  ".......OddTTTTTTTTO.......",
  ".......OddTTPTPTTTO.......",
  ".......OddTPTTTPTTO.......",
  ".......OddPTTTTTPTO.......",
  ".......OddTPTTTPTTO.......",
  ".......OddTTPTPTTTO.......",
  ".......OddTTTTTTTTO.......",
  ".......OddTTTTTTTTO.......",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  ".......OBBBBBBBBBBO.......",
  ".......OBBBBBBBBBBO.......",
  "........OOOOOOOOOO........",
];

const BACKARCH = [
  "..........................",
  ".........OOOOOOO..........",
  "........OkkkkkkkOO........",
  ".OOO...OKKKKKKKKKKO...OOO.",
  "OSSSO..OKKKKKKKKKKO..OSSSO",
  "OSSSO.OKKKKKKKKKKKKO.OSSSO",
  ".OTTTOOKSSSSSSSSSSKOOTTTO.",
  ".OTTTOOKSSSSSSSSSSKOOTTTO.",
  ".OTTTOAKGGGGSSGGGGKAOTTTO.",
  ".OTTTOAOGLEGGGGELGOAOTTTO.",
  ".OTTTOOOSSSSSSSSSSOOOTTTO.",
  ".OTTTO.OSSSmmmmSSSO.OTTTO.",
  ".OTTTO.OSSSSSSSSSsO.OTTTO.",
  ".OTTTO..OOOSSSSOOO..OTTTO.",
  ".OTTTO.OddTTTTTTTTO.OTTTO.",
  ".OTTTO.OddTTTTTTTTO.OTTTO.",
  ".OTTTO.OddTTTTTTTTO.OTTTO.",
  "..OOO..OddTTTTTTTTO..OOO..",
  ".......OddTTPTPTTTO.......",
  ".......OddTPTTTPTTO.......",
  ".......OddPTTTTTPTO.......",
  ".......OddTPTTTPTTO.......",
  ".......OddTTPTPTTTO.......",
  ".......OddTTTTTTTTO.......",
  ".......OddTTTTTTTTO.......",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  "........OJJJOOJJJO........",
  ".......OBBBBBBBBBBO.......",
  ".......OBBBBBBBBBBO.......",
  "........OOOOOOOOOO........",
];

/** Holds in ticks. Transitions are quick, the stretch itself is held. */
const SEQUENCE: { rows: string[]; hold: number; label: string }[] = [
  { rows: SIT,       hold: 12, label: "hunched at the desk" },
  { rows: RISING,    hold: 2,  label: "getting up" },
  { rows: STANDING,  hold: 4,  label: "standing" },
  { rows: REACHHALF, hold: 2,  label: "raising his arms" },
  { rows: REACHUP,   hold: 6,  label: "reaching up" },
  { rows: BACKARCH,  hold: 9,  label: "stretching his back" },
  { rows: REACHUP,   hold: 3,  label: "reaching up" },
  { rows: REACHHALF, hold: 2,  label: "lowering his arms" },
  { rows: STANDING,  hold: 7,  label: "standing" },
];

const W = STANDING[0].length;
const H = STANDING.length;

export function PixelDevStanding({ className }: { className?: string }) {
  const [step, setStep] = useState(0);
  const [reduced, setReduced] = useState(false);

  useEffect(() => {
    const mq = window.matchMedia("(prefers-reduced-motion: reduce)");
    setReduced(mq.matches);
    if (mq.matches) return;
    let hold = 0;
    const id = setInterval(() => {
      hold += 1;
      setStep((s) => {
        if (hold < SEQUENCE[s].hold) return s;
        hold = 0;
        return (s + 1) % SEQUENCE.length;
      });
    }, 170);
    return () => clearInterval(id);
  }, []);

  const frame = reduced ? SEQUENCE[2] : SEQUENCE[step];

  return (
    <div
      className={className}
      style={
        {
          "--px-line": "#100f0d",
          "--px-lens": "var(--color-suspend)",
          "--px-print": "var(--color-running)",
        } as React.CSSProperties
      }
    >
      <svg
        viewBox={`0 0 ${W} ${H}`}
        shapeRendering="crispEdges"
        className="h-full w-full"
        role="img"
        aria-label={`A pixel art developer, ${frame.label}`}
      >
        {frame.rows.flatMap((row, y) =>
          [...row].map((ch, x) =>
            ch === "." ? null : (
              <rect key={`${x}-${y}`} x={x} y={y} width={1} height={1} fill={PALETTE[ch]} />
            ),
          ),
        )}
      </svg>
    </div>
  );
}
