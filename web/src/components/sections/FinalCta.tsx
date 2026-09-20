"use client";

import { finalCta as copy, site } from "@/content/copy";
import { Section, Button } from "../ui/Primitives";
import { useReveal } from "@/lib/useReveal";

/**
 * The last thing on the page is a command, because the first thing on the page
 * was a signal name. The caret is the only moving part, it blinks because a
 * prompt blinks, and it stops under prefers-reduced-motion (globals.css).
 *
 * id="download" is the anchor every "Download for macOS" link on the page
 * resolves to, including the one in the nav.
 */
export function FinalCta() {
  const { ref, visible } = useReveal<HTMLDivElement>();

  return (
    <Section id="download">
      <div ref={ref} className="reveal" data-visible={visible}>
        <div className="rounded-xl border border-line bg-bg-raised px-4 py-14 text-center sm:px-10 sm:py-20">
          <h2 className="flex max-w-full flex-nowrap items-center justify-center gap-[0.4em] whitespace-nowrap font-mono text-[clamp(0.95rem,4.3vw,3rem)] font-bold leading-none tracking-[-0.03em]">
            <span className="text-running" aria-hidden>{copy.prompt}</span>
            <span className="text-fg">{copy.headline}</span>
            <span
              className="caret inline-block h-[0.95em] w-[0.5em] shrink-0 bg-suspend align-middle"
              aria-hidden
            />
          </h2>

          <p className="mx-auto mt-8 max-w-xl text-pretty text-lg leading-relaxed text-fg-muted">
            {copy.sub}
          </p>

          <div className="mt-10 flex flex-wrap items-center justify-center gap-3">
            <Button href={`${site.repo}/releases/latest`}>
              {copy.primary}
              <span className="transition-transform duration-200 group-hover:translate-y-0.5" aria-hidden>↓</span>
            </Button>
            <Button href={site.repo} variant="ghost">
              {copy.secondary}
              <span className="transition-transform duration-200 group-hover:translate-x-0.5" aria-hidden>→</span>
            </Button>
          </div>

          <p className="mt-7 font-mono text-xs leading-relaxed text-fg-faint">{copy.meta}</p>
        </div>
      </div>
    </Section>
  );
}
