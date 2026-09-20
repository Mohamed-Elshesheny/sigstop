/**
 * The interactive "It knows what you're doing" section.
 *
 * Each entry mirrors what the real MessageEngine would produce for that context:
 * an inferred activity, an honest confidence, the evidence behind it, and a line
 * chosen for that situation. The confidences here are the same ones the app uses —
 * a browser with no window-title access really is only ~0.40, and the demo says so
 * rather than flattering itself.
 */

export type AppKey =
  | "cursor" | "vscode" | "terminal" | "github" | "slack" | "xcode" | "docker" | "figma";

export interface AppDemo {
  key: AppKey;
  name: string;
  /** Monospace glyph used in place of a logo — we don't ship other people's marks. */
  glyph: string;
  accent: string;
  activity: string;
  confidence: number;
  minutes: number;
  evidence: string[];
  messages: { tone: "friendly" | "sarcastic" | "roast"; text: string }[];
}

export const appDemos: AppDemo[] = [
  {
    key: "cursor",
    name: "Cursor",
    glyph: "⌘",
    accent: "var(--color-suspend)",
    activity: "AI_CODING",
    confidence: 0.91,
    minutes: 52,
    evidence: [
      "Frontmost app is Cursor (exact bundle id match)",
      "52 min continuous active input",
      "No microphone activity",
    ],
    messages: [
      { tone: "friendly", text: "You've been in Cursor for 52 minutes. Claude will still be here in five." },
      { tone: "sarcastic", text: "Claude is thinking. You could think somewhere else for a bit." },
      { tone: "roast", text: "You've accepted four diffs in a row without reading one. That's not pair programming, that's a hostage situation." },
    ],
  },
  {
    key: "vscode",
    name: "VS Code",
    glyph: "◧",
    accent: "#4a9eff",
    activity: "CODING",
    confidence: 0.9,
    minutes: 47,
    evidence: [
      "Frontmost app is VS Code (exact bundle id match)",
      "Same window title for 45 min",
      "47 min continuous active input",
    ],
    messages: [
      { tone: "friendly", text: "Same file for 45 minutes. Worth a lap around the room." },
      { tone: "sarcastic", text: "You've been looking at the same function for 45 minutes. It is not going to get prettier." },
      { tone: "roast", text: "That function has survived 45 minutes of your staring. It has won. Go outside." },
    ],
  },
  {
    key: "terminal",
    name: "iTerm2",
    glyph: "❯",
    accent: "var(--color-running)",
    activity: "TERMINAL_WORK",
    confidence: 0.85,
    minutes: 38,
    evidence: [
      "Frontmost app is iTerm2 (exact bundle id match)",
      "38 min continuous active input",
      "Cannot distinguish building from scripting — reporting the parent class",
    ],
    messages: [
      { tone: "friendly", text: "Whatever you're compiling can wait five minutes." },
      { tone: "sarcastic", text: "Your terminal has been staring back at you for 38 minutes. Neither of you has blinked." },
      { tone: "roast", text: "You've run the same command three times expecting a different result. There's a word for that. Go get water." },
    ],
  },
  {
    key: "github",
    name: "GitHub",
    glyph: "◈",
    accent: "#a371f7",
    activity: "CODE_REVIEW",
    confidence: 0.65,
    minutes: 41,
    evidence: [
      "Frontmost app is a browser",
      "Window title matches a code-host pattern (Accessibility granted)",
      "Confidence capped: a title is a heuristic, not a fact",
    ],
    messages: [
      { tone: "friendly", text: "That PR will still be open in five minutes." },
      { tone: "sarcastic", text: "LGTM. Now go stand up." },
      { tone: "roast", text: "You've reviewed 900 lines in eleven minutes. We both know what happened there. Take a real break and do it properly after." },
    ],
  },
  {
    key: "xcode",
    name: "Xcode",
    glyph: "◆",
    accent: "#4a9eff",
    activity: "DEBUGGING",
    confidence: 0.8,
    minutes: 73,
    evidence: [
      "Frontmost app is Xcode (exact bundle id match)",
      "Debug console focused (Accessibility granted)",
      "73 min continuous active input",
    ],
    messages: [
      { tone: "friendly", text: "73 minutes of debugging. Fresh eyes find it faster. Usually in the shower." },
      { tone: "sarcastic", text: "The bug isn't going anywhere. Your chair, however, should." },
      { tone: "roast", text: "You've been debugging for 73 minutes. At this point it's worth considering that the bug is sitting in your chair." },
    ],
  },
  {
    key: "slack",
    name: "Slack",
    glyph: "◇",
    accent: "#e01e5a",
    activity: "COMMUNICATION",
    confidence: 0.88,
    minutes: 22,
    evidence: [
      "Frontmost app is Slack (exact bundle id match)",
      "Microphone is NOT active — this is typing, not a call",
      "22 min continuous active input",
    ],
    messages: [
      { tone: "friendly", text: "You've been typing in Slack for 22 minutes. That's a meeting with extra steps." },
      { tone: "sarcastic", text: "Three people are typing. None of them are going to say anything. Go stretch." },
      { tone: "roast", text: "You have written and deleted that message four times. Send it or stand up. Ideally stand up." },
    ],
  },
  {
    key: "docker",
    name: "Docker",
    glyph: "▣",
    accent: "#4a9eff",
    activity: "TERMINAL_WORK",
    confidence: 0.72,
    minutes: 34,
    evidence: [
      "Frontmost app is Docker Desktop (exact bundle id match)",
      "Cannot tell building from waiting — reporting the parent class",
    ],
    messages: [
      { tone: "friendly", text: "It's still building. That's a free five minutes, take it." },
      { tone: "sarcastic", text: "You are watching a progress bar. You have been promoted to spectator. Go be a spectator somewhere with a window." },
      { tone: "roast", text: "Nothing you do in the next five minutes will make that image build faster. Nothing. Go." },
    ],
  },
  {
    key: "figma",
    name: "Figma",
    glyph: "◐",
    accent: "#a371f7",
    activity: "UNKNOWN",
    confidence: 0.35,
    minutes: 29,
    evidence: [
      "Frontmost app is Figma (exact bundle id match)",
      "No reliable signal for what you're doing inside it",
      "Below the confidence threshold — the app will NOT name an activity",
    ],
    messages: [
      { tone: "friendly", text: "29 minutes at the screen. No idea what you're doing in there, but it can wait." },
      { tone: "sarcastic", text: "I genuinely don't know what you're doing in Figma. I do know you haven't moved in 29 minutes." },
      { tone: "roast", text: "I'm not going to pretend I know what's happening in Figma. I'm still right about the 29 minutes." },
    ],
  },
];

/** Escalation ladder — POSIX does the writing for us. */
export const escalation = [
  { signal: "SIGTSTP", level: 1, note: "Catchable. You're allowed to ignore this one.", text: "You've been going 45 minutes. Good a time as any." },
  { signal: "SIGINT", level: 2, note: "Catchable, but ignoring it is rude.", text: "Still going. Your chair is starting to think this arrangement is permanent." },
  { signal: "SIGTERM", level: 3, note: "This is your warning.", text: "Ninety minutes. Your laptop has thermally throttled twice. You have not." },
  { signal: "SIGSTOP", level: 4, note: "Cannot be caught, blocked, or ignored.", text: "Declaring a P1. The affected service is you. Five minutes. Go." },
] as const;
