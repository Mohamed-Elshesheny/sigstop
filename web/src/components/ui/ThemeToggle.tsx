"use client";

import { useEffect, useState } from "react";

type Theme = "light" | "dark";

/**
 * Light/dark switch.
 *
 * Defaults to the OS preference and only persists a choice once the reader
 * makes one, so we never override someone's system setting on first visit.
 * The pre-paint script in layout.tsx applies the stored value before React
 * mounts, which is what prevents a flash of the wrong theme.
 */
export function ThemeToggle() {
  const [theme, setTheme] = useState<Theme | null>(null);

  useEffect(() => {
    const stored = (() => {
      try { return localStorage.getItem("sigstop-theme") as Theme | null; } catch { return null; }
    })();
    const systemDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
    setTheme(stored ?? (systemDark ? "dark" : "light"));
  }, []);

  function toggle() {
    const next: Theme = theme === "dark" ? "light" : "dark";
    setTheme(next);
    document.documentElement.setAttribute("data-theme", next);
    try { localStorage.setItem("sigstop-theme", next); } catch { /* private mode */ }
  }

  // Render a stable-size placeholder until we know the theme, so the nav
  // does not shift when it resolves.
  if (!theme) return <span className="h-9 w-9" aria-hidden />;

  const dark = theme === "dark";
  return (
    <button
      onClick={toggle}
      aria-label={dark ? "Switch to light theme" : "Switch to dark theme"}
      title={dark ? "Switch to light theme" : "Switch to dark theme"}
      className="grid h-9 w-9 place-items-center rounded-lg border border-line-hi text-fg-muted transition-colors hover:border-fg-faint hover:text-fg"
    >
      {/* A process that is running vs one that is suspended, same two states
          the product is about, reused as the theme metaphor. */}
      <svg width="15" height="15" viewBox="0 0 16 16" fill="none" aria-hidden>
        {dark ? (
          <>
            <circle cx="8" cy="8" r="3.4" stroke="currentColor" strokeWidth="1.4" />
            {[0, 45, 90, 135, 180, 225, 270, 315].map((a) => (
              <line
                key={a}
                x1="8" y1="1.2" x2="8" y2="2.9"
                stroke="currentColor" strokeWidth="1.4" strokeLinecap="round"
                transform={`rotate(${a} 8 8)`}
              />
            ))}
          </>
        ) : (
          <path
            d="M13.4 9.6A5.8 5.8 0 0 1 6.4 2.6a5.9 5.9 0 1 0 7 7Z"
            stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round"
          />
        )}
      </svg>
    </button>
  );
}
