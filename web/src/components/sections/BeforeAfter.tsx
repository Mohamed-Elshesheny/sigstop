"use client";

import { beforeAfter as copy } from "@/content/copy";
import { Section, Kicker, Headline, Lede } from "../ui/Primitives";
import { useReveal } from "@/lib/useReveal";
import { cn } from "@/lib/cn";

/**
 * Two days, drawn to one clock.
 *
 * The claim is deliberately small: same span, same work, different shape. So
 * both rails are laid out in TRUE proportion, a five-minute seam is five
 * minutes tall (about six pixels) and is never inflated to look more
 * impressive. If the two columns were not on the same scale, the whole section
 * would be a lie told with CSS.
 *
 * Colour carries the argument:
 *   work / strain, the same green, darkening continuously with minutes since
 *                   the last seam. There is no separate "strain colour",
 *                   because that IS the point: nothing in the loop notices a
 *                   difference between hour one and hour eight. Red is not
 *                   used here, this is fatigue, not an alert.
 *   break        , amber, cut slightly wider than the rail so it reads as a
 *                   notch taken out of the block rather than a stripe on it.
 *   held         , still green, because you were still working, wrapped in a
 *                   dashed amber outline: a break that came due and was
 *                   deliberately not fired. Dashed is the honest notation for
 *                   "this exists and did not happen."
 */

type Tone = "work" | "strain" | "break" | "held";
type Item = { t: string; label: string; tone: string };

type Seg = Item & {
  tone: Tone;
  dur: number;
  topPct: number;
  hPct: number;
  /** Fatigue 0–1 at the top and the bottom edge of this segment. */
  f0: number;
  f1: number;
  /** Minutes since the last seam, at the bottom edge of this segment. */
  unbroken: number;
};

function toMin(t: string) {
  const [h, m] = t.split(":").map(Number);
  return h * 60 + m;
}

/** Minutes since the last seam, mapped to 0–1. 5½ hours unbroken is the ceiling. */
function fatigue(mins: number) {
  return Math.min(1, Math.max(0, mins / 330));
}

/** One green, dimmed by fatigue: 46% → 14% of the running colour. */
function greenAt(f: number) {
  return `color-mix(in srgb, var(--color-running) ${Math.round(46 - 32 * f)}%, var(--color-bg))`;
}

const AMBER = "color-mix(in srgb, var(--color-suspend) 82%, var(--color-bg))";
const AMBER_LINE = "color-mix(in srgb, var(--color-suspend) 72%, transparent)";
const HATCH =
  "repeating-linear-gradient(135deg, transparent 0 4px, color-mix(in srgb, var(--color-suspend) 26%, transparent) 4px 6px)";

function build(items: readonly Item[], end: string) {
  const start = toMin(items[0].t);
  const total = toMin(end) - start;
  let acc = 0;

  const segs: Seg[] = items.map((it, i) => {
    const from = toMin(it.t);
    const to = i === items.length - 1 ? toMin(end) : toMin(items[i + 1].t);
    const dur = to - from;
    const tone = it.tone as Tone;

    let f0 = 0;
    let f1 = 0;
    if (tone === "break") {
      acc = 0; // A seam resets the clock. That is the entire mechanism.
    } else {
      f0 = fatigue(acc);
      acc += dur;
      f1 = fatigue(acc);
    }

    return {
      t: it.t,
      label: it.label,
      tone,
      dur,
      f0,
      f1,
      unbroken: acc,
      topPct: ((from - start) / total) * 100,
      hPct: (dur / total) * 100,
    };
  });

  return { segs, total, start };
}

function hm(mins: number) {
  return `${Math.floor(mins / 60)}h ${String(mins % 60).padStart(2, "0")}m`;
}

function short(mins: number) {
  return mins >= 60 ? hm(mins) : `${mins}m`;
}

/** Fill for a tone at a given fatigue range. Shared by the rail and the legend. */
function fillStyle(tone: Tone, f0 = 0, f1 = 0): React.CSSProperties {
  if (tone === "break") return { background: AMBER };
  return { backgroundImage: `linear-gradient(to bottom, ${greenAt(f0)}, ${greenAt(f1)})` };
}

