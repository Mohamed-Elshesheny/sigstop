"use client";

import { useEffect, useRef, useState } from "react";
import { problem as copy } from "@/content/copy";
import { Section, Kicker, Headline, Lede } from "../ui/Primitives";
import { useReveal } from "@/lib/useReveal";
import { cn } from "@/lib/cn";

const DAY = copy.day;
/** The last row is the day's total; every meter is drawn relative to it. */
const PEAK = DAY[DAY.length - 1].sitting;

/**
 * Reveals rows in scroll order and reports how far the reader has got.
 *
 * Monotonic on purpose: scrolling back up must not un-fill the rail. The whole
 * argument of this section is that the number only ever goes one direction, and
 * a counter that ticked backwards would quietly contradict it.
 *
 * Under prefers-reduced-motion every row is reported reached immediately, so
 * nothing is gated behind an animation that will not run.
 */
function useSequence(count: number) {
  const refs = useRef<(HTMLLIElement | null)[]>([]);
  const [reached, setReached] = useState(-1);

  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setReached(count - 1);
      return;
    }

    const obs = new IntersectionObserver(
      (entries) => {
        let high = -1;
        for (const e of entries) {
          if (!e.isIntersecting) continue;
          const i = Number((e.target as HTMLElement).dataset.index);
          if (i > high) high = i;
        }
        if (high >= 0) setReached((prev) => Math.max(prev, high));
      },
      { threshold: 0.35, rootMargin: "0px 0px -18% 0px" },
    );

    for (const el of refs.current) if (el) obs.observe(el);
    return () => obs.disconnect();
  }, [count]);

  return { refs, reached };
}

/** The accumulating column, a level meter, not a decoration. */
function SeatedMeter({ minutes, filled }: { minutes: number; filled: boolean }) {
  return (
    <div className="flex items-center gap-3">
      <div className="h-1.5 min-w-0 flex-1 overflow-hidden rounded-[1px] bg-surface-hi">
        <div
          className="h-full border-r border-suspend bg-suspend/25 transition-all duration-700 ease-[var(--ease-out-expo)]"
          style={{ width: filled ? `${(minutes / PEAK) * 100}%` : "0%" }}
        />
      </div>
      <span className="w-12 shrink-0 text-right font-mono text-xs tabular-nums text-fg-muted">
        {minutes}
        {"m"}
      </span>
    </div>
  );
}

