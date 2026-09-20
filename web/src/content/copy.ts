/**
 * All landing-page prose lives here so the writing can be reviewed as writing,
 * and so no component has to be edited to fix a sentence.
 *
 * Voice: deadpan accomplice. The app is on your side and funny about it.
 * It is NOT a warden. "Cannot be ignored" is a bluff the reader is in on ,
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
  repo: "https://github.com/Mohamed-Elshesheny/sigstop",
  tagline: "Suspend. Resume. Nothing lost.",
  description:
    "An open-source macOS menu bar app that notices what you're actually working on and tells you to step away, in a language you'll recognise.",
} as const;

export const nav = [
  { label: "Product", href: "#product" },
  { label: "How it works", href: "#how-it-works" },
  { label: "Privacy", href: "#privacy" },
  { label: "Open source", href: "#open-source" },
] as const;

export const hero = {
  headline: ["You're a developer.", "Not a server."],
  sub: "You spend your day debugging, reviewing PRs, arguing with an AI, and staring at the same forty lines. sigstop watches your workflow, never your code, and works out when it's actually a good moment to stop.",
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
    { sig: "SIGCONT", desc: "Resumes it exactly where it left off. Registers, memory, open files, all intact." },
  ],
  punch: "That's what a break is. It isn't a restart.",
  body: "You don't avoid breaks because you're busy. You avoid them because you're holding something fragile in your head and you're afraid of dropping it. Stopping doesn't drop it.",
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
    meta: "Three steps. None of them are about you.",
    steps: ["25:00 elapsed", "DING", "\"Take a break!\""],
    kinds: ["clock", "output", "output"],
    note: "Fires mid-sentence in your standup. You dismiss it. You dismiss the next one out of habit. You uninstall it on Thursday.",
  },
  sigstop: {
    title: "sigstop",
    meta: "Eight steps. Four of them are allowed to decide you should not be interrupted at all.",
    steps: [
      "45 min of genuinely active work",
      "What app is in front?",
      "What does that suggest you're doing?",
      "How sure am I, honestly?",
      "Is the mic live? Screen shared? Fullscreen?",
      "Wait for a natural seam",
      "Say something worth reading",
      "SIGCONT, back to work",
    ],
    kinds: ["clock", "signal", "inference", "honesty", "veto", "timing", "message", "resume"],
    note: "If the microphone is on, it does not fire. Not \"fires quietly\", does not fire.",
  },
  /** Stage labels for the flow diagram. Keys match the `kinds` arrays above. */
  stageLabels: {
    clock: "clock",
    output: "output",
    signal: "signal",
    inference: "inference",
    honesty: "confidence",
    veto: "veto",
    timing: "timing",
    message: "message",
    resume: "resume",
  },
  gateLabel: "can stop here",
  vetoLabel: "hard veto",
  countLabel: "steps",
} as const;

