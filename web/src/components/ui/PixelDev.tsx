"use client";

import { useEffect, useState } from "react";

/**
 * A pixel art developer who reacts to the session.
 *
 * Drawn as string art rather than a PNG so it re-themes with the site, stays
 * editable in review, and costs nothing to ship. The grids are GENERATED: the
 * layout script lives in the repo, renders each pose to a preview image, and
 * emits these arrays. Hand-counting 40 columns across four poses is how you get
 * a sheared sprite.
 *
 * Every transparent pixel touching art is promoted to outline by that script.
 * That single pass is most of the difference between flat shapes and a sprite.
 *
 * Poses: typing (2 frames), slumped as the session runs long, and stretching,
 * which is the only frame where the hands leave the keyboard.
 */

const PALETTE: Record<string, string> = {
  O: "var(--px-line)",
  K: "#3c2b1f", k: "#57402d", h: "#78593f",
  S: "#f2c39d", s: "#d49e76",
  G: "#1b1c21", L: "var(--px-lens)", W: "var(--px-lens-hi)", E: "#201508",
  m: "#9e5541",
  A: "#f8f9fb", a: "#c9cdd3",
  T: "#3c4759", d: "#2b3341",
  P: "var(--px-print)",
  M: "#b8bec6", n: "#8e96a1", c: "#6e7682",
  U: "#e85d3a", u: "#bf4527",
  V: "var(--px-steam)",
  D: "var(--px-desk)",
};

const TYPINGA = [
  "........................................",
  "..............OOOOOOOOOOO...............",
  "............OOKhhhhhhKKKKOO.............",
  "...........OKkkkkkkkkkkKKKKO............",
  "..........OKKKKKKKKKKKKKKKKKO...........",
  ".........OKKKKKKKKKKKKKKKKKKKO..........",
  ".........OKKKKKKKKKKKKKKKKKKKO..........",
  ".........OKKKKKKKKKKKKKKKKKKKO..........",
  ".........OKKKSSSKKKKKKKKKKKKKO..........",
  "........OOKKKSSSSSSSSSSSSSKKKOOO........",
  ".......OAAKKKSSSSSSSSSSSSSKKKOAAO.......",
  ".......OAAKGGGGGGSSSSSGGGGGGKOAAO.......",
  ".......OAAKGWEELGGGGGGGWEELGKOaaO.......",
  ".......OAASGLEELGSSSSSGLEELGsOaaO.......",
  ".......OAASGGGGGGSSSSSGGGGGGsOaaO.......",
  "........OOOSSSSSSSSSSSSSSSSsO.OO........",
  "...........OSSSSsmmmmmsSSSsO............",
  "............OSSSSSSSSSSSSsO.............",
  ".............OOSSSSSSSSsOO..............",
  "...............OsssssssO................",
  "............OOOOSSSSSSSOOOO.............",
  ".........OOOTTTTTTTTTTTTTTTOOO......V...",
  ".......OOTTTTTTTTTTTTTTTTTTTTTOO........",
  ".....OOdddTTTTTTTTTTTTTTTTTTTdddOO.V....",
  "....OTTTddTTTPTTTTTTTTPTTPTTTddTTTO.....",
  "....OTTTddTTPPTTTTTTTPTTTPPTTddTTTO..V..",
  "....OTTTddTPPTTTTTTTPTTTTTPPTddTTTO.....",
  "....OTTTddPPTTTTTTTPTTTTTTTPPddTTTO.VV..",
  "....OTTTddPPTTTTTTPTTTTTTTTPPddTTTO.....",
  "....OTTTddTPPTTTTPTTTTTTTTPPTddTTTOVV...",
  "....OTTTddTTPPTTPTTTTTTTTPPTTddTTTO.....",
  "....OTTTddTTTTTTTTTTTTTTTTTTTddTTTO..VV.",
  ".....OMMMMMMMMMMMMMMMMMMMMMMMMMMMOOOOOO.",
  ".....OMMMMMMMMMMMMMMMMMMMMMMMMMMMOUUUUUO",
  ".....OMMMMMMMMMMMMcccMMMMMMMMMMMMOUuuuUO",
  ".....OMMMMMMMMMMMcccccMMMMMMMMMMMOUuuuUU",
  ".....OMMMMMMMMMMMcccccMMMMMMMMMMMOUuuuUU",
  ".....OMMMMMMMMMMMMcccMMMMMMMMMMMMOUuuuUO",
  ".....OMMMMMMMMMMMMMMMMMMMMMMMMMMMOUUUUUO",
  "....OOnnnnnnnnnnnnnnnnnnnnnnnnnnnOOOOOO.",
  "OOOOnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnOOOOO",
  "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
];

