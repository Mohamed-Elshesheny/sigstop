"use client";

import { comparison as copy } from "@/content/copy";
import { Section, Kicker, Headline, Lede } from "../ui/Primitives";
import { useReveal } from "@/lib/useReveal";
import { cn } from "@/lib/cn";

type Verdict = "yes" | "no" | "some" | "n/a";

/** A mark rather than an emoji: emoji render differently on every machine and
 *  carry a tone this table is deliberately not using. */
function Mark({ v, strong }: { v: Verdict; strong?: boolean }) {
  const common = "mx-auto block h-4 w-4";
  if (v === "yes")
    return (
      <svg className={common} viewBox="0 0 16 16" fill="none" aria-hidden>
        <path d="M3 8.5 6.2 11.7 13 5" stroke={strong ? "var(--color-running)" : "var(--color-fg-muted)"} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    );
  if (v === "no")
    return (
      <svg className={common} viewBox="0 0 16 16" fill="none" aria-hidden>
        <path d="M4 4 12 12M12 4 4 12" stroke="var(--color-fg-faint)" strokeWidth="2" strokeLinecap="round" />
      </svg>
    );
  if (v === "some")
    return (
      <svg className={common} viewBox="0 0 16 16" fill="none" aria-hidden>
        <path d="M4 8h8" stroke="var(--color-suspend-ink)" strokeWidth="2" strokeLinecap="round" />
      </svg>
    );
  return <span className="block text-center font-mono text-[11px] text-fg-faint">{"·"}</span>;
}

export function Comparison() {
  const { ref, visible } = useReveal<HTMLDivElement>();
  const keys = ["sigstop", "pomodoro", "wellness", "nothing"] as const;

  return (
    <Section>
      <div ref={ref} className="reveal" data-visible={visible}>
        <Kicker>{copy.kicker}</Kicker>
        <Headline>{copy.headline}</Headline>
        <Lede>{copy.sub}</Lede>

        {/* Desktop: a real table, so screen readers get real headers. */}
        <div className="mt-12 hidden overflow-hidden rounded-xl border border-line md:block">
          <table className="w-full border-collapse">
            <caption className="sr-only">
              Feature comparison between sigstop, Pomodoro timers, wellness apps and using nothing
            </caption>
            <thead>
              <tr className="border-b border-line bg-surface/50">
                <th scope="col" className="w-[38%] px-5 py-4 text-left font-mono text-[11px] uppercase tracking-[0.15em] text-fg-faint">
                  {" "}
                </th>
                {copy.columns.map((c) => (
                  <th
                    key={c.key}
                    scope="col"
                    className={cn(
                      "px-3 py-4 text-center align-bottom",
                      c.highlight && "bg-suspend/[0.06]",
                    )}
                  >
                    <span className={cn("block font-mono text-[13px] font-bold", c.highlight ? "text-suspend-ink" : "text-fg")}>
                      {c.label}
                    </span>
                    <span className="mt-1 block font-mono text-[10px] leading-tight text-fg-faint">{c.note}</span>
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {copy.rows.map((r, i) => (
                <tr key={r.trait} className={cn("border-b border-line last:border-0", i % 2 === 1 && "bg-surface/25")}>
                  <th scope="row" className="px-5 py-3 text-left text-sm font-normal leading-snug text-fg-muted">
                    {r.trait}
                  </th>
                  {keys.map((k) => (
                    <td
                      key={k}
                      className={cn("px-3 py-3", k === "sigstop" && "bg-suspend/[0.06]")}
                    >
                      <Mark v={r[k] as Verdict} strong={k === "sigstop"} />
                      <span className="sr-only">{copy.legend[r[k] as Verdict]}</span>
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {/* Mobile: the table restructured per column, not scrolled sideways. */}
        <div className="mt-10 space-y-3 md:hidden">
          {copy.columns.map((c) => (
            <div
              key={c.key}
              className={cn(
                "rounded-xl border p-4",
                c.highlight ? "border-suspend/40 bg-suspend/[0.05]" : "border-line bg-surface/30",
              )}
            >
              <p className={cn("font-mono text-sm font-bold", c.highlight ? "text-suspend-ink" : "text-fg")}>{c.label}</p>
              <p className="mt-0.5 font-mono text-[10px] text-fg-faint">{c.note}</p>
              <ul className="mt-3 space-y-1.5">
                {copy.rows.map((r) => (
                  <li key={r.trait} className="flex items-start gap-2.5 text-[13px] leading-snug">
                    <span className="mt-0.5 shrink-0">
                      <Mark v={r[c.key as keyof typeof r] as Verdict} strong={c.highlight} />
                    </span>
                    <span className="text-fg-muted">{r.trait}</span>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>


        <div className="mt-10 rounded-xl border border-line bg-surface/30 p-6 sm:p-8">
          <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-suspend-ink">
            {copy.evidence.kicker}
          </p>
          <h3 className="mt-3 text-balance font-mono text-xl font-bold leading-tight tracking-tight sm:text-2xl">
            {copy.evidence.headline}
          </h3>
          <p className="mt-4 max-w-3xl text-pretty leading-relaxed text-fg-muted">{copy.evidence.body}</p>

          <ul className="mt-6 space-y-3">
            {copy.evidence.sources.map((src) => (
              <li key={src.doi} className="flex flex-col gap-1 border-l-2 pl-4 sm:flex-row sm:items-baseline sm:gap-4"
                  style={{ borderColor: src.agrees ? "var(--color-running)" : "var(--color-alert)" }}>
                <span className="shrink-0 font-mono text-[11px] uppercase tracking-wider"
                      style={{ color: src.agrees ? "var(--color-running)" : "var(--color-alert)" }}>
                  {src.agrees ? "supports" : "disputes"}
                </span>
                <span className="text-[13px] leading-snug text-fg-muted">
                  {src.claim}
                  <br />
                  <a href={`https://doi.org/${src.doi}`} className="font-mono text-[11px] text-fg-faint underline decoration-line-hi underline-offset-2 hover:text-fg">
                    {src.cite} · doi:{src.doi}
                  </a>
                </span>
              </li>
            ))}
          </ul>

          <p className="mt-6 max-w-3xl text-pretty text-[13px] leading-relaxed text-fg-faint">
            {copy.evidence.caveat}
          </p>
        </div>
      </div>
    </Section>
  );
}
