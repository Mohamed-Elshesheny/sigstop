/**
 * All landing-page prose lives here so the writing can be reviewed as writing,
 * and so no component has to be edited to fix a sentence.
 *
 * Voice: deadpan accomplice. The app is on your side and funny about it.
 * It is NOT a warden. "Cannot be ignored" is a bluff the reader is in on —
 * a menu bar app cannot suspend anyone, and the copy never pretends otherwise.
 *
 * Hard rules (CLAUDE.md §4.5):
 *   - no medical claims, ever. "your posture", never "your health".
 *   - never about body weight, appearance, medical conditions, mental health,
 *     competence, or job security.
 *   - no generic SaaS language. If a sentence could appear on any startup's
 *     homepage, it is deleted.
 */

export const site = {
  name: "sigstop",
  repo: "https://github.com/sigstop/sigstop",
  tagline: "Suspend. Resume. Nothing lost.",
  description:
    "An open-source macOS menu bar app that notices what you're actually working on and tells you to step away — in a language you'll recognise.",
} as const;

export const nav = [
  { label: "Product", href: "#product" },
  { label: "How it works", href: "#how-it-works" },
  { label: "Privacy", href: "#privacy" },
  { label: "Open source", href: "#open-source" },
] as const;

export const hero = {
  eyebrow: "open source · macOS · local-first",
  headline: ["You're a developer.", "Not a server."],
  sub: "You spend your day debugging, reviewing PRs, arguing with an AI, and staring at the same forty lines. sigstop watches your workflow — never your code — and works out when it's actually a good moment to stop.",
  primaryCta: "Download for macOS",
  secondaryCta: "View on GitHub",
  note: "Free forever. No account. No telemetry. Works with zero permissions granted.",
} as const;

/**
 * The objection this product has to beat is not "I don't have time."
 * It is "if I stop now I lose the stack I've been holding for forty minutes."
 * The name answers it, so the site leads with that answer.
 */
export const namePitch = {
  kicker: "Why sigstop",
  lines: [
    { sig: "SIGSTOP", desc: "The one signal a process cannot catch, block, or ignore." },
    { sig: "SIGCONT", desc: "Resumes it exactly where it left off. Registers, memory, open files — all intact." },
  ],
  punch: "That's what a break is. It isn't a restart.",
  body: "You don't avoid breaks because you're busy. You avoid them because you're holding something fragile in your head and you're afraid of dropping it. Stopping doesn't drop it.",
} as const;

export const problem = {
  kicker: "A normal Tuesday",
  headline: "Nothing here looks wrong. That's the problem.",
  sub: "No single hour of this is unreasonable. Look at the column on the right.",
  day: [
    { time: "09:04", label: "Open the editor", detail: "Standup notes still unread", sitting: 0 },
    { time: "09:40", label: "First real commit", detail: "feat/auth-refresh", sitting: 36 },
    { time: "10:15", label: "Still in the same file", detail: "It hasn't got prettier", sitting: 71 },
    { time: "11:02", label: "Something breaks", detail: "It worked on the last commit", sitting: 118 },
    { time: "11:58", label: "Still debugging", detail: "You've added 14 console.logs", sitting: 174 },
    { time: "12:30", label: "Lunch. At the desk.", detail: "One hand on the trackpad", sitting: 206 },
    { time: "13:20", label: "PR review", detail: "4 files, 900 lines, 'LGTM'", sitting: 256 },
    { time: "14:35", label: "Back to the AI", detail: "Accepting diffs you skimmed", sitting: 331 },
    { time: "15:50", label: "It finally works", detail: "You don't know which change fixed it", sitting: 406 },
    { time: "17:10", label: "Just one more thing", detail: "It is never one more thing", sitting: 486 },
  ],
  footer: {
    stat: "8h 06m",
    label: "seated, screen-facing, uninterrupted",
    line: "Your laptop throttled itself twice today to cool down. You didn't.",
  },
} as const;