const TYPINGB = [
  "........................................",
  "........................................",
  "..............OOOOOOOOOOO...............",
  "............OOKhhhhhhKKKKOO.............",
  "...........OKkkkkkkkkkkKKKKO............",
  "..........OKKKKKKKKKKKKKKKKKO...........",
  ".........OKKKKKKKKKKKKKKKKKKKO..........",
  ".........OKKKKKKKKKKKKKKKKKKKO..........",
  ".........OKKKKKKKKKKKKKKKKKKKO..........",
  ".........OKKKSSSKKKKKKKKKKKKKO..........",
  "........OOKKKSSSSSSSSSSSSSKKKOOO........",
  ".......OAAKKKSSSSSSSSSSSSSKKKOAAO.......",
  ".......OAAKGGGGGGSSSSSGGGGGGKOAAO.......",
  ".......OAAKGWEELGGGGGGGWEELGKOaaO.......",
  ".......OAASGLEELGSSSSSGLEELGsOaaO.......",
  ".......OAASGGGGGGSSSSSGGGGGGsOaaO.......",
  "........OOOSSSSSSSSSSSSSSSSsO.OO........",
  "...........OSSSSsmmmmmsSSSsO............",
  "............OSSSSSSSSSSSSsO.............",
  ".............OOSSSSSSSSsOO..............",
  "............OOOOsssssssOOOO..........V..",
  ".........OOOTTTTTTTTTTTTTTTOOO..........",
  ".......OOTTTTTTTTTTTTTTTTTTTTTOO....V...",
  ".....OOdddTTTTTTTTTTTTTTTTTTTdddOO......",
  "....OTTTddTTTPTTTTTTTTPTTPTTTddTTTOV....",
  "....OTTTddTTPPTTTTTTTPTTTPPTTddTTTO.....",
  "....OTTTddTPPTTTTTTTPTTTTTPPTddTTTO..VV.",
  "....OTTTddPPTTTTTTTPTTTTTTTPPddTTTO.....",
  "....OTTTddPPTTTTTTPTTTTTTTTPPddTTTO.VV..",
  "....OTTTddTPPTTTTPTTTTTTTTPPTddTTTO.....",
  "....OTTTddTTPPTTPTTTTTTTTPPTTddTTTOVV...",
  "....OTTTddTTTTTTTTTTTTTTTTTTTddTTTO.....",
  ".....OMMMMMMMMMMMMMMMMMMMMMMMMMMMOOOOOO.",
  ".....OMMMMMMMMMMMMMMMMMMMMMMMMMMMOUUUUUO",
  ".....OMMMMMMMMMMMMcccMMMMMMMMMMMMOUuuuUO",
  ".....OMMMMMMMMMMMcccccMMMMMMMMMMMOUuuuUU",
  ".....OMMMMMMMMMMMcccccMMMMMMMMMMMOUuuuUU",
  ".....OMMMMMMMMMMMMcccMMMMMMMMMMMMOUuuuUO",
  ".....OMMMMMMMMMMMMMMMMMMMMMMMMMMMOUUUUUO",
  "....OOnnnnnnnnnnnnnnnnnnnnnnnnnnnOOOOOO.",
  "OOOOnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnOOOOO",
  "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
];

