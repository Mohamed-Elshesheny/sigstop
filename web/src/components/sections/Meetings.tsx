"use client";

import { meetings as copy } from "@/content/copy";
import { Section, Kicker, Headline, Lede } from "../ui/Primitives";
import { useReveal } from "@/lib/useReveal";
import { cn } from "@/lib/cn";

/**
 * Meetings, and the one thing the app cannot see.
 *
 * The section is built around a descent in certainty, and the markup carries it
 * rather than leaving it to the adjectives: a solid amber rail for the two rows
 * that are device bits, dashed for the hold that is arithmetic on a device bit,
 * dotted for the row that is openly a guess. Dashed and dotted already mean
 * "this may not hold" elsewhere on the page (NotPomodoro's gate edges), so the
 * vocabulary is reused rather than reinvented.
 *
 * The limit block is deliberately full width, not a card sitting in a grid of
 * capabilities. A concession filed alongside features is a concession you were
 * hoping would be skimmed, and this audience grades exactly that.
 *
 * No motion of its own beyond the shared reveal, which is already reduced-motion
 * aware. A section about not interrupting people should not be the busiest thing
 * on the page.
 *
 * Each block reveals on its own rather than the section revealing as one. At
 * 375px this section is 5782px tall, so a single wrapper would animate five
 * screens of content on the strength of its first inch being visible, and the
 * whole thing would be sitting still by the time you reached any of it. Per
 * block, each part arrives as you do. It still reveals once and never re-hides,
 * and reduced motion still shows everything immediately, because that behaviour
 * lives in `useReveal` and in globals.css and is not reimplemented here.
 */

/** One revealed block, sized so that it is revealed near the point it is read. */
function Block({ className, children }: { className?: string; children: React.ReactNode }) {
  const { ref, visible } = useReveal<HTMLDivElement>();
  return (
    <div ref={ref} className={cn("reveal", className)} data-visible={visible}>
      {children}
    </div>
  );
}

type Verdict = keyof typeof copy.ladder.verdicts;

/** Certainty, drawn. Solid = a fact, dashed = arithmetic on a fact, dotted = a guess. */
const RAIL: Record<Verdict, string> = {
  block: "border-solid border-suspend",
  hold: "border-dashed border-suspend",
  defer: "border-dotted border-line-hi",
};

function VerdictChip({ verdict }: { verdict: Verdict }) {
  return (
    <span
      className={cn(
        "shrink-0 rounded px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.16em]",
        verdict === "block"
          ? "bg-suspend font-semibold text-accent-fg"
          : verdict === "hold"
            ? "border border-suspend/60 text-suspend-ink"
            : "border border-line-hi text-fg-faint",
      )}
    >
      {copy.ladder.verdicts[verdict]}
    </span>
  );
}

/** One phase of the muted call. `tone` only ever picks a colour, never content. */
function Phase({ phase, index }: { phase: (typeof copy.mute.phases)[number]; index: number }) {
  const held = phase.tone === "hold";
  const quiet = phase.tone === "mute";
  return (
    <li
      className={cn(
        "relative border-t-2 pt-4 sm:pt-5",
        quiet
          ? "border-dashed border-line-hi"
          : held
            ? "border-dashed border-suspend/50"
            : "border-suspend",
      )}
    >
      <span
        aria-hidden
        className={cn(
          "absolute -top-[5px] left-0 h-2 w-2 rounded-full",
          quiet ? "bg-line-hi" : "bg-suspend",
        )}
      />
      <p className="font-mono text-xs text-fg-faint">
        <span className="sr-only">{`Step ${index + 1}, `}</span>
        {phase.t}
      </p>
      <h4 className="mt-1 font-mono text-sm font-bold leading-snug tracking-tight text-fg">
        {phase.label}
      </h4>
      <p className="mt-2 text-pretty text-[13px] leading-relaxed text-fg-muted">{phase.body}</p>
    </li>
  );
}