function Swatch({ tone }: { tone: string }) {
  const t = tone as Tone;
  const style =
    t === "strain" ? fillStyle("work", 0.85, 1) : t === "held" ? fillStyle("work", 0.4, 0.52) : fillStyle(t);

  return (
    <span
      aria-hidden
      className={cn("relative mt-1 block shrink-0 rounded-[2px]", t === "break" ? "h-1.5 w-4" : "h-7 w-2.5")}
      style={style}
    >
      {t === "held" && (
        <span
          className="absolute inset-0 rounded-[2px] border border-dashed"
          style={{ borderColor: AMBER_LINE, backgroundImage: HATCH }}
        />
      )}
    </span>
  );
}

function Stat({ value, label }: { value: string; label: string }) {
  return (
    <div>
      <dt className="sr-only">{label}</dt>
      <dd className="font-mono text-sm font-bold tabular-nums text-fg">
        {value}
        <span className="mt-0.5 block text-[10px] font-normal uppercase tracking-[0.14em] text-fg-faint">
          {label}
        </span>
      </dd>
    </div>
  );
}

function Column({
  title,
  meta,
  end,
  items,
  stats,
  visible,
  className,
}: {
  title: string;
  meta: string;
  end: string;
  items: readonly Item[];
  stats: { value: string; label: string }[];
  visible: boolean;
  className?: string;
}) {
  const { segs, total, start } = build(items, end);

  // Labelling every block is impossible at true scale, consecutive events in
  // the right-hand column are five minutes apart. The rail is labelled at the
  // events that carry the argument: the opening block, every seam, every
  // withheld break, and every hour the left column spends not noticing. The
  // full sequence stays in the DOM for screen readers either way.
  const labelled = (s: Seg, i: number) =>
    i === 0 || s.tone === "break" || s.tone === "held" || s.tone === "strain";

  // Hour rules, so "same scale" is checkable rather than asserted.
  const hours: number[] = [];
  for (let m = start + ((60 - (start % 60)) % 60); m < start + total; m += 60) hours.push(m);

  return (
    <div className={cn("flex min-w-0 flex-col", className)}>
      <div className="border-b border-line pb-4">
        <h3 className="font-mono text-sm font-bold text-fg">{title}</h3>
        <p className="mt-2 max-w-sm text-pretty text-sm leading-relaxed text-fg-muted">{meta}</p>
      </div>

      <dl className="flex flex-wrap gap-x-8 gap-y-4 py-5">
        {stats.map((s) => (
          <Stat key={s.label} value={s.value} label={s.label} />
        ))}
      </dl>

      <div className="relative h-[560px] sm:h-[640px] lg:h-[700px]">
        <div aria-hidden className="absolute inset-0">
          {hours.map((m) => (
            <span
              key={m}
              className="absolute left-0 h-px w-1 bg-line-hi"
              style={{ top: `${((m - start) / total) * 100}%` }}
            />
          ))}
        </div>

        {/* The rail. It scales up from the top as the section arrives, the day
            filling in, which is the gesture the menu bar icon already makes.
            Reduced motion collapses the animation globally, and the end state
            is the readable one. */}
        <div
          aria-hidden
          className="absolute bottom-0 left-[9px] top-0 w-2.5 origin-top sm:w-3"
          style={visible ? { animation: "fill-up 1s var(--ease-out-expo) both" } : { transform: "scaleY(0)" }}
        >
          {segs.map((s) => (
            <span
              key={s.t}
              className={cn(
                "absolute rounded-[1px]",
                s.tone === "break" ? "left-[-3px] right-[-3px]" : "inset-x-0",
              )}
              style={{ top: `${s.topPct}%`, height: `${s.hPct}%`, ...fillStyle(s.tone, s.f0, s.f1) }}
            >
              {s.tone === "held" && (
                <span
                  className="absolute inset-0 rounded-[1px] border border-dashed"
                  style={{ borderColor: AMBER_LINE, backgroundImage: HATCH }}
                />
              )}
            </span>
          ))}
        </div>

        <ol className="absolute inset-y-0 left-9 right-0">
          {segs.map((s, i) =>
            labelled(s, i) ? (
              <li
                key={s.t}
                className="reveal absolute inset-x-0 flex items-start gap-2.5"
                data-visible={visible}
                style={{ top: `${s.topPct}%`, transitionDelay: `${240 + i * 30}ms` }}
              >
                <span
                  aria-hidden
                  className="mt-[7px] h-px w-3 shrink-0"
                  style={{
                    background:
                      s.tone === "break" || s.tone === "held" ? AMBER_LINE : "var(--color-line-hi)",
                  }}
                />
                <span className="min-w-0 -translate-y-[3px]">
                  <span className="font-mono text-[11px] tabular-nums text-fg-faint">{s.t}</span>
                  <span
                    className={cn(
                      "ml-2 text-[13px] leading-snug",
                      s.tone === "break" || s.tone === "held" ? "text-fg" : "text-fg-muted",
                    )}
                  >
                    {s.label}
                  </span>
                  {(s.tone === "break" || s.tone === "held") && (
                    <span className="ml-2 font-mono text-[10px] tabular-nums text-fg-faint">
                      {short(s.dur)}
                    </span>
                  )}
                  {s.tone === "strain" && (
                    <span className="ml-2 font-mono text-[10px] tabular-nums text-fg-faint">
                      {short(s.unbroken)} {copy.stats.unbroken}
                    </span>
                  )}
                </span>
              </li>
            ) : (
              <li key={s.t} className="sr-only">
                {s.t}, {s.label}
              </li>
            ),
          )}
        </ol>
      </div>

      <p className="mt-3 pl-9 font-mono text-[11px] tabular-nums text-fg-faint">{end}</p>
    </div>
  );
}