const SLUMPED = [
  "........................................",
  "........................................",
  "..............OOOOOOOOOOO...............",
  "............OOKhhhhhhKKKKOO.............",
  "...........OKkkkkkkkkkkKKKKO............",
  "..........OKKKKKKKKKKKKKKKKKO...........",
  ".........OKKKKKKKKKKKKKKKKKKKO..........",
  ".........OKKKKKKKKKKKKKKKKKKKO..........",
  ".........OKKKKKKKKKKKKKKKKKKKO..........",
  ".........OKKKSSSKKKKKKKKKKKKKO..........",
  "........OOKKKSSSSSSSSSSSSSKKKOOO........",
  ".......OAAKKKSSSSSSSSSSSSSKKKOAAO.......",
  ".......OAAKGGGGGGSSSSSGGGGGGKOAAO.......",
  ".......OAAKGWLLLGGGGGGGWLLLGKOaaO.......",
  ".......OAASGLEELGSSSSSGLEELGsOaaO.......",
  ".......OAASGGGGGGSSSSSGGGGGGsOaaO.......",
  "........OOOSSSSSSSSSSSSSSSSsO.OO........",
  "...........OSSSSsmmmmmsSSSsO............",
  "............OSSSSSSSSSSSSsO.............",
  ".............OOSSSSSSSSsOO..............",
  "............OOOOsssssssOOOO.............",
  ".........OOOTTTTTTTTTTTTTTTOOO.....V....",
  ".......OOTTTTTTTTTTTTTTTTTTTTTOO........",
  ".....OOdddTTTTTTTTTTTTTTTTTTTdddOO...V..",
  "....OTTTddTTTPTTTTTTTTPTTPTTTddTTTO.....",
  "....OTTTddTTPPTTTTTTTPTTTPPTTddTTTO.V...",
  "....OTTTddTPPTTTTTTTPTTTTTPPTddTTTO.....",
  "....OTTTddPPTTTTTTTPTTTTTTTPPddTTTOVV...",
  "....OTTTddPPTTTTTTPTTTTTTTTPPddTTTO.....",
  "....OTTTddTPPTTTTPTTTTTTTTPPTddTTTO..VV.",
  "....OTTTddTTPPTTPTTTTTTTTPPTTddTTTO.....",
  "....OTTTddTTTTTTTTTTTTTTTTTTTddTTTO.VV..",
  ".....OMMMMMMMMMMMMMMMMMMMMMMMMMMMOOOOOO.",
  ".....OMMMMMMMMMMMMMMMMMMMMMMMMMMMOUUUUUO",
  ".....OMMMMMMMMMMMMcccMMMMMMMMMMMMOUuuuUO",
  ".....OMMMMMMMMMMMcccccMMMMMMMMMMMOUuuuUU",
  ".....OMMMMMMMMMMMcccccMMMMMMMMMMMOUuuuUU",
  ".....OMMMMMMMMMMMMcccMMMMMMMMMMMMOUuuuUO",
  ".....OMMMMMMMMMMMMMMMMMMMMMMMMMMMOUUUUUO",
  "....OOnnnnnnnnnnnnnnnnnnnnnnnnnnnOOOOOO.",
  "OOOOnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnOOOOO",
  "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
];