export const beforeAfter = {
  kicker: "Same work, redistributed",
  headline: "It's the same eight hours.",
  sub: "This isn't a productivity claim and it isn't a health claim. It's a shape. The work gets done either way, one version just has seams in it.",
  scaleNote: "One day, one clock. Both columns are drawn to the same scale.",
  before: {
    title: "Without",
    meta: "One block. Nothing in the system is watching it get longer.",
    end: "18:00",
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
    meta: "The same block, with seams cut into it, and two it deliberately refused to cut.",
    end: "18:00",
    items: [
      { t: "09:00", label: "Start", tone: "work" },
      { t: "09:45", label: "SIGTSTP, a good seam", tone: "break" },
      { t: "09:50", label: "SIGCONT", tone: "work" },
      { t: "10:35", label: "SIGTSTP", tone: "break" },
      { t: "10:40", label: "SIGCONT", tone: "work" },
      { t: "11:25", label: "Skipped, you're on a call", tone: "held" },
      { t: "11:50", label: "SIGTSTP, call ended", tone: "break" },
      { t: "11:55", label: "SIGCONT", tone: "work" },
      { t: "12:40", label: "Lunch. Away from the desk.", tone: "break" },
      { t: "13:20", label: "SIGCONT", tone: "work" },
      { t: "14:05", label: "SIGTSTP", tone: "break" },
      { t: "14:10", label: "SIGCONT", tone: "work" },
      { t: "14:55", label: "Held, your screen is shared", tone: "held" },
      { t: "15:30", label: "SIGTSTP, the demo ended", tone: "break" },
      { t: "15:35", label: "SIGCONT", tone: "work" },
      { t: "16:20", label: "SIGTSTP", tone: "break" },
      { t: "16:25", label: "SIGCONT", tone: "work" },
    ],
  },
  /** The four tones a timeline block can carry. "held" is a feature, not a miss. */
  legend: [
    { tone: "work", label: "Running", desc: "A process doing what it is supposed to be doing." },
    { tone: "strain", label: "Still running", desc: "The same work, hours later. Nothing in the loop notices the difference." },
    { tone: "break", label: "Seam", desc: "SIGTSTP, then SIGCONT. The stack is still there when you get back." },
    { tone: "held", label: "Held", desc: "A break came due and was deliberately not fired, mic live, or screen shared. This is the feature, not a miss." },
  ],
  stats: { span: "span", seams: "seams", away: "away from the desk", held: "held back", unbroken: "unbroken" },
  disclaimerLabel: "What this diagram is not claiming",
  disclaimer:
    "No promises about your health, your focus, or your output. We can't measure those and neither can anyone selling you something. All sigstop does is pick better moments than a timer would.",
} as const;

export const privacy = {
  kicker: "Privacy",
  headline: "Your code stays yours.",
  sub: "You're going to read the source before you run this. Good, that's the point. Here is exactly what it touches, and why you don't have to take our word for any of it.",
  sees: {
    title: "What it reads",
    items: [
      { k: "Which app is in front", v: "Name and bundle id. Nothing inside it." },
      { k: "How long since you touched the keyboard", v: "A number of seconds. Not which keys." },
      { k: "Whether the mic is live", v: "A yes/no from CoreAudio. It never opens a stream." },
      { k: "Session duration", v: "How long you've been going." },
      { k: "Window titles", v: "Only if you grant Accessibility. Off by default." },
    ],
    note: "Five signals. That is the entire inventory, there is no sixth one further down the page.",
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
    note: "Not \"we promise not to look.\" There is no code path that could. Reading any of these needs a permission the app never requests and an entitlement it was never signed with.",
  },
  proof: {
    title: "Don't trust it. Check it.",
    sub: "Every claim above is verifiable from a terminal in under a minute.",
    terminalTitle: "zsh, verify sigstop",
    provesLabel: "proves",
    copyLabel: "Copy",
    copiedLabel: "Copied",
    copyFailLabel: "Copy failed. Select the line and copy it yourself, which you were probably going to do anyway.",
    checks: [
      { cmd: "nm -u /Applications/sigstop.app/Contents/MacOS/sigstop | grep -E 'NSURLSession|_socket|getaddrinfo'", desc: "Silence. The app's own binary references no networking at all. Every byte of network code is in Sparkle." },
      { cmd: "ls /Applications/sigstop.app/Contents/Frameworks", desc: "Sparkle.framework, and nothing else. One dependency, named, versioned, diffable." },
      { cmd: "plutil -p /Applications/sigstop.app/Contents/Info.plist | grep SU", desc: "The one URL it can fetch, the key it verifies updates against, and automatic checks set to false." },
      { cmd: "sigstop --doctor", desc: "Prints everything it can currently see about you, and why it believes it." },
      { cmd: "cat ~/Library/Application\\ Support/sigstop/events.jsonl", desc: "Your entire stored history. Plain JSON, one event per line. Read it yourself." },
    ],
  },
    zeroPermLabel: "Zero permissions",
  zeroPerm:
    "The app is fully functional with zero permissions granted. Accessibility and git context are upgrades you opt into, never gates. If it demanded permissions to work at all, the promise above would be worth nothing.",
} as const;

