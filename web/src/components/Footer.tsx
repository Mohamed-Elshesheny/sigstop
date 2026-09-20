import { footer as copy, site } from "@/content/copy";
import { MenuBarIcon } from "./ui/MenuBarIcon";

/**
 * Minimal on purpose. A footer stuffed with badges and newsletter signup would
 * undo the sentence directly above it about not collecting anything.
 */
export function Footer() {
  return (
    <footer className="border-t border-line px-5 py-16 sm:px-8">
      <div className="mx-auto w-full max-w-6xl">
        <div className="grid gap-12 md:grid-cols-[minmax(0,1fr)_auto] md:gap-20">
          <div>
            <p className="flex items-center gap-2.5 font-mono text-sm font-bold tracking-tight text-fg">
              {/* The mark carries no information here, so it does not announce itself. */}
              <span aria-hidden>
                <MenuBarIcon fill={1} size={15} />
              </span>
              {site.name}
            </p>
            <p className="mt-4 max-w-sm text-pretty text-sm leading-relaxed text-fg-muted">{copy.blurb}</p>
            <p className="mt-4 font-mono text-[11px] tracking-wide text-fg-faint">{site.tagline}</p>
          </div>

          <div className="grid grid-cols-2 gap-10 sm:gap-16">
            {copy.columns.map((column) => {
              const headingId = `footer-${column.title.toLowerCase()}`;
              return (
                <nav key={column.title} aria-labelledby={headingId}>
                  <h2
                    id={headingId}
                    className="font-mono text-[11px] uppercase tracking-[0.2em] text-fg-faint"
                  >
                    {column.title}
                  </h2>
                  <ul className="mt-5 space-y-3">
                    {column.links.map((link) => (
                      <li key={link.label}>
                        <a
                          href={link.href}
                          className="font-mono text-[13px] text-fg-muted transition-colors duration-200 hover:text-fg"
                        >
                          {link.label}
                        </a>
                      </li>
                    ))}
                  </ul>
                </nav>
              );
            })}
          </div>
        </div>

        <p className="mt-14 border-t border-line pt-8 font-mono text-[11px] leading-relaxed text-fg-faint">
          {copy.colophon}
        </p>
      </div>
    </footer>
  );
}
