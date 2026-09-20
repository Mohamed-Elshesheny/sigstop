"use client";

import { useEffect, useState } from "react";
import { hero, namePitch, site } from "@/content/copy";
import { MenuBarPanel } from "../ui/MenuBarPanel";
import { PixelDevStanding } from "../ui/PixelDevStanding";
import { Button } from "../ui/Primitives";

export function Hero() {
  const [minutes, setMinutes] = useState(41);

  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const id = setInterval(() => setMinutes((m) => (m >= 46 ? 41 : m + 1)), 1600);
    return () => clearInterval(id);
  }, []);

  return (
    <section className="relative overflow-hidden px-5 pb-16 pt-28 sm:px-8 sm:pt-32">
      {/* Grid + radial falloff. Static, cheap, and it does not move while you read. */}
      <div className="pointer-events-none absolute inset-0 grid-bg opacity-[0.55]" aria-hidden />
      <div
        className="pointer-events-none absolute inset-0"
        style={{ background: "radial-gradient(ellipse 90% 55% at 50% 0%, transparent 10%, var(--color-bg) 78%)" }}
        aria-hidden
      />

      <div className="relative mx-auto w-full max-w-6xl">
        {/* Full-bleed headline. Both statements need to land on their own line ,
            orphaning "Not a" above "server." breaks the rhythm of the joke. */}
        <h1 className="font-mono text-[length:var(--text-hero)] font-bold leading-[0.92] tracking-[-0.045em]">
          <span className="block">{hero.headline[0]}</span>
          <span className="block text-fg-faint">
            Not a{" "}
            <span className="relative inline-block text-fg">
              server.
              <svg
                className="absolute -bottom-0.5 left-0 w-full"
                height="12"
                viewBox="0 0 200 12"
                preserveAspectRatio="none"
                aria-hidden
              >
                <path
                  d="M2 8 Q 50 3, 100 7 T 198 5"
                  stroke="var(--color-suspend)"
                  strokeWidth="3"
                  fill="none"
                  strokeLinecap="round"
                />
              </svg>
            </span>
          </span>
        </h1>

        <div className="mt-10 grid items-start gap-12 lg:grid-cols-[1fr_340px] lg:gap-20">
          <div>
            <p className="max-w-xl text-pretty text-lg leading-relaxed text-fg-muted">{hero.sub}</p>

            <div className="mt-9 flex flex-wrap items-center gap-3">
              <Button href="#download">
                {hero.primaryCta}
                <span className="transition-transform duration-200 group-hover:translate-y-0.5" aria-hidden>↓</span>
              </Button>
              <Button href={site.repo} variant="ghost">
                {hero.secondaryCta}
                <span className="transition-transform duration-200 group-hover:translate-x-0.5" aria-hidden>→</span>
              </Button>
            </div>

            {/* He shares a baseline with the fine print, so he sits beside real
                content rather than floating in the right margin. */}
            <div className="mt-6 flex items-end gap-5">
              <p className="max-w-sm font-mono text-xs leading-relaxed text-fg-faint">{hero.note}</p>
              <PixelDevStanding className="h-[4.5rem] w-[2.93rem] shrink-0 sm:h-20 sm:w-[3.25rem]" />
            </div>
          </div>

          {/* The product, shown rather than described. */}
          <div className="w-full max-w-[340px] justify-self-center lg:justify-self-end">
            <MenuBarPanel
              minutes={minutes}
              target={45}
              app="Cursor"
              activity="AI_CODING"
              confidence={0.91}
              evidence={[
                "Frontmost app is Cursor (exact bundle id match)",
                `${minutes} min continuous active input`,
                "Microphone is not active, you're not on a call",
              ]}
            />
            <p className="mt-3 text-center font-mono text-[11px] leading-relaxed text-fg-faint">
              Live. The bars fill as the session does.
            </p>
          </div>
        </div>
      </div>

      {/* The objection this product exists to beat. */}
      <div className="relative mx-auto w-full max-w-6xl border-t border-line pt-10">
        <p className="mb-6 font-mono text-[11px] uppercase tracking-[0.2em] text-fg-faint">{namePitch.kicker}</p>
        <div className="grid gap-8 md:grid-cols-[auto_1fr] md:gap-14">
          <dl className="space-y-4">
            {namePitch.lines.map((l) => (
              <div key={l.sig} className="flex flex-col gap-1 sm:flex-row sm:items-baseline sm:gap-4">
                <dt className="w-24 shrink-0 font-mono text-sm font-bold text-suspend-ink">{l.sig}</dt>
                <dd className="max-w-md text-sm leading-relaxed text-fg-muted">{l.desc}</dd>
              </div>
            ))}
          </dl>
          <div className="md:border-l md:border-line md:pl-14">
            <p className="text-balance font-mono text-2xl font-bold leading-tight tracking-tight sm:text-3xl">
              {namePitch.punch}
            </p>
            <p className="mt-4 max-w-lg text-pretty leading-relaxed text-fg-muted">{namePitch.body}</p>
          </div>
        </div>
      </div>
    </section>
  );
}
