"use client";

import { notPomodoro as copy } from "@/content/copy";
import { Section, Kicker, Headline, Lede } from "../ui/Primitives";
import { useReveal } from "@/lib/useReveal";
import { cn } from "@/lib/cn";

/**
 * Two pipelines, drawn as pipelines.
 *
 * The argument of this section is the asymmetry, so the two columns are
 * deliberately NOT balanced: the timer gets a narrow column that runs out after
 * three nodes and then stops, and the whitespace underneath it is part of the
 * point. Equal-height cards would have quietly argued the opposite.
 *
 * Four of the sigstop nodes are gates, they are allowed to end the run without
 * ever showing you anything. Those are drawn with a dashed outgoing edge,
 * because "the flow may not continue past here" is exactly what dashed means.
 */

type Stage = keyof typeof copy.stageLabels;

/** Gates can terminate the pipeline. The mic check is the one that always wins. */
const GATES: ReadonlySet<string> = new Set<Stage>(["inference", "honesty", "veto", "timing"]);

/** Node accent. Amber only where a decision is taken; green only at SIGCONT. */
function accentFor(stage: string): string {
  switch (stage) {
    case "honesty":
    case "veto":
    case "timing":
      return "var(--color-suspend)";
    case "resume":
      return "var(--color-running)";
    case "inference":
    case "message":
      return "var(--color-fg)";
    default:
      return "var(--color-fg-faint)";
  }
}

function Node({
  index,
  total,
  label,
  stage,
  visible,
  emphasis,
}: {
  index: number;
  total: number;
  label: string;
  stage: string;
  visible: boolean;
  emphasis: boolean;
}) {
  const last = index === total - 1;
  const gate = GATES.has(stage);
  const accent = emphasis ? accentFor(stage) : "var(--color-fg-faint)";
  const stageLabel = copy.stageLabels[stage as Stage] ?? stage;

  return (
    <li
      className="reveal relative flex gap-4 pb-4 last:pb-0"
      data-visible={visible}
      style={{ transitionDelay: `${index * 55}ms` }}
    >
      {/* The edge to the next node. Dashed after a gate: the run may end here. */}
      {!last && (
        <span
          aria-hidden
          className={cn(
            "absolute left-[13px] top-8 bottom-0",
            gate ? "border-l border-dashed" : "border-l",
          )}
          style={{ borderColor: gate ? "color-mix(in srgb, var(--color-suspend) 45%, transparent)" : "var(--color-line)" }}
        />
      )}

      <span
        aria-hidden
        className="relative z-10 grid h-7 w-7 shrink-0 place-items-center rounded-md border bg-bg font-mono text-[10px] tabular-nums"
        style={{ borderColor: accent, color: accent }}
      >
        {String(index + 1).padStart(2, "0")}
      </span>

      <span className="min-w-0 flex-1 pt-0.5">
        <span className={cn("block text-pretty text-[15px] leading-snug", emphasis ? "text-fg" : "text-fg-muted")}>
          {label}
        </span>
        <span className="mt-1 flex flex-wrap items-center gap-2 font-mono text-[10px] uppercase tracking-[0.16em] text-fg-faint">
          <span>{stageLabel}</span>
          {gate && (
            <span
              className={cn(
                "rounded-sm border px-1.5 py-px tracking-[0.12em] normal-case",
                stage === "veto"
                  ? "border-suspend/50 text-suspend"
                  : "border-line-hi text-fg-faint",
              )}
            >
              {stage === "veto" ? copy.vetoLabel : copy.gateLabel}
            </span>
          )}
        </span>
      </span>
    </li>
  );
}

function Pipeline({
  title,
  meta,
  steps,
  kinds,
  note,
  emphasis,
  visible,
  className,
}: {
  title: string;
  meta: string;
  steps: readonly string[];
  kinds: readonly string[];
  note: string;
  emphasis: boolean;
  visible: boolean;
  className?: string;
}) {
  return (
    <div className={cn("flex flex-col", className)}>
      <div className="mb-6 flex items-baseline justify-between gap-3 border-b border-line pb-3">
        <h3 className={cn("font-mono text-sm font-bold", emphasis ? "text-fg" : "text-fg-muted")}>{title}</h3>
        <span className="font-mono text-[10px] tabular-nums text-fg-faint">
          {steps.length} {copy.countLabel}
        </span>
      </div>

      <p className={cn("mb-7 max-w-sm text-pretty text-sm leading-relaxed", emphasis ? "text-fg-muted" : "text-fg-faint")}>
        {meta}
      </p>

      <ol className="relative">
        {steps.map((step, i) => (
          <Node
            key={step}
            index={i}
            total={steps.length}
            label={step}
            stage={kinds[i] ?? "signal"}
            visible={visible}
            emphasis={emphasis}
          />
        ))}
      </ol>

      <p
        className={cn(
          "mt-7 text-pretty text-sm leading-relaxed",
          emphasis ? "text-fg-muted" : "border-l-2 border-line-hi pl-4 text-fg-faint",
        )}
      >
        {note}
      </p>
    </div>
  );
}

export function NotPomodoro() {
  const { ref, visible } = useReveal<HTMLDivElement>(0.1);

  return (
    <Section id="not-pomodoro">
      <div ref={ref} className="reveal" data-visible={visible}>
        <Kicker>{copy.kicker}</Kicker>
        <Headline>{copy.headline}</Headline>
        <Lede>{copy.sub}</Lede>

        {/* Asymmetric on purpose. The short pipeline gets the short column. */}
        <div className="mt-12 grid gap-14 md:grid-cols-[minmax(0,17rem)_minmax(0,1fr)] md:gap-14 lg:gap-20">
          <Pipeline
            title={copy.timer.title}
            meta={copy.timer.meta}
            steps={copy.timer.steps}
            kinds={copy.timer.kinds}
            note={copy.timer.note}
            emphasis={false}
            visible={visible}
            className="self-start md:border-r md:border-line md:pr-10 lg:pr-12"
          />
          <Pipeline
            title={copy.sigstop.title}
            meta={copy.sigstop.meta}
            steps={copy.sigstop.steps}
            kinds={copy.sigstop.kinds}
            note={copy.sigstop.note}
            emphasis
            visible={visible}
          />
        </div>

        {/* The line this whole section exists to land. */}
      </div>
    </Section>
  );
}
