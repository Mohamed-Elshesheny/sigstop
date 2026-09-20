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
      "Is a mic live? Is a camera live? Fullscreen?",
      "Wait for a natural seam",
      "Say something worth reading",
      "SIGCONT, back to work",
    ],
    kinds: ["clock", "signal", "inference", "honesty", "veto", "timing", "message", "resume"],
    note: "If a microphone or a camera is running, it does not fire. Not \"fires quietly\", does not fire. Both are a yes/no device flag, read without a permission prompt and without opening a stream.",
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
      { t: "14:55", label: "Held, your camera is on", tone: "held" },
      { t: "15:30", label: "SIGTSTP, the camera went off", tone: "break" },
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
    { tone: "held", label: "Held", desc: "A break came due and was deliberately not fired: a microphone or a camera was running, or one had just stopped and the call had not. This is the feature, not a miss." },
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
      { k: "Whether a mic is live", v: "A yes/no from CoreAudio. It never opens a stream." },
      { k: "Whether a camera is live", v: "A yes/no from CoreMediaIO. It never opens a stream, and macOS asks you for nothing." },
      { k: "Session duration", v: "How long you've been going." },
      { k: "Window titles", v: "Only if you grant Accessibility. Off by default." },
    ],
    note: "Six signals. That is the entire inventory, there is no seventh one further down the page.",
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
    note: "Not \"we promise not to look.\" There is no code path that could. Reading any of these needs a permission the app never requests and an entitlement it was never signed with. It costs something, and here is the bill: because it never reads your screen, it cannot tell that you are sharing it. A live mic or camera is what it holds a break back on, and a silent screen share is the case it misses.",
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
      body: "Mic live, camera live, fullscreen? Then it does not fire at all. Otherwise it waits for an app switch or a quiet moment, within a bounded window.",
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

/**
 * The ten badges, named exactly as `SigstopCore/Badges/Badge.swift` names them,
 * and carrying the same motif ids, so a mark on the page and a mark in the app
 * are the same object under the same name.
 *
 * `earned` is the line the app shows once a badge is yours. It is here rather
 * than only in Settings because it is where the set does its real work: it says
 * what the mark means, in the product's voice, without ever telling the reader
 * they have been good.
 */
export const badges = {
  kicker: "The ten",
  headline: "There is a shelf, and it cannot be taken off you.",
  sub: "Ten badges, kept in Settings and never in a prompt. Every one is arithmetic over the log already on disk, so none of them made the app watch you any more closely than it already did.",
  items: [
    {
      name: "[1]+ Stopped",
      motif: "job-line",
      earns: "Take one break.",
      earned: "It is what the shell prints when a job is suspended, and the job is fine: registers, memory, all of it still there.",
    },
    {
      name: "ten down",
      motif: "descent",
      earns: "Ten breaks in total.",
      earned: "Ten times you took your own priority down a step, and nobody else had to do it for you.",
    },
    {
      name: "nothing blocked",
      motif: "lifted-gate",
      earns: "One day where every break offered was taken.",
      earned: "Nothing deferred, nothing pending, nothing in the way.",
    },
    {
      name: "always halts",
      motif: "tombstone",
      earns: "Ten days where every break offered was taken.",
      earned: "Whether an arbitrary program halts is undecidable. You are not an arbitrary program, and this is ten days of evidence.",
    },
    {
      name: "no handler",
      motif: "straight-through",
      earns: "Accept five prompts within fifteen seconds of being asked.",
      earned: "Nothing caught them, nothing thought about them, the default just ran.",
    },
    {
      name: "uncatchable",
      motif: "escalation",
      earns: "Let one prompt climb all four rungs to SIGSTOP.",
      earned: "The top rung cannot be caught, blocked or ignored by anybody, ever, and the kernel will not even let you try to install a handler for it.",
    },
    {
      name: "yielded",
      motif: "handoff",
      earns: "A day of at least four hours where no single stretch passed an hour.",
      earned: "You handed the slot back before anything had to take it from you.",
    },
    {
      name: "early return",
      motif: "early-exit",
      earns: "Take a break before 10:00 on five separate days.",
      earned: "Out before the branching got complicated.",
    },
    {
      name: "still running",
      motif: "detached",
      earns: "Take a break after 01:00 on five separate days.",
      earned: "The terminal is closed and the link to it is cut: the job is the thing still running, and you are the part that stopped.",
    },
    {
      name: "[100]+ Stopped",
      motif: "job-line-full",
      earns: "A hundred breaks in total.",
      earned: "The shell prints the same line it printed the first time. Only the number in the brackets moved.",
    },
  ],
  /* The two states, offered as a control so a reader can flip the whole wall
     and watch what does and does not survive. */
  view: {
    label: "Show the shelf as",
    earned: "earned",
    locked: "not yet",
    note: {
      earned:
        "One amber per mark, and only on the part that carries the meaning: the suspended job between the brackets, the arm swung out of the road, the rung nothing can catch.",
      locked:
        "The same objects, every line in the same place at the same weight. Only the amber is gone, and the empty socket is now the brightest thing in the mark, so your eye lands on what is missing. Nothing is crossed out, nothing is greyed to a stub, and nothing anywhere is a padlock.",
    },
  },
  chip: { earned: "yours", locked: "not yet" },
  rules: [
    { k: "Nothing expires", v: "Miss a day, miss a month. A badge records something that happened and there is no number to protect." },
    { k: "Nothing can go down", v: "There is no counter to lose, so there is nothing here to hold hostage." },
    { k: "Nothing rewards working longer", v: "The app exists to interrupt long stretches. Paying you for one would have it arguing with itself, and yielded is explicitly for a day where nothing ran past the hour." },
  ],
  note: "No levels, no tiers, no points, no shareable card. If that sounds like a thin version of what other apps do here, it is, deliberately.",
  marksNote: "The marks are the app's, drawn from the same coordinates. Ten of them and ten objects: the set is meant to be told apart by silhouette alone, in a settings list, without reading a single title.",
} as const;