/** Totals are derived from the timeline data, never written down a second time. */
function totals(items: readonly Item[], end: string) {
  const { segs, total } = build(items, end);
  const breaks = segs.filter((s) => s.tone === "break");
  return {
    span: hm(total),
    seams: breaks.length,
    away: hm(breaks.reduce((n, s) => n + s.dur, 0)),
    held: segs.filter((s) => s.tone === "held").length,
  };
}

export function BeforeAfter() {
  const { ref, visible } = useReveal<HTMLDivElement>(0.08);

  const b = totals(copy.before.items, copy.before.end);
  const a = totals(copy.after.items, copy.after.end);

  return (
    <Section id="before-after">
      <div ref={ref} className="reveal" data-visible={visible}>
        <Kicker>{copy.kicker}</Kicker>
        <Headline>{copy.headline}</Headline>
        <Lede>{copy.sub}</Lede>
        <p className="mt-4 font-mono text-[11px] leading-relaxed text-fg-faint">{copy.scaleNote}</p>

        <div className="mt-14 grid gap-16 md:grid-cols-2 md:gap-10 lg:gap-16">
          <Column
            title={copy.before.title}
            meta={copy.before.meta}
            end={copy.before.end}
            items={copy.before.items}
            stats={[
              { value: b.span, label: copy.stats.span },
              { value: b.span, label: copy.stats.unbroken },
            ]}
            visible={visible}
            className="md:border-r md:border-line md:pr-10 lg:pr-16"
          />
          <Column
            title={copy.after.title}
            meta={copy.after.meta}
            end={copy.after.end}
            items={copy.after.items}
            stats={[
              { value: a.span, label: copy.stats.span },
              { value: String(a.seams), label: copy.stats.seams },
              { value: a.away, label: copy.stats.away },
              { value: String(a.held), label: copy.stats.held },
            ]}
            visible={visible}
          />
        </div>

        <dl className="mt-16 grid gap-x-10 gap-y-6 border-t border-line pt-8 sm:grid-cols-2 lg:grid-cols-4">
          {copy.legend.map((l) => (
            <div key={l.tone} className="flex gap-3.5">
              <Swatch tone={l.tone} />
              <div className="min-w-0">
                <dt className="font-mono text-xs font-bold text-fg">{l.label}</dt>
                <dd className="mt-1.5 text-pretty text-[13px] leading-relaxed text-fg-muted">{l.desc}</dd>
              </div>
            </div>
          ))}
        </dl>

        {/* The refusal. Not small print: a diagram like the one above is exactly
            where a product would normally slip in a claim it cannot support, so
            the refusal is set at the same weight as the diagram. */}
      </div>
    </Section>
  );
}
