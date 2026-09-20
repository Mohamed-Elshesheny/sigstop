import { cn } from "@/lib/cn";

/**
 * The product mark: two terminal block bars.
 *
 * The bars are hollow while the session is young and fill from the bottom as
 * continuous work accrues — so the icon IS the timer rather than decoration
 * sitting next to one. At 100% it flips to the suspend colour, which is the
 * only moment it ever changes colour.
 *
 * `fill` is 0–1 and is the fraction of the configured work interval elapsed.
 */
export function MenuBarIcon({
  fill = 0, size = 18, className,
}: { fill?: number; size?: number; className?: string }) {
  const clamped = Math.min(1, Math.max(0, fill));
  const due = clamped >= 1;
  const color = due ? "var(--color-suspend)" : "var(--color-fg)";
  const barW = size * 0.3;
  const gap = size * 0.16;

  return (
    <span
      className={cn("relative inline-flex items-end", className)}
      style={{ width: size, height: size, gap }}
      role="img"
      aria-label={due ? "Break due" : `Session ${Math.round(clamped * 100)} percent`}
    >
      {[0, 1].map((i) => (
        <span
          key={i}
          className="relative overflow-hidden rounded-[1.5px]"
          style={{ width: barW, height: size, border: `1.5px solid ${color}` }}
        >
          <span
            className="absolute inset-x-0 bottom-0 origin-bottom transition-transform duration-700"
            style={{ background: color, height: "100%", transform: `scaleY(${clamped})` }}
          />
        </span>
      ))}
    </span>
  );
}