const STRETCHING = [
  "........................................",
  "..............OOOOOOOOOOO...............",
  "............OOKhhhhhhKKKKOO.............",
  "...........OKkkkkkkkkkkKKKKO............",
  "..OOOO....OKKKKKKKKKKKKKKKKKO....OOOO...",
  ".OsSSSO..OKKKKKKKKKKKKKKKKKKKO..OSSSsO..",
  ".OSSSSO..OKKKKKKKKKKKKKKKKKKKO..OSSSSO..",
  ".OSSSSO..OKKKKKKKKKKKKKKKKKKKO..OSSSSO..",
  ".OSSSSO..OKKKSSSKKKKKKKKKKKKKO..OSSSSO..",
  "..OTTTO.OOKKKSSSSSSSSSSSSSKKKOOOOTTTO...",
  "..OTTTOOAAKKKSSSSSSSSSSSSSKKKOAAOTTTO...",
  "..OTTTOOAAKGGGGGGSSSSSGGGGGGKOAAOTTTO...",
  "..OTTTOOAAKGWEELGGGGGGGWEELGKOaaOTTTO...",
  "...OTTTOAASGLEELGSSSSSGLEELGsOaaTTTO....",
  "...OTTTOAASGGGGGGSSSSSGGGGGGsOaaTTTO....",
  "...OTTTOOOOSSSSSSSSSSSSSSSSsO.OOTTTO....",
  "...OTTTO...OSSSSsmmmmmsSSSsO...OTTTO....",
  "...OTTTO....OSSSSSSSSSSSSsO....OTTTO....",
  "....OTTTO....OOSSSSSSSSsOO....OTTTO.....",
  "....OTTTO......OsssssssO......OTTTO.....",
  "....OTTTO...OOOOSSSSSSSOOOO...OTTTO.....",
  "....OTTTOOOOTTTTTTTTTTTTTTTOOOOTTTO.V...",
  "....OTTTOTTTTTTTTTTTTTTTTTTTTTOTTTO.....",
  ".....OOdddTTTTTTTTTTTTTTTTTTTdddOO.V....",
  "......OdddTTTPTTTTTTTTPTTPTTTdddO.......",
  "......OdddTTPPTTTTTTTPTTTPPTTdddO....V..",
  "......OdddTPPTTTTTTTPTTTTTPPTdddO.......",
  "......OdddPPTTTTTTTPTTTTTTTPPdddO...VV..",
  "......OdddPPTTTTTTPTTTTTTTTPPdddO.......",
  "......OdddTPPTTTTPTTTTTTTTPPTdddO..VV...",
  "......OdddTTPPTTPTTTTTTTTPPTTdddO.......",
  "......OdddTTTTTTTTTTTTTTTTTTTdddO....VV.",
  ".....OMMMMMMMMMMMMMMMMMMMMMMMMMMMOOOOOO.",
  ".....OMMMMMMMMMMMMMMMMMMMMMMMMMMMOUUUUUO",
  ".....OMMMMMMMMMMMMcccMMMMMMMMMMMMOUuuuUO",
  ".....OMMMMMMMMMMMcccccMMMMMMMMMMMOUuuuUU",
  ".....OMMMMMMMMMMMcccccMMMMMMMMMMMOUuuuUU",
  ".....OMMMMMMMMMMMMcccMMMMMMMMMMMMOUuuuUO",
  ".....OMMMMMMMMMMMMMMMMMMMMMMMMMMMOUUUUUO",
  "....OOnnnnnnnnnnnnnnnnnnnnnnnnnnnOOOOOO.",
  "OOOOnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnOOOOO",
  "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
];

const FRAMES = { typingA: TYPINGA, typingB: TYPINGB, slumped: SLUMPED, stretching: STRETCHING };
const W = TYPINGA[0].length;

export type PixelDevState = "typing" | "slumped" | "stretching";

function Sprite({ rows }: { rows: string[] }) {
  return (
    <svg
      viewBox={`0 0 ${W} ${rows.length}`}
      shapeRendering="crispEdges"
      className="h-full w-full"
      role="img"
      aria-label="A pixel art developer at a laptop, wearing glasses and earbuds"
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
          "--px-line": "#100f0d",
          "--px-lens": "var(--color-suspend)",
          "--px-lens-hi": "color-mix(in srgb, var(--color-suspend) 45%, white)",
          "--px-print": "var(--color-running)",
          "--px-desk": "var(--color-line-hi)",
          "--px-steam": "color-mix(in srgb, var(--color-fg) 35%, transparent)",
        } as React.CSSProperties
      }
    >
      <Sprite rows={rows} />
    </div>
  );
}
