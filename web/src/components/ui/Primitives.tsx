import { cn } from "@/lib/cn";

export function Section({
  id, className, children,
}: { id?: string; className?: string; children: React.ReactNode }) {
  return (
    <section id={id} className={cn("relative px-5 py-16 sm:px-8 md:py-20", className)}>
      <div className="mx-auto w-full max-w-6xl">{children}</div>
    </section>
  );
}

export function Kicker({ children }: { children: React.ReactNode }) {
  return (
    <p className="mb-5 flex items-center gap-2.5 font-mono text-[11px] uppercase tracking-[0.2em] text-fg-faint">
      <span className="h-px w-6 bg-line-hi" aria-hidden />
      {children}
    </p>
  );
}

export function Headline({ children, className }: { children: React.ReactNode; className?: string }) {
  return (
    <h2 className={cn("text-balance font-mono text-[length:var(--text-section)] font-bold leading-[1.02] tracking-[-0.03em]", className)}>
      {children}
    </h2>
  );
}

export function Lede({ children, className }: { children: React.ReactNode; className?: string }) {
  return <p className={cn("mt-6 max-w-2xl text-pretty text-lg leading-relaxed text-fg-muted", className)}>{children}</p>;
}

export function Button({
  href, variant = "primary", children, className,
}: {
  href: string;
  variant?: "primary" | "ghost";
  children: React.ReactNode;
  className?: string;
}) {
  const base =
    "group inline-flex items-center justify-center gap-2 rounded-lg px-6 py-3.5 font-mono text-sm font-semibold transition-all duration-200";
  const styles =
    variant === "primary"
      ? "bg-suspend text-accent-fg hover:opacity-90 hover:-translate-y-0.5 active:translate-y-0"
      : "border border-line-hi text-fg hover:border-fg-faint hover:bg-surface";
  return (
    <a href={href} className={cn(base, styles, className)}>
      {children}
    </a>
  );
}

/** A dot that reads as a process state indicator. */
export function StateDot({ state }: { state: "running" | "suspend" | "alert" }) {
  const color = state === "running" ? "bg-running" : state === "suspend" ? "bg-suspend" : "bg-alert";
  return <span className={cn("inline-block h-1.5 w-1.5 shrink-0 rounded-full", color)} aria-hidden />;
}

/** Terminal-style chrome used for code and shell samples. */
export function TerminalFrame({
  title, children, className,
}: { title?: string; children: React.ReactNode; className?: string }) {
  return (
    <div className={cn("overflow-hidden rounded-xl border border-line bg-bg-raised", className)}>
      <div className="flex items-center gap-2 border-b border-line bg-surface px-4 py-2.5">
        <span className="h-2.5 w-2.5 rounded-full bg-[#ff5f57]" aria-hidden />
        <span className="h-2.5 w-2.5 rounded-full bg-[#febc2e]" aria-hidden />
        <span className="h-2.5 w-2.5 rounded-full bg-[#28c840]" aria-hidden />
        {title && <span className="ml-2 font-mono text-xs text-fg-faint">{title}</span>}
      </div>
      <div className="p-4 font-mono text-sm leading-relaxed sm:p-5">{children}</div>
    </div>
  );
}