export const openSource = {
  kicker: "Open source",
  headline: "Built in the open.",
  sub: "Apache-2.0 licensed. No paid tier, no \"pro\" version withholding the useful half, no account to create. If it's useful, star it. If it's wrong, open an issue. If you have a better joke, open a PR, the message corpus is a JSON file.",
  cards: [
    { title: "Read the architecture", body: "Four design documents written before a line of Swift. The activity detection doc is honest about what macOS will and won't let an app know.", cta: "docs/", href: "https://github.com/Mohamed-Elshesheny/sigstop/tree/main/docs" },
    { title: "Add your editor", body: "Support for a new app is one provider file and a bundle id. It requires zero changes to core code, if it did, the extension point would be wrong.", cta: "Providers", href: "https://github.com/Mohamed-Elshesheny/sigstop/tree/main/app/Sources/SigstopSensors/Providers" },
    { title: "Write a better line", body: "The corpus is plain JSON with structured preconditions. Contribute a joke that only fires when someone's been in Xcode for 90 minutes on a Friday.", cta: "corpus.json", href: "https://github.com/Mohamed-Elshesheny/sigstop/blob/main/app/Sources/SigstopCore/Message/corpus.json" },
  ],
  facts: [
    { k: "Language", v: "Swift 6" },
    { k: "License", v: "Apache-2.0" },
    { k: "Minimum", v: "macOS 14" },
    { k: "Bundle", v: "7.5 MB, 2.8 of it Sparkle" },
    { k: "Dependencies", v: "1, and you can name it" },
  ],
  factsNote:
    "Facts, not social proof. A star count tells you how a repo trended, not whether the code does what it says.",
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
  prompt: "$",
  headline: "kill -STOP $(pgrep you)",
  sub: "Five minutes. Nothing is lost. That's the entire pitch.",
  primary: "Download for macOS",
  secondary: "View source",
  meta: "macOS 14+ · Apple Silicon & Intel · 2.1 MB · Apache-2.0",
} as const;

export const footer = {
  blurb: "An open-source macOS menu bar app for developers who forget to stop.",
  columns: [
    { title: "Product", links: [ { label: "Download", href: "#download" }, { label: "How it works", href: "#how-it-works" }, { label: "Privacy", href: "#privacy" }, { label: "Changelog", href: "https://github.com/Mohamed-Elshesheny/sigstop/releases" } ] },
    { title: "Source", links: [ { label: "GitHub", href: "https://github.com/Mohamed-Elshesheny/sigstop" }, { label: "Architecture docs", href: "https://github.com/Mohamed-Elshesheny/sigstop/tree/main/docs" }, { label: "Contributing", href: "https://github.com/Mohamed-Elshesheny/sigstop/blob/main/CONTRIBUTING.md" }, { label: "License (Apache-2.0)", href: "https://github.com/Mohamed-Elshesheny/sigstop/blob/main/LICENSE" } ] },
  ],
  colophon: "No analytics on this page either. It would have been a strange thing to do.",
} as const;

/**
 * The product demo. The character is the stage for it: the session state, the
 * posture and the menu bar icon are all driven by the same step index, so the
 * three never disagree.
 */
