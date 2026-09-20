"use client";

import { server as copy } from "@/content/copy";
import { Section, Kicker, Headline, Lede } from "../ui/Primitives";
import { useReveal } from "@/lib/useReveal";
import { cn } from "@/lib/cn";

const ROWS = copy.rows;
const HOSTS = copy.ui.hosts;

/**
 * One check result.
 *
 * Red is reserved for escalation L4 and genuine warnings, so a missing check is
 * drawn as an empty ring, absence, not failure, which is also the truer joke.
 * Exactly one row ("nobody is on call for you") escalates, because exactly one
 * of these is a real operational hole.
 */
function Cell({
  label, ok, note, escalated,
}: { label: string; ok: boolean; note: string; escalated?: boolean }) {
  const status = ok ? copy.ui.pass : copy.ui.absent;
  return (
    <div className="flex items-start gap-2.5">
      <span
        className={cn(
          "mt-[0.3rem] h-2.5 w-2.5 shrink-0 rounded-full border",
          ok
            ? "border-running bg-running"
            : escalated
              ? "border-alert bg-transparent"
              : "border-line-hi bg-transparent",
        )}
        aria-hidden
      />
      <div className="min-w-0">
        {/* Visible on narrow layouts, where there is no header row to read from.
            sr-only at md keeps it in the accessibility tree either way. */}
        <span className="block font-mono text-[10px] uppercase tracking-[0.16em] text-fg-faint md:sr-only">
          {label}
        </span>
        {/* The dot carries pass/absent for sighted readers and is decorative, so
            the state is restated in text for everyone else, but only when the
            note does not already say it, to avoid "configured configured". */}
        {note !== status && <span className="sr-only">{status}. </span>}
        <span
          className={cn(
            "block font-mono text-[13px] leading-snug",
            ok ? "text-fg-muted" : escalated ? "text-alert" : "text-fg-faint",
          )}
        >
          {note}
        </span>
      </div>
    </div>
  );
}

/** Status-page strip. The shape of the two columns is legible before any word is. */
function CheckStrip({ passes, total }: { passes: number; total: number }) {
  return (
    <div className="mt-3 flex gap-1" aria-hidden>
      {Array.from({ length: total }, (_, i) => (
        <span
          key={i}
          className={cn(
            "h-5 flex-1 rounded-[2px]",
            i < passes ? "bg-running/70" : "bg-surface-hi",
          )}
        />
      ))}
    </div>
  );
}

function HostCard({
  name, role, meta, score, passes, total, tone,
}: {
  name: string; role: string; meta: string; score: string;
  passes: number; total: number; tone: "ok" | "thin";
}) {
  return (
    <div className="min-w-0 p-4 sm:p-5">
      <p className="font-mono text-[10px] uppercase tracking-[0.18em] text-fg-faint">{role}</p>
      <p className="mt-1.5 truncate font-mono text-sm font-bold text-fg">{name}</p>
      <p className="mt-1 font-mono text-xs text-fg-faint tabular-nums">{meta}</p>
      <CheckStrip passes={passes} total={total} />
      <p
        className={cn(
          "mt-2.5 font-mono text-[11px] tabular-nums",
          tone === "ok" ? "text-running" : "text-fg-muted",
        )}
      >
        {score}
      </p>
    </div>
  );
}

export function BodyNotServer() {
  const { ref: headRef, visible: headVisible } = useReveal<HTMLDivElement>();
  const { ref: boardRef, visible: boardVisible } = useReveal<HTMLDivElement>(0.08);

  const total = ROWS.length;
  const serverPasses = ROWS.filter((r) => r.server).length;
  const devPasses = ROWS.filter((r) => r.dev).length;

  return (
    <Section>
      <div ref={headRef} className="reveal" data-visible={headVisible}>
        <Kicker>{copy.kicker}</Kicker>
        <Headline>{copy.headline}</Headline>
        <Lede>{copy.sub}</Lede>
      </div>

      <div
        ref={boardRef}
        className="reveal mt-12 overflow-hidden rounded-xl border border-line bg-bg-raised"
        data-visible={boardVisible}
      >
        <div className="flex items-center justify-between gap-4 border-b border-line bg-surface px-4 py-2.5 sm:px-5">
          <span className="font-mono text-xs text-fg-faint">{copy.ui.boardTitle}</span>
          <span className="hidden font-mono text-[11px] text-fg-faint sm:block">{copy.ui.legend}</span>
        </div>

        {/* Two hosts, side by side at every width, the comparison is the point. */}
        <div className="grid grid-cols-2 divide-x divide-line border-b border-line">
          <HostCard
            name={HOSTS.server.name}
            role={HOSTS.server.role}
            meta={HOSTS.server.meta}
            score={HOSTS.server.score}
            passes={serverPasses}
            total={total}
            tone="ok"
          />
          <HostCard
            name={HOSTS.dev.name}
            role={HOSTS.dev.role}
            meta={HOSTS.dev.meta}
            score={HOSTS.dev.score}
            passes={devPasses}
            total={total}
            tone="thin"
          />
        </div>

        {/* Header row for the wide layout only; narrow rows label their own cells. */}
        <div
          className="hidden grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)_minmax(0,1fr)] gap-x-5 border-b border-line px-4 py-2.5 font-mono text-[10px] uppercase tracking-[0.18em] text-fg-faint sm:px-5 md:grid"
          aria-hidden
        >
          <span>{copy.ui.colTrait}</span>
          <span>{HOSTS.server.role}</span>
          <span>{HOSTS.dev.role}</span>
        </div>

        <ul>
          {ROWS.map((row, i) => {
            const escalated = row.trait === copy.ui.alertTrait;
            return (
              <li
                key={row.trait}
                className={cn(
                  "reveal grid grid-cols-2 gap-x-4 gap-y-3 px-4 py-4 hover:bg-surface/40 sm:px-5 md:grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)_minmax(0,1fr)] md:items-center md:gap-y-0",
                  i > 0 && "border-t border-line",
                )}
                data-visible={boardVisible}
                style={{ transitionDelay: `${60 + i * 45}ms` }}
              >
                <p className="col-span-2 font-mono text-sm leading-snug text-fg md:col-span-1">
                  {row.trait}
                </p>
                <Cell label={HOSTS.server.role} ok={row.server} note={copy.ui.pass} />
                <Cell
                  label={HOSTS.dev.role}
                  ok={row.dev}
                  note={row.devNote}
                  escalated={escalated}
                />
              </li>
            );
          })}
        </ul>

        <div className="border-t border-line bg-surface/50 px-4 py-5 sm:px-5 sm:py-6">
          <p className="max-w-2xl text-pretty font-mono text-[15px] leading-relaxed text-fg sm:text-base">
            {copy.punch}
          </p>
          <p className="mt-3 font-mono text-[11px] text-fg-faint sm:hidden">{copy.ui.legend}</p>
        </div>
      </div>
    </Section>
  );
}
