"use client";

import { useId, useState } from "react";
import { appDemos, escalation, type AppDemo } from "@/content/apps";
import { context as copy } from "@/content/copy";
import { Section, Kicker, Headline, Lede, StateDot } from "../ui/Primitives";
import { AppLogo } from "../ui/AppLogo";
import { useReveal } from "@/lib/useReveal";
import { cn } from "@/lib/cn";

type ToneKey = "friendly" | "sarcastic" | "roast";
const TONES: { key: ToneKey; label: string; sig: string }[] = [
  { key: "friendly", label: "Friendly", sig: "polite" },
  { key: "sarcastic", label: "Sarcastic", sig: "default" },
  { key: "roast", label: "Roast", sig: "you asked" },
];

export function ContextDemo() {
  // Not appDemos[0]: the hero panel is already Cursor / AI_CODING / 0.91, and a
  // demo whose job is to change per context should not open on the card the
  // reader just looked at. Xcode argues harder, at a lower confidence.
  const [active, setActive] = useState<AppDemo>(
    appDemos.find((a) => a.key === "xcode") ?? appDemos[0],
  );
  const [tone, setTone] = useState<ToneKey>("sarcastic");
  const { ref, visible } = useReveal<HTMLDivElement>();
  const panelId = useId();

  const message =
    active.messages.find((m) => m.tone === tone) ?? active.messages[0];
  const confident = active.confidence >= 0.6;

  return (
    <Section id="product">
      <div ref={ref} className={cn("reveal")} data-visible={visible}>
        <Kicker>{copy.kicker}</Kicker>
        <Headline>{copy.headline}</Headline>
        <Lede>{copy.sub}</Lede>

        <div className="mt-10 grid gap-6 lg:grid-cols-[minmax(0,320px)_minmax(0,1fr)] lg:gap-10">
          {/* ── App picker. Real buttons in a real tablist. ───────────────── */}
          <div>
            <p className="mb-3 font-mono text-[11px] uppercase tracking-[0.18em] text-fg-faint">
              {copy.hint}
            </p>
            <div
              role="tablist"
              aria-label="Applications"
              aria-orientation="vertical"
              className="grid grid-cols-2 gap-2 lg:grid-cols-1"
            >
              {appDemos.map((app) => {
                const on = app.key === active.key;
                return (
                  <button
                    key={app.key}
                    role="tab"
                    id={`${panelId}-tab-${app.key}`}
                    aria-selected={on}
                    aria-controls={panelId}
                    onClick={() => setActive(app)}
                    className={cn(
                      "group flex items-center gap-3 rounded-lg border px-3.5 py-3 text-left transition-all duration-200",
                      on
                        ? "border-suspend/50 bg-suspend/[0.07]"
                        : "border-line bg-surface/40 hover:border-line-hi hover:bg-surface",
                    )}
                  >
                    <span
                      className="grid h-8 w-8 shrink-0 place-items-center rounded-md border"
                      style={{ borderColor: on ? app.accent : "var(--color-line-hi)" }}
                      aria-hidden
                    >
                      <AppLogo
                        app={app.key}
                        className={cn("h-[18px] w-[18px]", on ? "text-fg" : "text-fg-faint")}
                      />
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className={cn("block truncate font-mono text-[13px]", on ? "text-fg" : "text-fg-muted")}>
                        {app.name}
                      </span>
                      <span className="block truncate font-mono text-[10px] text-fg-faint">
                        {app.minutes}m · {app.confidence.toFixed(2)}
                      </span>
                    </span>
                  </button>
                );
              })}
            </div>
          </div>

          {/* ── The notification this context would actually produce. ──────── */}
          <div
            role="tabpanel"
            id={panelId}
            aria-labelledby={`${panelId}-tab-${active.key}`}
            tabIndex={0}
            className="rounded-xl border border-line bg-bg-raised"
          >
            {/* inference header */}
            <div className="flex flex-wrap items-center justify-between gap-3 border-b border-line px-5 py-3.5">
              <span className="flex items-center gap-2 font-mono text-[11px] text-fg-faint">
                <StateDot state={confident ? "running" : "suspend"} />
                inference
              </span>
              <span className="flex items-center gap-4 font-mono text-[11px]">
                <span className={confident ? "text-fg" : "text-suspend"}>
                  {confident ? active.activity : "UNKNOWN"}
                </span>
                <span className="text-fg-faint">
                  conf{" "}
                  <span style={{ color: confident ? "var(--color-running)" : "var(--color-suspend)" }}>
                    {active.confidence.toFixed(2)}
                  </span>
                </span>
              </span>
            </div>

            <div className="p-5 sm:p-7">
              {/* the message */}
              <p className="text-balance text-xl leading-snug sm:text-2xl">{message.text}</p>

              {/* tone switch */}
              <div className="mt-6 flex flex-wrap items-center gap-2">
                {TONES.map((t) => {
                  const on = t.key === tone;
                  return (
                    <button
                      key={t.key}
                      onClick={() => setTone(t.key)}
                      aria-pressed={on}
                      className={cn(
                        "rounded-md border px-3 py-1.5 font-mono text-[11px] transition-colors",
                        on
                          ? "border-suspend/60 bg-suspend/10 text-suspend"
                          : "border-line text-fg-faint hover:border-line-hi hover:text-fg-muted",
                      )}
                    >
                      {t.label}
                    </button>
                  );
                })}
                <span className="ml-1 font-mono text-[10px] text-fg-faint">
                  {copy.toneNote}
                </span>
              </div>

              {/* the evidence trail, the product's core promise made visible */}
              <div className="mt-7 border-t border-line pt-5">
                <p className="mb-2.5 font-mono text-[10px] uppercase tracking-[0.18em] text-fg-faint">
                  {copy.evidenceLabel}
                </p>
                <ul className="space-y-1.5">
                  {active.evidence.map((e) => (
                    <li key={e} className="flex gap-2.5 font-mono text-[11px] leading-relaxed text-fg-muted">
                      <span className="text-fg-faint" aria-hidden>→</span>
                      <span>{e}</span>
                    </li>
                  ))}
                </ul>
              </div>

              {/* the honesty case, this is the section's real argument */}
              {!confident && (
                <p className="mt-5 rounded-lg border border-suspend/25 bg-suspend/[0.06] px-4 py-3 font-mono text-[11px] leading-relaxed text-suspend">
                  {copy.unsure}
                </p>
              )}
            </div>
          </div>
        </div>

        {/* ── Escalation ladder, written by POSIX ───────────────────────────── */}
        <div className="mt-14 border-t border-line pt-12">
          <p className="mb-2 font-mono text-[11px] uppercase tracking-[0.18em] text-fg-faint">
            {copy.escalation.kicker}
          </p>
          <p className="mb-8 max-w-2xl text-pretty leading-relaxed text-fg-muted">
            {copy.escalation.lede}
          </p>

          <ol className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
            {escalation.map((step) => {
              const last = step.level === 4;
              return (
                <li
                  key={step.signal}
                  className={cn(
                    "rounded-xl border p-5",
                    last ? "border-alert/40 bg-alert/[0.05]" : "border-line bg-surface/40",
                  )}
                >
                  <div className="flex items-baseline justify-between gap-2">
                    <span
                      className="font-mono text-sm font-bold"
                      style={{ color: last ? "var(--color-alert)" : "var(--color-suspend)" }}
                    >
                      {step.signal}
                    </span>
                    <span className="font-mono text-[10px] text-fg-faint">L{step.level}</span>
                  </div>
                  <p className="mt-2 font-mono text-[10px] leading-relaxed text-fg-faint">
                    {step.note}
                  </p>
                  <p className="mt-3 border-t border-line pt-3 text-sm leading-relaxed text-fg-muted">
                    {step.text}
                  </p>
                </li>
              );
            })}
          </ol>

          <p className="mt-6 font-mono text-[11px] leading-relaxed text-fg-faint">
            {copy.escalation.note}
          </p>
        </div>
      </div>
    </Section>
  );
}
