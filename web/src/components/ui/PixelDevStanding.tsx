"use client";

import { useEffect, useState } from "react";

/**
 * The small standing figure at the top of the page.
 *
 * It runs one loop: get up, straighten, reach, arch back, settle. That is the
 * product in four frames, above the fold, before anyone has read a word.
 *
 * Same generated-string-art approach as PixelDev: the layout script is committed
 * next to this file and emits these grids, so nobody hand counts columns.
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
  "..........................",
  "..OOO...OOOOOOO....OOO....",
  ".OSSSO.OkkkkkkkOO.OSSSO...",
  ".OSSSOOKKKKKKKKKKOOSSSO...",
  "..OTTTOKKKKKKKKKKOTTTO....",
  "..OTTTKKKKKKKKKKKKTTTO....",
  "..OTTTKSSSSSSSSSSKTTTO....",
  "..OTTTKSSSSSSSSSSKTTTO....",
  "..OTTTKGGGGSSGGGGKTTTO....",
  "..OTTTOGLEGGGGELGOTTTO....",
  "..OTTTOSSSSSSSSSSOTTTO....",
  "..OTTTOSSSmmmmSSSOTTTO....",
  "..OTTTOSSSSSSSSSsOTTTO....",
  "..OTTTOOOOSSSSOOOOTTTO....",
  "..OTTTOddTTTTTTTTOTTTO....",
  "..OTTTOddTTTTTTTTOTTTO....",
  "...OOOOddTTTTTTTTOOOO.....",
  "......OddTTTTTTTTO........",
  "......OddTTPTPTTTO........",
  "......OddTPTTTPTTO........",
  "......OddPTTTTTPTO........",
  "......OddTPTTTPTTO........",
  "......OddTTPTPTTTO........",
  "......OddTTTTTTTTO........",
  "......OddTTTTTTTTO........",
  ".......OOJJJOOJJJO........",
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

/** One cycle of the stretch, held for the given number of ticks each. */
const SEQUENCE: { rows: string[]; hold: number; label: string }[] = [
  { rows: RISING,   hold: 3, label: "standing up" },
  { rows: STANDING, hold: 3, label: "standing" },
  { rows: REACHUP,  hold: 4, label: "reaching up" },
  { rows: BACKARCH, hold: 5, label: "stretching" },
  { rows: STANDING, hold: 6, label: "standing" },
];

const W = STANDING[0].length;

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
    }, 240);
    return () => clearInterval(id);
  }, []);

  // Under reduced motion the figure simply stands. It still communicates who
  // this is for; it just does not move while someone is trying to read.
  const frame = reduced ? SEQUENCE[1] : SEQUENCE[step];

  return (
    <div
      className={className}
      style={
        {
          "--px-line": "var(--color-fg)",
          "--px-lens": "var(--color-suspend)",
          "--px-print": "var(--color-running)",
        } as React.CSSProperties
      }
    >
      <svg
        viewBox={`0 0 ${W} ${frame.rows.length}`}
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
