"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { privacy as copy } from "@/content/copy";
import { Section, Kicker, Headline, Lede, StateDot, TerminalFrame } from "../ui/Primitives";
import { useReveal } from "@/lib/useReveal";
import { cn } from "@/lib/cn";

/**
 * The section an adversarial reader lands on before deciding whether to run a
 * binary that watches their workflow all day.
 *
 * Deliberately no padlocks, shields or "bank-grade" anything. Trust imagery is
 * what you reach for when you have nothing checkable to show; this section has
 * four commands instead. Specificity is the only credibility that survives
 * someone who reads source for a living.
 */
export function Privacy() {
  const { ref, visible } = useReveal<HTMLDivElement>();

  const [status, setStatus] = useState("");
  const [copied, setCopied] = useState<string | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); }, []);

  const onCopy = useCallback(async (cmd: string) => {
    if (timer.current) clearTimeout(timer.current);
    try {
      await navigator.clipboard.writeText(cmd);
      setCopied(cmd);
      setStatus(`${copy.proof.copiedLabel}: ${cmd}`);
    } catch {
      setCopied(null);
      setStatus(copy.proof.copyFailLabel);
    }
    timer.current = setTimeout(() => { setCopied(null); setStatus(""); }, 2600);
  }, []);

  return (
    <Section id="privacy">
      <div ref={ref} className="reveal" data-visible={visible}>
        <Kicker>{copy.kicker}</Kicker>
        <Headline>{copy.headline}</Headline>
        <Lede>{copy.sub}</Lede>

        {/* One compact block. The inventory is short enough to read at a
            glance, which is the actual argument; spreading five signals over
            two tall cards made it look longer than it is. */}
        <div className="mt-8 grid gap-px overflow-hidden rounded-xl border border-line bg-line md:grid-cols-2">
          <div className="bg-bg p-5">
            <h3 className="flex items-center gap-2 font-mono text-[12px] font-semibold uppercase tracking-[0.14em] text-fg-faint">
              <StateDot state="running" />
              {copy.sees.title}
            </h3>
            <dl className="mt-3 space-y-1.5">
              {copy.sees.items.map((item) => (
                <div key={item.k} className="flex items-baseline gap-2 text-[13px] leading-snug">
                  <dt className="font-mono text-fg">{item.k}</dt>
                  <dd className="text-fg-faint">{item.v}</dd>
                </div>
              ))}
            </dl>
          </div>

          <div className="bg-bg p-5">
            <h3 className="flex items-center gap-2 font-mono text-[12px] font-semibold uppercase tracking-[0.14em] text-fg-faint">
              <span className="text-suspend-ink" aria-hidden>{"\u2205"}</span>
              {copy.never.title}
            </h3>
            <ul className="mt-3 flex flex-wrap gap-x-2 gap-y-1.5">
              {copy.never.items.map((item) => (
                <li
                  key={item}
                  className="rounded border border-line-hi px-2 py-0.5 font-mono text-[12px] text-fg"
                >
                  {item}
                </li>
              ))}
            </ul>
            <p className="mt-3 text-[12px] leading-snug text-fg-muted">{copy.never.note}</p>
          </div>
        </div>

        {/* ── (b) The commands. Real, current, and actually copy-pasteable. ── */}
        <div className="mt-8">
          <h3 className="font-mono text-base font-bold tracking-tight">
            {copy.proof.title}{" "}
            <span className="font-normal text-fg-faint">{copy.proof.sub}</span>
          </h3>

          <TerminalFrame title={copy.proof.terminalTitle} className="mt-4">
            <ul>
              {copy.proof.checks.map((check) => {
                const isCopied = copied === check.cmd;
                return (
                  <li key={check.cmd} className="border-t border-line py-2.5 first:border-t-0 first:pt-0 last:pb-0">
                    <div className="flex items-start gap-3">
                      <span className="select-none pt-px text-running" aria-hidden>$</span>
                      <code className="min-w-0 flex-1 break-all text-[13px] leading-relaxed text-fg">
                        {check.cmd}
                      </code>
                      <button
                        type="button"
                        onClick={() => onCopy(check.cmd)}
                        aria-label={`${isCopied ? copy.proof.copiedLabel : copy.proof.copyLabel}: ${check.cmd}`}
                        className={cn(
                          "shrink-0 rounded-md border px-2.5 py-1 font-mono text-[11px] transition-colors duration-200",
                          isCopied
                            ? "border-suspend/60 text-suspend"
                            : "border-line-hi text-fg-faint hover:border-fg-faint hover:text-fg",
                        )}
                      >
                        <span aria-hidden>{isCopied ? copy.proof.copiedLabel : copy.proof.copyLabel}</span>
                      </button>
                    </div>

                    <p className="mt-1.5 pl-6 text-[12px] leading-snug text-fg-muted">
                      <span className="font-mono text-fg-faint" aria-hidden>{copy.proof.provesLabel}, </span>
                      {check.desc}
                    </p>
                  </li>
                );
              })}
            </ul>
          </TerminalFrame>

          <p role="status" aria-live="polite" className="sr-only">{status}</p>
        </div>

        {/* ── (c) The one connection. ───────────────────────────────────────
            Placed AFTER the commands on purpose. A reader who has just been
            handed five things to run is in the right frame of mind for the
            paragraph that admits the app does open a socket; the same paragraph
            above the commands reads like a disclaimer being got out of the way.
            It is a single full-width block rather than a card in the grid
            because it is the one thing on this page that concedes something,
            and burying a concession in a two-up layout is how you make it look
            like you were hoping nobody would read it. */}
        <div className="mt-8 overflow-hidden rounded-xl border border-line bg-bg p-5">
          <h3 className="flex items-center gap-2 font-mono text-[12px] font-semibold uppercase tracking-[0.14em] text-fg-faint">
            <StateDot state="suspend" />
            {copy.network.title}
          </h3>
          <p className="mt-2 text-[13px] leading-snug text-fg-muted">{copy.network.sub}</p>
          <dl className="mt-3 space-y-1.5">
            {copy.network.items.map((item) => (
              <div key={item.k} className="flex items-baseline gap-2 text-[13px] leading-snug">
                <dt className="shrink-0 font-mono text-fg">{item.k}</dt>
                <dd className="text-fg-faint">{item.v}</dd>
              </div>
            ))}
          </dl>
          <p className="mt-3 text-[12px] leading-snug text-fg-muted">{copy.network.note}</p>
        </div>
      </div>
    </Section>
  );
}