export function Meetings() {
  return (
    <Section id="meetings">
      <Block>
        <Kicker>{copy.kicker}</Kicker>
        <Headline>{copy.headline}</Headline>
        <Lede>{copy.sub}</Lede>
      </Block>

      {/* (a) The four states, in descending order of what may be claimed. */}
      <Block className="mt-14">
        <h3 className="font-mono text-base font-bold tracking-tight">{copy.ladder.title}</h3>
        <ol className="mt-5 space-y-px overflow-hidden rounded-xl border border-line bg-line">
          {copy.ladder.items.map((item) => (
            <li key={item.state} className="bg-bg p-5">
              <div className={cn("border-l-2 pl-4", RAIL[item.verdict as Verdict])}>
                <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
                  <h4 className="font-mono text-sm font-bold tracking-tight text-fg">{item.state}</h4>
                  <VerdictChip verdict={item.verdict as Verdict} />
                </div>
                <p className="mt-1 break-all font-mono text-[11px] leading-snug text-fg-faint">
                  {item.source}
                </p>
                <p className="mt-2.5 max-w-3xl text-pretty text-sm leading-relaxed text-fg-muted">
                  {item.body}
                </p>
              </div>
            </li>
          ))}
        </ol>
        <p className="mt-3 text-pretty text-[13px] leading-relaxed text-fg-muted">{copy.ladder.note}</p>
      </Block>

      {/* (b) The mute case, which is the only one worth drawing. */}
      <Block className="mt-14">
        <h3 className="font-mono text-base font-bold tracking-tight">{copy.mute.title}</h3>
        <p className="mt-3 max-w-3xl text-pretty leading-relaxed text-fg-muted">{copy.mute.sub}</p>

        <ol className="mt-8 grid gap-x-6 gap-y-8 sm:grid-cols-2 lg:grid-cols-4">
          {copy.mute.phases.map((phase, i) => (
            <Phase key={phase.t + phase.label} phase={phase} index={i} />
          ))}
        </ol>

        <p className="mt-8 max-w-3xl text-pretty leading-relaxed text-fg">{copy.mute.close}</p>
      </Block>

      {/* The ceilings, on their own, because the first question anyone asks a
          hold is how long it lasts and the answer is four numbers. */}
      <Block className="mt-10">
        <h3 className="font-mono text-[12px] font-semibold uppercase tracking-[0.14em] text-fg-faint">
          {copy.bounds.title}
        </h3>
        <dl className="mt-4 grid gap-px overflow-hidden rounded-xl border border-line bg-line sm:grid-cols-2 lg:grid-cols-4">
          {copy.bounds.items.map((item) => (
            <div key={item.k} className="bg-bg-raised px-5 py-5">
              <dt className="font-mono text-lg font-bold tracking-tight text-suspend-ink">{item.k}</dt>
              <dd className="mt-2 text-pretty text-[13px] leading-relaxed text-fg-muted">{item.v}</dd>
            </div>
          ))}
        </dl>
        <p className="mt-3 text-pretty text-[13px] leading-relaxed text-fg-muted">{copy.bounds.note}</p>
      </Block>

      {/* (c) The limit. Full width, and not optional reading. */}
      <Block className="mt-14 rounded-xl border border-line bg-surface/50 p-6 sm:p-8">
        <h3 className="font-mono text-[12px] font-semibold uppercase tracking-[0.14em] text-fg-faint">
          {copy.gap.title}
        </h3>
        <p className="mt-3 font-mono text-2xl font-bold tracking-tight text-fg sm:text-3xl">
          {copy.gap.headline}
        </p>
        <p className="mt-4 max-w-3xl text-pretty leading-relaxed text-fg-muted">{copy.gap.body}</p>

        <h4 className="mt-7 font-mono text-[12px] font-semibold uppercase tracking-[0.14em] text-fg-faint">
          {copy.gap.alsoTitle}
        </h4>
        <ul className="mt-3 max-w-3xl space-y-2.5">
          {copy.gap.also.map((item) => (
            <li key={item} className="flex gap-3 text-pretty text-sm leading-relaxed text-fg-muted">
              <span aria-hidden className="select-none pt-0.5 font-mono text-sm text-fg-faint">
                {"∅"}
              </span>
              {item}
            </li>
          ))}
        </ul>

        <div className="mt-7 max-w-3xl border-l-2 border-suspend pl-4">
          <p className="font-mono text-[12px] font-semibold uppercase tracking-[0.14em] text-fg-faint">
            {copy.gap.answerLabel}
          </p>
          <p className="mt-1.5 text-pretty leading-relaxed text-fg">{copy.gap.answer}</p>
        </div>
      </Block>

      {/* (d) The four apps people actually name when they ask. */}
      <Block className="mt-14">
        <h3 className="font-mono text-base font-bold tracking-tight">{copy.apps.title}</h3>
        <dl className="mt-5 overflow-hidden rounded-xl border border-line">
          {copy.apps.items.map((app) => (
            <div
              key={app.name}
              className="flex flex-col gap-1 border-b border-line px-5 py-4 last:border-b-0 sm:flex-row sm:gap-5"
            >
              <dt className="w-44 shrink-0 font-mono text-sm font-bold tracking-tight text-fg">
                {app.name}
              </dt>
              <dd className="text-pretty text-sm leading-relaxed text-fg-muted">{app.how}</dd>
            </div>
          ))}
        </dl>
        <p className="mt-3 max-w-3xl text-pretty text-[13px] leading-relaxed text-fg-muted">
          {copy.apps.note}
        </p>
      </Block>

      {/* (e) What a long call costs the cycle, which is nothing. */}
      <Block className="mt-14">
        <h3 className="font-mono text-base font-bold tracking-tight">{copy.cost.title}</h3>
        <dl className="mt-5 grid gap-px overflow-hidden rounded-xl border border-line bg-line md:grid-cols-3">
          {copy.cost.items.map((item) => (
            <div key={item.k} className="bg-bg-raised px-5 py-5">
              <dt className="font-mono text-[13px] font-bold tracking-tight text-suspend-ink">{item.k}</dt>
              <dd className="mt-2 text-pretty text-sm leading-relaxed text-fg-muted">{item.v}</dd>
            </div>
          ))}
        </dl>
      </Block>
    </Section>
  );
}
