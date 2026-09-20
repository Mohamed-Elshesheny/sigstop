import type { Metadata, Viewport } from "next";
import { Inter, JetBrains_Mono } from "next/font/google";
import { site } from "@/content/copy";
import "./globals.css";

/* next/font self-hosts these at build time — no runtime request to Google.
   On a page whose whole argument is "this app makes no network calls", shipping
   a third-party font request would be an embarrassing contradiction. */
const inter = Inter({ subsets: ["latin"], variable: "--font-inter", display: "swap" });
const jetbrains = JetBrains_Mono({ subsets: ["latin"], variable: "--font-jetbrains", display: "swap" });

export const metadata: Metadata = {
  title: "sigstop — you're a developer, not a server",
  description: site.description,
  keywords: ["macOS", "developer tools", "open source", "break reminder", "menu bar app", "swift"],
  openGraph: {
    title: "sigstop — you're a developer, not a server",
    description: site.description,
    type: "website",
    siteName: "sigstop",
  },
  twitter: { card: "summary_large_image", title: "sigstop", description: site.description },
  metadataBase: new URL("https://sigstop.dev"),
};

export const viewport: Viewport = {
  themeColor: "#08090b",
  colorScheme: "dark",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${inter.variable} ${jetbrains.variable}`}>
      <body className="antialiased">
        <a
          href="#main"
          className="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-[100] focus:rounded-md focus:bg-suspend focus:px-4 focus:py-2 focus:font-mono focus:text-sm focus:text-black"
        >
          Skip to content
        </a>
        {children}
      </body>
    </html>
  );
}