export const server = {
  kicker: "The comparison nobody enjoys",
  headline: "Your laptop has better monitoring than you do.",
  sub: "Both of you have been up for nine hours. Only one of you is instrumented.",
  rows: [
    { trait: "Runs continuously", server: true, dev: true, devNote: "Yes" },
    { trait: "Handles concurrent load", server: true, dev: true, devNote: "Badly, but yes" },
    { trait: "Active cooling", server: true, dev: false, devNote: "A desk fan, maybe" },
    { trait: "Health checks", server: true, dev: false, devNote: "None" },
    { trait: "Alerting on degradation", server: true, dev: false, devNote: "Ignored" },
    { trait: "Scheduled maintenance", server: true, dev: false, devNote: "\"After this ticket\"" },
    { trait: "Thermal throttling", server: true, dev: false, devNote: "Pushes through" },
    { trait: "Someone gets paged", server: true, dev: false, devNote: "Nobody is on call for you" },
  ],
  punch: "You would never run a service like this. You'd get paged at 3am and you'd fix it by morning.",
} as const;

export const context = {
  kicker: "The difference",
  headline: "It knows what you're doing.",
  sub: "A timer knows one thing: that time passed. sigstop reads which app is in front, how long you've genuinely been active, and whether this is a sane moment to interrupt. Click through and watch the message change.",
  hint: "Pick an app",
} as const;

export const notPomodoro = {
  kicker: "Not another pomodoro",
  headline: "A timer doesn't know you're on a call.",
  sub: "That's the whole thing. One of these reads a clock. The other reads a room.",
  timer: {
    title: "Traditional timer",
    steps: ["25:00 elapsed", "DING", "\"Take a break!\""],
    note: "Fires mid-sentence in your standup. You dismiss it. You dismiss the next one out of habit. You uninstall it on Thursday.",
  },
  sigstop: {
    title: "sigstop",
    steps: [
      "45 min of genuinely active work",
      "What app is in front?",
      "What does that suggest you're doing?",
      "How sure am I, honestly?",
      "Is the mic live? Screen shared? Fullscreen?",
      "Wait for a natural seam",
      "Say something worth reading",
      "SIGCONT — back to work",
    ],
    note: "If the microphone is on, it does not fire. Not \"fires quietly\" — does not fire.",
  },
} as const;

export const beforeAfter = {
  kicker: "Same work, redistributed",
  headline: "It's the same eight hours.",
  sub: "This isn't a productivity claim and it isn't a health claim. It's a shape. The work gets done either way — one version just has seams in it.",
  before: {
    title: "Without",
    items: [
      { t: "09:00", label: "Start", tone: "work" },
      { t: "10:00", label: "Still going", tone: "work" },
      { t: "11:30", label: "Deep in the debugger", tone: "work" },
      { t: "13:00", label: "Notice your back", tone: "strain" },
      { t: "14:00", label: "Keep going anyway", tone: "strain" },
      { t: "16:00", label: "Reading the same line", tone: "strain" },
      { t: "17:30", label: "Diminishing returns", tone: "strain" },
    ],
  },
  after: {
    title: "With sigstop",
    items: [
      { t: "09:00", label: "Start", tone: "work" },
      { t: "09:45", label: "SIGTSTP — a good seam", tone: "break" },
      { t: "09:50", label: "SIGCONT", tone: "work" },
      { t: "10:35", label: "SIGTSTP", tone: "break" },
      { t: "10:40", label: "SIGCONT", tone: "work" },
      { t: "11:25", label: "Skipped — you're on a call", tone: "held" },
      { t: "11:50", label: "SIGTSTP — call ended", tone: "break" },
    ],
  },
  disclaimer:
    "No promises about your health, your focus, or your output. We can't measure those and neither can anyone selling you something. All sigstop does is pick better moments than a timer would.",
} as const;

