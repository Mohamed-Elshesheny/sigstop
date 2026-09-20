import type { AppKey } from "@/content/apps";

export function AppLogo({ app, className }: { app: AppKey; className?: string }) {
  const common = { className, viewBox: "0 0 24 24", "aria-hidden": true as const };

  switch (app) {
    case "cursor":
      return (
        <svg {...common}>
          <path d="M12 2 21 7v10l-9 5-9-5V7l9-5Z" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" />
          <path d="M12 2v20M3 7l9 5 9-5M3 17l9-5 9 5" stroke="currentColor" strokeWidth="1.1" strokeLinejoin="round" opacity=".65" />
        </svg>
      );
    case "vscode":
      return (
        <svg {...common}>
          <path d="M17.6 2.3 9.4 10 5 6.6 3 7.7v8.6l2 1.1 4.4-3.4 8.2 7.7L22 20V4l-4.4-1.7Z" fill="none" stroke="#3b9eff" strokeWidth="1.5" strokeLinejoin="round" />
          <path d="M18 6.4v11.2L10.6 12 18 6.4Z" fill="#3b9eff" opacity=".85" />
        </svg>
      );
    case "terminal":
      return (
        <svg {...common}>
          <rect x="2.5" y="4" width="19" height="16" rx="2.6" fill="none" stroke="currentColor" strokeWidth="1.5" />
          <path d="m6.5 9.5 3 2.5-3 2.5M12 15h5.5" stroke="#3fb950" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      );
    case "github":
      return (
        <svg {...common}>
          <path
            fill="currentColor"
            d="M12 2a10 10 0 0 0-3.16 19.49c.5.09.68-.22.68-.48v-1.7c-2.78.6-3.37-1.34-3.37-1.34-.45-1.16-1.11-1.47-1.11-1.47-.91-.62.07-.6.07-.6 1 .07 1.53 1.03 1.53 1.03.9 1.53 2.35 1.09 2.92.83.09-.65.35-1.09.63-1.34-2.22-.25-4.56-1.11-4.56-4.94 0-1.09.39-1.98 1.03-2.68-.1-.25-.45-1.27.1-2.65 0 0 .84-.27 2.75 1.02a9.5 9.5 0 0 1 5 0c1.91-1.29 2.75-1.02 2.75-1.02.55 1.38.2 2.4.1 2.65.64.7 1.03 1.59 1.03 2.68 0 3.84-2.34 4.68-4.57 4.93.36.31.68.92.68 1.85v2.74c0 .27.18.58.69.48A10 10 0 0 0 12 2Z"
          />
        </svg>
      );
    case "xcode":
      return (
        <svg {...common}>
          <path d="M12 2.5 21 12l-9 9.5L3 12l9-9.5Z" fill="none" stroke="#3b9eff" strokeWidth="1.5" strokeLinejoin="round" />
          <path d="m8.6 12 2.4 2.6 4.4-5.2" stroke="#3b9eff" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" fill="none" />
        </svg>
      );
    case "slack":
      return (
        <svg {...common}>
          <g strokeWidth="2.4" strokeLinecap="round" fill="none">
            <path d="M6.5 14.2H4.3M9.8 14.2v5.5" stroke="#e01e5a" />
            <path d="M9.8 17.5H4.3M6.5 9.8v2.2" stroke="#36c5f0" />
            <path d="M17.5 9.8h2.2M14.2 9.8V4.3" stroke="#2eb67d" />
            <path d="M14.2 6.5h5.5M17.5 14.2v-2.2" stroke="#ecb22e" />
          </g>
          <g fill="none" stroke="currentColor" strokeWidth="1.2" opacity=".25">
            <circle cx="12" cy="12" r="9.2" />
          </g>
        </svg>
      );
    case "docker":
      return (
        <svg {...common}>
          <g fill="#3b9eff">
            <rect x="3.2" y="10.4" width="2.6" height="2.4" rx=".4" />
            <rect x="6.4" y="10.4" width="2.6" height="2.4" rx=".4" />
            <rect x="9.6" y="10.4" width="2.6" height="2.4" rx=".4" />
            <rect x="12.8" y="10.4" width="2.6" height="2.4" rx=".4" />
            <rect x="6.4" y="7.6" width="2.6" height="2.3" rx=".4" />
            <rect x="9.6" y="7.6" width="2.6" height="2.3" rx=".4" />
            <rect x="12.8" y="7.6" width="2.6" height="2.3" rx=".4" />
          </g>
          <path d="M2.4 13.4c0 3.6 2.6 6.2 7 6.2 5.3 0 9.2-2.6 10.6-7 1.4.6 2.7.2 3.4-.8-1-.8-2.4-.9-3.4-.4" fill="none" stroke="#3b9eff" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      );
    case "figma":
      return (
        <svg {...common}>
          <g strokeWidth="0">
            <path d="M8.8 2.4h3.2v5.2H8.8a2.6 2.6 0 0 1 0-5.2Z" fill="#f24e1e" />
            <path d="M12 2.4h3.2a2.6 2.6 0 0 1 0 5.2H12V2.4Z" fill="#ff7262" />
            <path d="M12 7.6h3.2a2.6 2.6 0 0 1 0 5.2H12V7.6Z" fill="#1abcfe" />
            <path d="M8.8 7.6H12v5.2H8.8a2.6 2.6 0 0 1 0-5.2Z" fill="#a259ff" />
            <path d="M8.8 12.8H12V18a2.6 2.6 0 1 1-3.2-5.2Z" fill="#0acf83" />
          </g>
        </svg>
      );
  }
}