/**
 * Meetings. The section that answers the objection that decides installs:
 * "will this thing full-screen me while I am sharing my screen to twelve people."
 *
 * Every claim here is checkable against `InterruptionPolicy.hardBlock`,
 * `MeetingLatch` and docs/BREAK-DECISION.md §7.8, and the section is written
 * around the limit rather than around the feature: the app cannot see a screen
 * share, that gap is stated in the same size type as the capability, and the
 * reason it is not closed (the Screen Recording grant) is the reason anyone
 * should trust the rest of the page.
 */
export const meetings = {
  kicker: "Meetings",
  headline: "It does not fire in your standup.",
  sub: "This is the objection that decides whether you install a break app at all: a full screen prompt landing while twelve people are watching your screen. So here is the whole mechanism, including the case it misses.",

  ladder: {
    title: "Four states. Only two of them are allowed to be certain.",
    note: "Only a device bit may block. Everything softer than a device bit may delay a prompt and nothing else, which is the difference between this and a mute button.",
    verdicts: { block: "cannot fire", hold: "held", defer: "delayed only" },
    items: [
      {
        state: "A microphone is running",
        verdict: "block",
        source: "kAudioDevicePropertyDeviceIsRunningSomewhere",
        body: "A yes or no bit on the audio device. No Microphone permission, no prompt, no stream ever opened, and nothing that could be heard if one were. While that bit is set nothing is delivered on any channel, at any rung of the ladder.",
      },
      {
        state: "A camera is running",
        verdict: "block",
        source: "kCMIODevicePropertyDeviceIsRunningSomewhere",
        body: "The same shape of bit from CoreMediaIO, at the same price of zero. This is the camera on, microphone muted case, and it used to be the obvious hole.",
      },
      {
        state: "One of those two stopped, recently",
        verdict: "hold",
        source: "the same two bits, and arithmetic on them",
        body: "Muting looks exactly like leaving, so the app does not guess between them. A device that ran continuously for 45 seconds and then stopped holds the prompt for eight minutes on that fact alone, and for up to twenty while the app it was attributed to is still open.",
      },
      {
        state: "Something resembles a call, but nothing has proved it",
        verdict: "defer",
        source: "a guess, and it is handled as one",
        body: "Capture that has not lasted long enough yet, or the app launching next to a Zoom that was already running. Neither is a fact, so neither blocks. They buy time and the time runs out.",
      },
    ],
  },

  mute: {
    title: "The hard case is mute",
    sub: "Nothing on the machine is live during a call you are muted on. The bit drops the instant you press it, which is when a timer would go off. One real call, and what the app does with it:",
    phases: [
      { t: "14:02", tone: "live", label: "Zoom takes the microphone", body: "The device bit goes true. Forty five seconds of it in a row rules out Siri, a dictated sentence and a microphone test." },
      { t: "14:31", tone: "mute", label: "You mute", body: "Every live signal on this Mac goes quiet at once. The call did not end. Nothing at this tier can tell the difference." },
      { t: "14:39", tone: "hold", label: "Eight minutes on the fact", body: "Unconditional, and it needs to know nothing about Zoom. Delete every line of app matching and this part remains." },
      { t: "14:51", tone: "hold", label: "Twelve more, because Zoom is still open", body: "The app it named is running, so the hold is extended. Twenty minutes is the ceiling and it is never longer." },
    ],
    close: "At 14:51 the hold ends and the prompt is allowed through. Quit Zoom before then and it ends ninety seconds later instead, because the call is over.",
  },

  bounds: {
    title: "Every hold is bounded, and it is never silent about one",
    items: [
      { k: "20 min", v: "The longest any single hold can run. The last twelve of those need the named app to still be running." },
      { k: "90 min", v: "Held time in one episode. Past that the app is wrong about something, so it stops holding and says which ceiling it hit." },
      { k: "3 h", v: "Held time in one day, after which it stops until tomorrow." },
      { k: "1 click", v: "The menu bar carries its own state while it holds, names the fact and the closing time, and offers \"Not in a meeting\" the whole time." },
    ],
    note: "No hold survives a relaunch. A hold restored from disk is a suppression that can outlive the bug that created it, and quitting the app has to stay the crude escape hatch it is. The day's running total does survive, because that number can only ever make the app less willing to hold, never more.",
  },

  gap: {
    title: "What it cannot see",
    headline: "A screen share.",
    body: "There is no permission-free way to know a display is being captured. CGDisplayIsCaptured has been deprecated since macOS 10.9 and no longer compiles, CoreMediaIO enumerates no display capture device, and ScreenCaptureKit requires the Screen Recording grant, which is the exact permission that would let this app read your screen. It is not going to ask for it. So a silent screen share, muted and camera off, is a case this misses, and the block that was supposed to cover it never fires on anybody's machine.",
    alsoTitle: "Two more, stated rather than buried",
    also: [
      "A call you joined muted with the camera off and never unmuted. No capture fact ever happens, so there is nothing to hold on to.",
      "Google Meet in Safari. Safari routes page audio through one process that serves every WebKit client, so it names no app. A live microphone still blocks. What is lost is the name, and with it the longer hold after you mute.",
    ],
    answerLabel: "The answer to all three",
    answer: "One line in the menu: I'm in a meeting. It holds everything for two hours and then expires. A hold that never expires is a mute button, and a mute button is how an app like this quietly stops working.",
  },

  apps: {
    title: "The four people actually ask about",
    note: "Matched by bundle id prefix, because macOS attributes audio to helper processes and not to apps. The list is in the source, each entry marked verified or not, and it is the only thing the app learns: which app holds the microphone, never what is being said, typed or shown in it.",
    items: [
      { name: "Slack", how: "Named directly by CoreAudio's process table. Blocks while live, and anchors the hold after you mute." },
      { name: "Microsoft Teams", how: "Its media path is a separate process that does not sit under the Teams bundle prefix at all, which is why matching is by prefix against a list you can read and correct." },
      { name: "Zoom", how: "Named the same way. It also holds the device briefly in a waiting room and just after a call, which the hold absorbs rather than tries to out-guess." },
      { name: "Google Meet", how: "A browser tab, not an app. In Chrome, Arc, Brave, Edge and Firefox the microphone attributes to the browser, so the tab can be anchored to it. In Safari it names nothing, and the plain device bit carries the block on its own." },
    ],
  },

  cost: {
    title: "A two hour call costs the cycle nothing",
    items: [
      { k: "Nothing queues up", v: "While it is blocked the deferral clock is paused and nothing is emitted on any channel. The cycle is preserved, not spent." },
      { k: "Nothing lands late", v: "A cycle that spends an hour blocked is abandoned rather than fired. It re-arms after ten minutes of real work, so you are not prompted the second you say goodbye." },
      { k: "Nothing you were shown counts against you", v: "A prompt already on screen when a call starts is withdrawn, and its timer is cleared with it. You are not charged with ignoring something you were never allowed to answer." },
    ],
  },
} as const;
