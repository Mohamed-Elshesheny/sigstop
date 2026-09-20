"use client";

import { useEffect, useState } from "react";
import { nav, site, hero } from "@/content/copy";
import { MenuBarIcon } from "./ui/MenuBarIcon";
import { ThemeToggle } from "./ui/ThemeToggle";
import { cn } from "@/lib/cn";

export function Nav() {
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 24);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <header
      className={cn(
        "fixed inset-x-0 top-0 z-50 transition-all duration-300",
        scrolled && "border-b border-line bg-bg/80 backdrop-blur-xl",
      )}
    >
      <nav className="mx-auto flex h-16 w-full max-w-6xl items-center justify-between px-5 sm:px-8">
        <a href="#" className="flex items-center gap-2.5" aria-label="sigstop home">
          <MenuBarIcon fill={0.6} size={16} brand />
          <span className="font-mono text-[15px] font-bold tracking-tight">sigstop</span>
        </a>

        <ul className="hidden items-center gap-8 md:flex">
          {nav.map((item) => (
            <li key={item.href}>
              <a
                href={item.href}
                className="font-mono text-[13px] text-fg-muted transition-colors hover:text-fg"
              >
                {item.label}
              </a>
            </li>
          ))}
        </ul>

        <div className="flex items-center gap-2">
          <ThemeToggle />
          <a
            href={site.repo}
            className="hidden rounded-lg border border-line-hi px-4 py-2 font-mono text-[13px] text-fg-muted transition-colors hover:border-fg-faint hover:text-fg sm:block"
          >
            GitHub
          </a>
          <a
            href="#download"
            className="rounded-lg bg-suspend px-4 py-2 font-mono text-[13px] font-semibold text-accent-fg transition-opacity hover:opacity-90"
          >
            {hero.primaryCta.replace(" for macOS", "")}
          </a>
        </div>
      </nav>
    </header>
  );
}
