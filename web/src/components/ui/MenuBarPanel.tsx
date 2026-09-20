"use client";

import { MenuBarIcon } from "./MenuBarIcon";
import { StateDot } from "./Primitives";

/**
 * A faithful mock of the app's menu bar dropdown.
 *
 * The numbers shown are the real fields the app tracks. The "why" list is the
 * evidence trail — the product's rule is that it must always be able to answer
 * "why do you think that?", so the UI shows its reasoning rather than asserting.
 */
export function MenuBarPanel({
  minutes, target, app, activity, confidence, evidence,
}: {
  minutes: number;
  target: number;
  app: string;
  activity: string;
  confidence: number;
  evidence: string[];
}) {
  const fill = Math.min(1, minutes / target);
  const due = fill >= 1;
  const pct = Math.round(confidence * 100);

  return (
    <div className="w-full max-w-[340px] overflow-hidden rounded-xl border border-line-hi bg-bg-raised shadow-2xl shadow-black/60">
      {/* fake menu bar strip */}
      <div className="flex items-center justify-end gap-3 border-b border-line bg-surface px-3 py-1.5">
        <span className="font-mono text-[10px] text-fg-faint">100%</span>
        <span className="font-mono text-[10px] text-fg-faint">Wed 14:52</span>
        <MenuBarIcon fill={fill} size={14} />
      </div>

      <div className="p-4">
        <div className="flex items-baseline justify-between">
          <span className="font-mono text-[11px] uppercase tracking-widest text-fg-faint">
            {due ? "break due" : "running"}
          </span>
          <span className="flex items-center gap-1.5 font-mono text-[11px] text-fg-faint">
            <StateDot state={due ? "suspend" : "running"} />
            {due ? "SIGTSTP" : "state R"}
          </span>
        </div>

        <div className="mt-2 flex items-baseline gap-2">
          <span
            className="font-mono text-4xl font-bold tabular-nums tracking-tight"
            style={{ color: due ? "var(--color-suspend)" : "var(--color-fg)" }}
          >
            {String(Math.floor(minutes / 60)).padStart(2, "0")}:{String(minutes % 60).padStart(2, "0")}
          </span>
          <span className="font-mono text-xs text-fg-faint">continuous</span>
        </div>

        {/* progress toward the configured interval */}
        <div className="mt-3 h-1 overflow-hidden rounded-full bg-surface-hi">
          <div
            className="h-full rounded-full transition-all duration-700"
            style={{ width: `${fill * 100}%`, background: due ? "var(--color-suspend)" : "var(--color-running)" }}
          />
        </div>

        <dl className="mt-4 space-y-1.5 border-t border-line pt-3 font-mono text-[11px]">
          <div className="flex justify-between gap-3">
            <dt className="text-fg-faint">app</dt>
            <dd className="truncate text-fg">{app}</dd>
          </div>
          <div className="flex justify-between gap-3">
            <dt className="text-fg-faint">activity</dt>
            <dd className="text-fg">{activity}</dd>
          </div>
          <div className="flex justify-between gap-3">
            <dt className="text-fg-faint">confidence</dt>
            <dd style={{ color: confidence >= 0.6 ? "var(--color-running)" : "var(--color-suspend)" }}>
              {confidence.toFixed(2)}
              <span className="ml-1 text-fg-faint">({pct}%)</span>
            </dd>
          </div>
        </dl>

        <details className="mt-3 border-t border-line pt-3">
          <summary className="cursor-pointer font-mono text-[11px] text-fg-faint transition-colors hover:text-fg">
            why do you think that?
          </summary>
          <ul className="mt-2 space-y-1">
            {evidence.map((e) => (
              <li key={e} className="flex gap-2 font-mono text-[10px] leading-relaxed text-fg-muted">
                <span className="text-fg-faint">→</span>
                {e}
              </li>
            ))}
          </ul>
        </details>
      </div>
    </div>
  );
}