export function DeveloperDay() {
  const { ref: headRef, visible: headVisible } = useReveal<HTMLDivElement>();
  const { ref: tailRef, visible: tailVisible } = useReveal<HTMLDivElement>();
  const { refs, reached } = useSequence(DAY.length);

  const seated = reached >= 0 ? DAY[reached].sitting : 0;

  return (
    <Section>
      <div ref={headRef} className="reveal" data-visible={headVisible}>
        <Kicker>{copy.kicker}</Kicker>
        <Headline>{copy.headline}</Headline>
        <Lede>{copy.sub}</Lede>
        <p className="mt-5 font-mono text-xs text-fg-faint">{copy.ui.counterHint}</p>
      </div>

      <div className="relative mt-12">
        {/* Running counter. Sticky under the nav so the number stays in frame
            while the rows scroll past it, the accumulation is the argument.
            Hidden from assistive tech: every row already states its own total. */}
        <div
          className="sticky top-16 z-20 rounded-lg border border-line bg-bg/85 px-4 py-3 backdrop-blur-md sm:px-5"
          aria-hidden
        >
          <div className="flex items-baseline justify-between gap-4">
            <span className="font-mono text-[11px] uppercase tracking-[0.18em] text-fg-faint">
              {copy.ui.counterLabel}
            </span>
            <span className="flex items-baseline gap-1.5 font-mono tabular-nums">
              <span className="text-2xl font-bold leading-none text-suspend sm:text-3xl">{seated}</span>
              <span className="text-xs text-fg-faint">{copy.ui.counterUnit}</span>
            </span>
          </div>
          <div className="mt-2.5 h-px w-full bg-line">
            <div
              className="h-px bg-suspend transition-all duration-700 ease-[var(--ease-out-expo)]"
              style={{ width: `${(seated / PEAK) * 100}%` }}
            />
          </div>
        </div>

        {/* Column headings. Decorative on mobile-sized layouts, where each row
            labels its own meter, so they are marked hidden rather than faked. */}
        <div
          className="mt-8 hidden grid-cols-[4.5rem_1.75rem_minmax(0,1fr)_minmax(0,17rem)] gap-x-5 border-b border-line pb-2 font-mono text-[10px] uppercase tracking-[0.18em] text-fg-faint sm:grid"
          aria-hidden
        >
          <span>{copy.ui.colTime}</span>
          <span />
          <span>{copy.ui.colEvent}</span>
          <span className="text-right">{copy.ui.colSeated}</span>
        </div>

        <ol className="mt-2">
          {DAY.map((row, i) => {
            const on = i <= reached;
            return (
              <li
                key={row.time}
                ref={(el) => {
                  refs.current[i] = el;
                }}
                data-index={i}
                data-visible={on}
                className="reveal grid grid-cols-[3.25rem_1.5rem_minmax(0,1fr)] gap-x-3 sm:grid-cols-[4.5rem_1.75rem_minmax(0,1fr)_minmax(0,17rem)] sm:gap-x-5"
              >
                <time className="py-4 font-mono text-xs leading-5 tabular-nums text-fg-faint">
                  {row.time}
                </time>

                {/* The rail. Each row owns its segment, so it reads as one
                    continuous line that colours in as you scroll. */}
                <span className="relative flex justify-center" aria-hidden>
                  <span
                    className={cn(
                      "absolute w-px transition-colors duration-500",
                      i === 0 ? "bottom-0 top-[1.35rem]" : "inset-y-0",
                      on ? "bg-suspend/40" : "bg-line",
                    )}
                  />
                  <span
                    className={cn(
                      "relative mt-[0.95rem] h-2 w-2 shrink-0 rounded-full border transition-colors duration-500",
                      on ? "border-suspend bg-suspend" : "border-line-hi bg-bg",
                    )}
                  />
                </span>

                <div className="min-w-0 py-4">
                  <p className="font-mono text-[15px] leading-snug text-fg">{row.label}</p>
                  <p className="mt-1 text-pretty text-sm leading-relaxed text-fg-muted">{row.detail}</p>
                  <div className="mt-3 sm:hidden">
                    <SeatedMeter minutes={row.sitting} filled={on} />
                  </div>
                </div>

                <div className="hidden py-4 sm:flex sm:items-center">
                  <SeatedMeter minutes={row.sitting} filled={on} />
                </div>
              </li>
            );
          })}
        </ol>

        <p className="mt-6 pl-[3.25rem] font-mono text-sm leading-relaxed text-fg-muted sm:pl-[4.5rem]">
          {copy.ui.closing}
        </p>
      </div>

      <div
        ref={tailRef}
        className="reveal mt-12 rounded-xl border border-line bg-surface/40 p-6 sm:p-8"
        data-visible={tailVisible}
      >
        <div className="flex flex-wrap items-baseline gap-x-6 gap-y-2">
          <p className="font-mono text-[clamp(2.5rem,9vw,4.5rem)] font-bold leading-none tracking-[-0.04em] tabular-nums text-suspend">
            {copy.footer.stat}
          </p>
          <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-fg-faint">
            {copy.footer.label}
          </p>
        </div>
        <p className="mt-6 max-w-2xl border-t border-line pt-6 text-pretty text-lg leading-relaxed text-fg">
          {copy.footer.line}
        </p>
        <p className="mt-3 font-mono text-xs text-fg-faint">{copy.ui.runningTotal}</p>
      </div>
    </Section>
  );
}
