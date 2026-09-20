"use client";

import { badges as copy } from "@/content/copy";
import { Section, Kicker, Headline, Lede } from "../ui/Primitives";
import { useReveal } from "@/lib/useReveal";

/**
 * The ten badges.
 *
 * A list of names and prices, and then the three properties that are the whole
 * reason this section is allowed to exist on a page that spends the rest of its
 * length arguing against streaks. The marks are drawn in the app and are not
 * redrawn here: ten drawings kept in two places drift, and the one that drifts
 * is always the one nobody is looking at.
 */
export function Badges() {
  const { ref, visible } = useReveal<HTMLDivElement>();

  return (
    <Section id="badges">
      <div ref={ref} className="reveal" data-visible={visible}>
        <Kicker>{copy.kicker}</Kicker>
        <Headline>{copy.headline}</Headline>
        <Lede>{copy.sub}</Lede>

        <div className="mt-12 overflow-hidden rounded-xl border border-line">
          <div className="flex gap-4 border-b border-line bg-surface/40 px-5 py-3 font-mono text-[10px] uppercase tracking-[0.18em] text-fg-faint">
            <span className="w-44 shrink-0">{copy.columnLabels.name}</span>
            <span>{copy.columnLabels.earns}</span>
          </div>
          <ul>
            {copy.items.map((item) => (
              <li
                key={item.name}
                className="flex flex-col gap-1 border-b border-line px-5 py-4 last:border-b-0 sm:flex-row sm:gap-4"
              >
                <span className="w-44 shrink-0 font-mono text-sm font-bold tracking-tight text-fg">
                  {item.name}
                </span>
                <span className="text-pretty text-sm leading-relaxed text-fg-muted">{item.earns}</span>
              </li>
            ))}
          </ul>
        </div>

        <dl className="mt-10 grid gap-px overflow-hidden rounded-xl border border-line bg-line md:grid-cols-3">
          {copy.rules.map((rule) => (
            <div key={rule.k} className="bg-bg-raised px-5 py-5">
              <dt className="font-mono text-[13px] font-bold tracking-tight text-suspend">{rule.k}</dt>
              <dd className="mt-2 text-pretty text-sm leading-relaxed text-fg-muted">{rule.v}</dd>
            </div>
          ))}
        </dl>

        <p className="mt-3 font-mono text-[11px] leading-relaxed text-fg-faint">{copy.note}</p>
      </div>
    </Section>
  );
}