export const productDemo = {
  kicker: "The whole loop",
  headline: "Forty five minutes, then five.",
  sub: "This is the entire product. There is no dashboard to configure, no streak to maintain, and nothing to log in to. There are ten badges, kept out of the way in Settings: none of them expires, none of them can go down, and none of them rewards working longer.",
  steps: [
    {
      id: "work",
      label: "Working",
      sig: "state R",
      minutes: 12,
      pose: "typing",
      title: "It watches the app, not the file",
      body: "Frontmost application and how long since you last touched the keyboard. That is the whole input at this stage.",
    },
    {
      id: "long",
      label: "Still working",
      sig: "state R",
      minutes: 44,
      pose: "slumped",
      title: "Continuous active work, not elapsed time",
      body: "A coffee run pauses the clock. Reading for ninety seconds does not. The number is time you were actually at it.",
    },
    {
      id: "due",
      label: "Break due",
      sig: "SIGTSTP",
      minutes: 45,
      pose: "slumped",
      title: "It waits for a seam",
      body: "Mic live, screen shared, fullscreen? Then it does not fire at all. Otherwise it waits for an app switch or a quiet moment, within a bounded window.",
    },
    {
      id: "break",
      label: "Break",
      sig: "state T",
      minutes: 0,
      pose: "stretching",
      title: "Five minutes",
      body: "Stand up. Look at something further away than your screen. The timer does not judge you if you come back early.",
    },
    {
      id: "resume",
      label: "Back",
      sig: "SIGCONT",
      minutes: 1,
      pose: "typing",
      title: "Nothing was lost",
      body: "Same branch, same file, same half finished thought. That was always the actual objection, and it is the one the name answers.",
    },
  ],
  autoplayNote: "Playing. Click any step to hold it.",
  pausedNote: "Held. Click again to resume.",
} as const;

/**
 * The comparison. Written to be checkable rather than flattering: every column
 * is a real category of tool, every row is something you can verify yourself,
 * and the rows sigstop loses are left in. A comparison table where the author
 * wins every row is an advert, and developers grade it as one.
 */
export const comparison = {
  kicker: "Where this sits",
  headline: "We are not the first thing that tells you to take a break.",
  sub: "We are the only one that looks at what you are doing first. Here is the honest version, including the parts we lose.",
  columns: [
    { key: "sigstop", label: "sigstop", note: "this", highlight: true },
    { key: "pomodoro", label: "Pomodoro timers", note: "the 25 minute crowd", highlight: false },
    { key: "wellness", label: "Wellness apps", note: "streaks to protect, a subscription", highlight: false },
    { key: "nothing", label: "Your current setup", note: "nothing", highlight: false },
  ],
  rows: [
    { trait: "Knows which app you are in", sigstop: "yes", pomodoro: "no", wellness: "some", nothing: "no" },
    { trait: "Knows you are on a call and shuts up", sigstop: "yes", pomodoro: "no", wellness: "no", nothing: "yes" },
    { trait: "Tells you why it believes that", sigstop: "yes", pomodoro: "n/a", wellness: "no", nothing: "n/a" },
    { trait: "Admits when it does not know", sigstop: "yes", pomodoro: "n/a", wellness: "no", nothing: "n/a" },
    { trait: "Works with zero permissions granted", sigstop: "yes", pomodoro: "yes", wellness: "no", nothing: "yes" },
    { trait: "Sends nothing about you, anywhere", sigstop: "yes", pomodoro: "some", wellness: "no", nothing: "yes" },
    { trait: "Its only connection is an update check you triggered", sigstop: "yes", pomodoro: "some", wellness: "no", nothing: "n/a" },
    { trait: "Verifies every update against a key inside the app", sigstop: "yes", pomodoro: "some", wellness: "some", nothing: "n/a" },
    { trait: "Source you can read and fork", sigstop: "yes", pomodoro: "some", wellness: "no", nothing: "n/a" },
    { trait: "Free, no account, no tier", sigstop: "yes", pomodoro: "some", wellness: "no", nothing: "yes" },
    { trait: "Escalates instead of nagging identically", sigstop: "yes", pomodoro: "no", wellness: "no", nothing: "no" },
    { trait: "Runs on Windows and Linux", sigstop: "no", pomodoro: "yes", wellness: "yes", nothing: "yes" },
    { trait: "Keeps a streak you can lose", sigstop: "no", pomodoro: "no", wellness: "yes", nothing: "no" },
    { trait: "Tracks anything for your manager", sigstop: "no", pomodoro: "no", wellness: "some", nothing: "no" },
    { trait: "Will make you a better engineer", sigstop: "yes", pomodoro: "no", wellness: "no", nothing: "no" },
  ],
  legend: {
    yes: "yes",
    no: "no",
    some: "sometimes",
    "n/a": "not applicable",
  },

  } as const;