export const privacy = {
  kicker: "Privacy",
  headline: "Your code stays yours.",
  sub: "You're going to read the source before you run this. Good — that's the point. Here is exactly what it touches, and why you don't have to take our word for any of it.",
  sees: {
    title: "What it reads",
    items: [
      { k: "Which app is in front", v: "Name and bundle id. Nothing inside it." },
      { k: "How long since you touched the keyboard", v: "A number of seconds. Not which keys." },
      { k: "Whether the mic is live", v: "A yes/no from CoreAudio. It never opens a stream." },
      { k: "Session duration", v: "How long you've been going." },
      { k: "Window titles", v: "Only if you grant Accessibility. Off by default." },
    ],
  },
  never: {
    title: "What it cannot read",
    items: [
      "Your source code",
      "Your keystrokes",
      "Your clipboard",
      "Your passwords",
      "Your messages",
      "Your screen",
    ],
  },
  proof: {
    title: "Don't trust it. Check it.",
    sub: "Every claim above is verifiable from a terminal in under a minute.",
    checks: [
      { cmd: "otool -L /Applications/sigstop.app/Contents/MacOS/sigstop", desc: "No networking framework is linked. It cannot phone home because it has no mouth." },
      { cmd: "codesign -d --entitlements - /Applications/sigstop.app", desc: "No network entitlement. No screen recording. No input monitoring." },
      { cmd: "sigstop --doctor", desc: "Prints everything it can currently see about you, and why it believes it." },
      { cmd: "cat ~/Library/Application\\ Support/sigstop/events.jsonl", desc: "Your entire stored history. Plain JSON, one event per line. Read it yourself." },
    ],
  },
  zeroPerm:
    "The app is fully functional with zero permissions granted. Accessibility and git context are upgrades you opt into, never gates. If it demanded permissions to work at all, the promise above would be worth nothing.",
} as const;

export const openSource = {
  kicker: "Open source",
  headline: "Built in the open.",
  sub: "MIT licensed. No paid tier, no \"pro\" version withholding the useful half, no account to create. If it's useful, star it. If it's wrong, open an issue. If you have a better joke, open a PR — the message corpus is a JSON file.",
  cards: [
    { title: "Read the architecture", body: "Four design documents written before a line of Swift. The activity detection doc is honest about what macOS will and won't let an app know.", cta: "docs/", href: "https://github.com/sigstop/sigstop/tree/main/docs" },
    { title: "Add your editor", body: "Support for a new app is one provider file and a bundle id. It requires zero changes to core code — if it did, the extension point would be wrong.", cta: "Providers", href: "https://github.com/sigstop/sigstop/tree/main/app/Sources/SigstopSensors/Providers" },
    { title: "Write a better line", body: "The corpus is plain JSON with structured preconditions. Contribute a joke that only fires when someone's been in Xcode for 90 minutes on a Friday.", cta: "corpus.json", href: "https://github.com/sigstop/sigstop/blob/main/app/Sources/SigstopCore/Message/corpus.json" },
  ],
  ctaPrimary: "Star on GitHub",
  ctaSecondary: "Read CONTRIBUTING",
} as const;

/** Microcopy used as section dividers and small print throughout the page. */
export const asides = [
  "Your chair has opened an issue.",
  "Your spine requested a maintenance window.",
  "CI is green. You should be too.",
  "Ship code. Not yourself.",
  "Commit your code. Not your posture.",
  "human.exe is not responding.",
  "You have been running for 4h12m without yielding.",
  "No process should hold the CPU this long.",
] as const;

export const finalCta = {
  headline: "kill -STOP $(pgrep you)",
  sub: "Five minutes. Nothing is lost. That's the entire pitch.",
  primary: "Download for macOS",
  secondary: "View source",
  meta: "macOS 14+ · Apple Silicon & Intel · 2.1 MB · MIT",
} as const;

export const footer = {
  blurb: "An open-source macOS menu bar app for developers who forget to stop.",
  columns: [
    { title: "Product", links: [ { label: "Download", href: "#download" }, { label: "How it works", href: "#how-it-works" }, { label: "Privacy", href: "#privacy" }, { label: "Changelog", href: "https://github.com/sigstop/sigstop/releases" } ] },
    { title: "Source", links: [ { label: "GitHub", href: "https://github.com/sigstop/sigstop" }, { label: "Architecture docs", href: "https://github.com/sigstop/sigstop/tree/main/docs" }, { label: "Contributing", href: "https://github.com/sigstop/sigstop/blob/main/CONTRIBUTING.md" }, { label: "License (MIT)", href: "https://github.com/sigstop/sigstop/blob/main/LICENSE" } ] },
  ],
  colophon: "No analytics on this page either. It would have been a strange thing to do.",
} as const;
