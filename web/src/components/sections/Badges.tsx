"use client";

import { useState } from "react";
import { badges as copy } from "@/content/copy";
import { Section, Kicker, Headline, Lede } from "../ui/Primitives";
import { BadgeMark, type Motif } from "../ui/BadgeMark";
import { useReveal } from "@/lib/useReveal";
import { cn } from "@/lib/cn";

/**
 * The ten badges, drawn rather than listed.
 *
 * The marks are the argument here, so they get the room: one object per row,
 * at the size the app draws them, with the price and the meaning beside it.
 *
 * The one interactive thing on the page flips every mark between earned and not
 * yet, and it exists because that is the claim this section is making. A locked
 * badge elsewhere is a padlock, a grey blob, a percentage bar: a small ongoing
 * reproach. Here it is the same object with the amber out of it, and the only
 * way to show that it costs nothing to be missing is to let someone put it back
 * and see that nothing else moved. The control changes the copy as well as the
 * ink, exactly as Settings does, because a locked badge in the app says what it
 * takes and an earned one says what it meant.
 *
 * Two columns, so `[1]+ Stopped` opens the wall and `[100]+ Stopped` closes it.
 * They are the same brackets printed twice and the layout should not break the
 * rhyme.
 */
export function Badges() {
  const { ref, visible } = useReveal<HTMLDivElement>(0.08);
  const [earned, setEarned] = useState(true);

  return (
    <Section id="badges">
      <div ref={ref} className="reveal" data-visible={visible}>
        <Kicker>{copy.kicker}</Kicker>
        <Headline>{copy.headline}</Headline>
        <Lede>{copy.sub}</Lede>

        <div className="mt-10 flex flex-wrap items-center gap-x-4 gap-y-3">
          <span id="badge-view-label" className="font-mono text-[11px] uppercase tracking-[0.18em] text-fg-faint">
            {copy.view.label}
          </span>
          <div
            role="group"
            aria-labelledby="badge-view-label"
            className="inline-flex rounded-lg border border-line bg-surface p-1"
          >
            <StateButton active={earned} onClick={() => setEarned(true)}>
              {copy.view.earned}
            </StateButton>
            <StateButton active={!earned} onClick={() => setEarned(false)}>
              {copy.view.locked}
            </StateButton>
          </div>
        </div>

        <p
          className="mt-4 max-w-2xl text-pretty text-sm leading-relaxed text-fg-muted"
          aria-live="polite"
        >
          {earned ? copy.view.note.earned : copy.view.note.locked}
        </p>

        <ul className="mt-10 grid gap-px overflow-hidden rounded-xl border border-line bg-line sm:grid-cols-2">
          {copy.items.map((item, i) => (
            <li
              key={item.name}
              className="reveal flex gap-5 bg-bg-raised p-5 sm:p-6"
              data-visible={visible}
              style={{ transitionDelay: `${i * 45}ms` }}
            >
              <BadgeMark
                motif={item.motif as Motif}
                earned={earned}
                className="mt-0.5 h-14 w-14 sm:h-[68px] sm:w-[68px]"
              />

              <div className="min-w-0 flex-1">
                <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
                  <h3 className="font-mono text-sm font-bold tracking-tight text-fg">{item.name}</h3>
                  <span
                    className={cn(
                      "font-mono text-[10px] uppercase tracking-[0.16em]",
                      earned ? "text-suspend-ink" : "text-fg-faint",
                    )}
                  >
                    {earned ? copy.chip.earned : copy.chip.locked}
                  </span>
                </div>

                <p className="mt-2.5 text-pretty text-[13.5px] leading-relaxed text-fg-muted">
                  {item.earns}
                </p>
                <p className="mt-1.5 text-pretty text-[13.5px] leading-relaxed text-fg-faint">
                  {item.earned}
                </p>
              </div>
            </li>
          ))}
        </ul>

        <p className="mt-3 max-w-2xl text-pretty font-mono text-[11px] leading-relaxed text-fg-faint">
          {copy.marksNote}
        </p>

        {/* The three properties. This is the part of the section that is an
            argument rather than a display, so it sits under the wall and not
            over it: you should have looked at the shelf first. */}
        <dl className="mt-12 grid gap-px overflow-hidden rounded-xl border border-line bg-line md:grid-cols-3">
          {copy.rules.map((rule) => (
            <div key={rule.k} className="bg-bg-raised px-5 py-5">
              <dt className="font-mono text-[13px] font-bold tracking-tight text-suspend-ink">{rule.k}</dt>
              <dd className="mt-2 text-pretty text-sm leading-relaxed text-fg-muted">{rule.v}</dd>
            </div>
          ))}
        </dl>

        <p className="mt-3 font-mono text-[11px] leading-relaxed text-fg-faint">{copy.note}</p>
      </div>
    </Section>
  );
}

function StateButton({
  active,
  onClick,
  children,
}: {
  active: boolean;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      aria-pressed={active}
      onClick={onClick}
      className={cn(
        "rounded-md px-3.5 py-1.5 font-mono text-xs transition-colors duration-150",
        active
          ? "bg-bg-raised font-semibold text-fg shadow-sm"
          : "text-fg-muted hover:text-fg",
      )}
    >
      {children}
    </button>
  );
}
