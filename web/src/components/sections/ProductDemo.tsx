"use client";

import { useEffect, useState } from "react";
import { productDemo as copy } from "@/content/copy";
import { PixelDev, type PixelDevState } from "../ui/PixelDev";
import { MenuBarIcon } from "../ui/MenuBarIcon";
import { Section, Kicker, Headline, Lede, StateDot } from "../ui/Primitives";
import { useReveal } from "@/lib/useReveal";
import { cn } from "@/lib/cn";

export function ProductDemo() {
  const [i, setI] = useState(0);
  const [held, setHeld] = useState(false);
  const { ref, visible } = useReveal<HTMLDivElement>();

  useEffect(() => {
    if (held || !visible) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const id = setInterval(() => setI((n) => (n + 1) % copy.steps.length), 2800);
    return () => clearInterval(id);
  }, [held, visible]);

  const step = copy.steps[i];
  const fill = step.id === "break" ? 0 : Math.min(1, step.minutes / 45);

  return (
    <Section id="how-it-works">
      <div ref={ref} className="reveal" data-visible={visible}>
        <Kicker>{copy.kicker}</Kicker>
        <Headline>{copy.headline}</Headline>
        <Lede>{copy.sub}</Lede>

        {/* Step rail. Real buttons, so this is keyboard operable and not a
            carousel you can only watch. */}
        <div className="mt-12 flex flex-wrap gap-2" role="tablist" aria-label="Demo steps">
          {copy.steps.map((s, n) => {
            const on = n === i;
            return (
              <button
                key={s.id}
                role="tab"
                aria-selected={on}
                onClick={() => {
                  setI(n);
                  setHeld((h) => (n === i ? !h : true));
                }}
                className={cn(
                  "flex items-center gap-2 rounded-lg border px-3.5 py-2 font-mono text-[12px] transition-all",
                  on
                    ? "border-suspend/50 bg-suspend/[0.08] text-fg"
                    : "border-line text-fg-faint hover:border-line-hi hover:text-fg-muted",
                )}
              >
                <StateDot state={s.id === "due" ? "suspend" : s.id === "break" ? "suspend" : "running"} />
                {s.label}
              </button>
            );
          })}
        </div>

        <div className="mt-8 grid gap-8 lg:grid-cols-[minmax(0,1fr)_minmax(0,0.85fr)] lg:gap-14">
          {/* The character. Given room, because this is the only place on the
              page where the product has a face. */}
          <div className="relative overflow-hidden rounded-2xl border border-line bg-bg-raised">
            <div className="pointer-events-none absolute inset-0 grid-bg opacity-30" aria-hidden />

            {/* menu bar strip, so the icon state is visible alongside the pose */}
            <div className="relative flex items-center justify-end gap-3 border-b border-line bg-surface/70 px-4 py-2 backdrop-blur">
              <span className="font-mono text-[10px] text-fg-faint">Wed 14:52</span>
              <MenuBarIcon fill={fill} size={15} />
            </div>

            <div className="relative flex items-end justify-center px-6 pb-2 pt-6">
              <PixelDev state={step.pose as PixelDevState} className="h-56 w-full max-w-[340px] sm:h-64" />
            </div>

            <div className="relative flex items-center justify-between border-t border-line px-5 py-3 font-mono text-[11px]">
              <span className="flex items-center gap-2 text-fg-faint">
                <StateDot state={step.id === "break" ? "suspend" : "running"} />
                {step.sig}
              </span>
              <span className="tabular-nums text-fg-muted">
                {step.id === "break" ? "05:00 break" : `${String(step.minutes).padStart(2, "0")}:00 continuous`}
              </span>
            </div>
          </div>

          {/* What that step means */}
          <div className="flex flex-col justify-center">
            <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-suspend-ink">
              {step.sig}
            </p>
            <h3 className="mt-3 text-balance font-mono text-2xl font-bold leading-tight tracking-tight sm:text-3xl">
              {step.title}
            </h3>
            <p className="mt-4 text-pretty leading-relaxed text-fg-muted">{step.body}</p>

            <div className="mt-8 flex items-center gap-3">
              <div className="h-1 flex-1 overflow-hidden rounded-full bg-surface-hi">
                <div
                  className="h-full rounded-full bg-suspend transition-all duration-500"
                  style={{ width: `${((i + 1) / copy.steps.length) * 100}%` }}
                />
              </div>
              <span className="font-mono text-[10px] text-fg-faint">
                {i + 1}/{copy.steps.length}
              </span>
            </div>
            <p className="mt-3 font-mono text-[10px] text-fg-faint" aria-live="polite">
              {held ? copy.pausedNote : copy.autoplayNote}
            </p>
          </div>
        </div>
      </div>
    </Section>
  );
}
