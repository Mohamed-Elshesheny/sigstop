"use client";

import { openSource as copy, site } from "@/content/copy";
import { Section, Kicker, Headline, Lede, Button } from "../ui/Primitives";
import { useReveal } from "@/lib/useReveal";

/**
 * The "is this a real project" section.
 *
 * No star counts, no contributor avatars, no download totals. This audience
 * checks, and an inflated number is the one mistake they never forgive. The
 * stats strip below is static fact, language, licence, floor, size, deps ,
 * which is duller and holds up.
 */
export function OpenSource() {
  const { ref, visible } = useReveal<HTMLDivElement>();

  return (
    <Section id="open-source">
      <div ref={ref} className="reveal" data-visible={visible}>
        <Kicker>{copy.kicker}</Kicker>
        <Headline>{copy.headline}</Headline>
        <Lede>{copy.sub}</Lede>

        {/* ── Facts, not social proof. ──────────────────────────────────── */}
        <dl className="mt-12 grid grid-cols-2 gap-px overflow-hidden rounded-xl border border-line bg-line sm:grid-cols-3 lg:grid-cols-5">
          {copy.facts.map((fact) => (
            <div key={fact.k} className="bg-bg-raised px-5 py-5">
              <dt className="font-mono text-[10px] uppercase tracking-[0.18em] text-fg-faint">{fact.k}</dt>
              <dd className="mt-2 font-mono text-lg font-bold tracking-tight text-fg">{fact.v}</dd>
            </div>
          ))}
        </dl>
        <p className="mt-3 font-mono text-[11px] leading-relaxed text-fg-faint">{copy.factsNote}</p>

        {/* ── Three real places to start. Each links at a real repo path. ── */}
        <ul className="mt-12 grid gap-5 md:grid-cols-3">
          {copy.cards.map((card) => (
            <li key={card.title} className="flex">
              <a
                href={card.href}
                className="group flex w-full flex-col rounded-xl border border-line bg-surface/30 p-6 transition-colors duration-200 hover:border-line-hi hover:bg-surface"
              >
                <h3 className="font-mono text-base font-bold tracking-tight text-fg">{card.title}</h3>
                <p className="mt-3 flex-1 text-pretty text-sm leading-relaxed text-fg-muted">{card.body}</p>
                <span className="mt-6 inline-flex items-center gap-2 font-mono text-[13px] text-suspend">
                  {card.cta}
                  <span className="transition-transform duration-200 group-hover:translate-x-0.5" aria-hidden>→</span>
                </span>
              </a>
            </li>
          ))}
        </ul>

        <div className="mt-12 flex flex-wrap items-center gap-3">
          <Button href={site.repo}>
            {copy.ctaPrimary}
            <span className="transition-transform duration-200 group-hover:translate-x-0.5" aria-hidden>→</span>
          </Button>
          <Button href={`${site.repo}/blob/main/CONTRIBUTING.md`} variant="ghost">
            {copy.ctaSecondary}
          </Button>
        </div>
      </div>
    </Section>
  );
}
