#!/usr/bin/env python3
"""Fail if the app's source names an API that reads content or runs other code.

docs/PRIVACY.md §2 tells a suspicious reader that the app never reads the clipboard, the
screen or keystrokes, never starts another process and never scripts another app, and its
threat table said a forbidden-symbol guard enforced that. There was no such guard. This is it.

It also refuses the ways to reach the network that leave no networking symbol in the binary:
`Data(contentsOf:)` and its relatives load any URL inside Foundation, `AsyncImage` fetches from a
view, and a class or library loaded by name at runtime is invisible to nm. The one reviewed use,
reading the corpus from the app's own bundle, is allowed by file.

`make verify` checks the same list against the built binary with nm, which is the stronger
proof for what ships. This one reads the source, because an NSEvent monitor is an
Objective-C method call that nm cannot see, and a global monitor is exactly how an app would
start reading keystrokes. The one global monitor the app has watches mouse-downs to close its
panel, so a monitor is allowed only when every event type it asks for is a mouse event.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCES = ROOT / "app/Sources"

FORBIDDEN = {
    r"\bNSPasteboard\b": "reads or writes the clipboard",
    r"\bProcess\b": "starts another process",
    r"\bNSTask\b": "starts another process",
    r"\bposix_spawnp?\b": "starts another process",
    r"\b(execve|execvp|execv|popen)\s*\(": "starts another process",
    r"\bNSAppleScript\b": "scripts another app",
    r"\bOSAScript\b": "scripts another app",
    r"\bAESendMessage\b": "scripts another app",
    r"\bCGEventTapCreate\w*\b": "taps keyboard and mouse input",
    r"\btapCreate\s*\(": "taps keyboard and mouse input",
    r"\bCGEventSourceKeyState\b": "reads which keys are down",
    r"\bkeyState\s*\(": "reads which keys are down",
    r"\bIOHIDManager\w*\b": "reads raw keyboard input",
    r"\bCGWindowListCreateImage\b": "captures the screen",
    r"\bCGDisplayCreateImage\b": "captures the screen",
    r"\bSC(Stream|ShareableContent|ScreenshotManager)\b": "captures the screen",
    r"\bAVCaptureSession\b": "records the camera or microphone",
    r"\bAVAudioRecorder\b": "records the microphone",
    r"\bAVAudioEngine\b": "records the microphone",
    r"\b(URLSession|NSURLSession|NSURLConnection)\b": "opens a network connection outside Sparkle",
    r"\bAsyncImage\b": "fetches a URL from a view",
    r"\b(WKWebView|WebView)\b": "loads web content",
    r"\b(dlopen|dlsym|NSClassFromString|NSSelectorFromString|objc_getClass)\b": "loads code or classes by name at runtime",
    r"\b(Data|NSData|String|NSString|NSImage|CIImage|XMLParser|NSDictionary|NSArray|NSAttributedString)\s*\(\s*contentsOf:":
        "loads a URL, which can be a network URL that no symbol check sees",
}

# Where a flagged call is known and reviewed. The corpus is read from the app's own bundle.
ALLOWED = {
    "contentsOf:": {"app/Sources/SigstopCore/Message/MessageTemplate.swift"},
}

MONITOR = re.compile(r"addGlobalMonitorForEvents\s*\(\s*matching:\s*(\[[^\]]*\]|\.\w+)")
EVENT = re.compile(r"\.(\w+)")

BLOCK = re.compile(r"/\*.*?\*/", re.S)
STRING = re.compile(r'"(?:[^"\\]|\\.)*"')


def code_only(text: str) -> str:
    text = BLOCK.sub("", text)
    text = "\n".join(line.split("//")[0] for line in text.splitlines())
    return STRING.sub('""', text)


def main() -> int:
    failures: list[str] = []
    monitors = 0
    for path in sorted(SOURCES.rglob("*.swift")):
        rel = path.relative_to(ROOT)
        body = code_only(path.read_text())
        for pattern, why in FORBIDDEN.items():
            for match in re.finditer(pattern, body):
                if any(key in pattern and str(rel) in files for key, files in ALLOWED.items()):
                    continue
                line = body.count("\n", 0, match.start()) + 1
                failures.append(f"{rel}:{line}: {match.group(0).strip()} {why}")
        for call in re.finditer(r"addGlobalMonitorForEvents", body):
            line = body.count("\n", 0, call.start()) + 1
            mask = MONITOR.match(body, call.start())
            if not mask:
                failures.append(f"{rel}:{line}: a global event monitor whose mask this check cannot read")
                continue
            kinds = EVENT.findall(mask.group(1))
            if not kinds or any("Mouse" not in kind for kind in kinds):
                failures.append(f"{rel}:{line}: a global event monitor for {', '.join(kinds)}; "
                                "only mouse events are allowed")
            monitors += 1

    if failures:
        print("::error::the app names an API that reads content or runs other code")
        for f in failures:
            print(f"  {f}")
        print("  docs/PRIVACY.md §2 promises none of these. Changing that is its own PR, "
              "argued in the rules table in CONTRIBUTING.md first.")
        return 1

    print(f"forbidden APIs: none in app/Sources; {monitors} global event monitor(s), mouse events only")
    return 0


if __name__ == "__main__":
    sys.exit(main())
