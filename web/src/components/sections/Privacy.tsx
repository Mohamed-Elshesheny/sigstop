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

  // One polite live region for the whole proof list. Four separate regions
  // would fight each other on a screen reader for no extra information.
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
      // Clipboard access can be denied outright. Say so rather than showing a
      // "Copied" state for a thing that did not get copied.
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

        {/* ── (a) The contrast. Two columns, deliberately unequal in weight. ──
            The left one is an inventory. The right one is the reason anybody
            installs this, so it gets the heavier surface and the larger type. */}
        <div className="mt-10 grid gap-4 md:grid-cols-2 md:gap-5">
          <div className="rounded-xl border border-line bg-surface/30 p-5 sm:p-6">
            <h3 className="flex items-center gap-2.5 font-mono text-sm font-semibold tracking-tight text-fg">
              <StateDot state="running" />
              {copy.sees.title}
            </h3>

            <dl className="mt-6">
              {copy.sees.items.map((item) => (
                <div key={item.k} className="border-t border-line py-4 first:border-t-0 first:pt-0 last:pb-0">
                  <dt className="font-mono text-[13px] leading-snug text-fg">{item.k}</dt>
                  <dd className="mt-1.5 text-sm leading-relaxed text-fg-muted">{item.v}</dd>
                </div>
              ))}
            </dl>

            <p className="mt-6 border-t border-line pt-5 font-mono text-[11px] leading-relaxed text-fg-faint">
              {copy.sees.note}
            </p>
          </div>

          <div className="relative overflow-hidden rounded-xl border border-line-hi bg-surface p-5 sm:p-6">
            <span className="absolute inset-x-0 top-0 h-px bg-suspend/60" aria-hidden />

            <h3 className="flex items-center gap-2.5 font-mono text-sm font-semibold tracking-tight text-fg">
              <span className="text-suspend" aria-hidden>∅</span>
              {copy.never.title}
            </h3>

            <ul className="mt-6 space-y-3.5">
              {copy.never.items.map((item) => (
                <li key={item} className="flex items-baseline gap-3">
                  <span className="font-mono text-xs text-fg-faint" aria-hidden>--</span>
                  <span className="font-mono text-base leading-snug tracking-tight text-fg sm:text-lg">
                    {item}
                  </span>
                </li>
              ))}
            </ul>

            <p className="mt-7 text-pretty border-t border-line-hi pt-5 text-sm leading-relaxed text-fg-muted">
              {copy.never.note}
            </p>
          </div>
        </div>

        {/* ── (b) The commands. Real, current, and actually copy-pasteable. ── */}
        <div className="mt-20">
          <h3 className="font-mono text-2xl font-bold tracking-tight sm:text-3xl">{copy.proof.title}</h3>
          <p className="mt-3 max-w-2xl text-pretty leading-relaxed text-fg-muted">{copy.proof.sub}</p>

          <TerminalFrame title={copy.proof.terminalTitle} className="mt-7">
            <ul>
              {copy.proof.checks.map((check) => {
                const isCopied = copied === check.cmd;
                return (
                  <li key={check.cmd} className="border-t border-line py-4 first:border-t-0 first:pt-0 last:pb-0">
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

                    <p className="mt-2.5 pl-6 text-[13px] leading-relaxed text-fg-muted">
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

        {/* ── (c) The claim everything above rests on. ────────────────────── */}
      </div>
    </Section>
  );
}
