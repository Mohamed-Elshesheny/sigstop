# Message Engine & Humor System

Design document. Covers the selection model, slot filling, recency ledger, tone tiers and
safety rails, escalation, confidence gating, and the message-pack corpus format.

Throughout, "the app" means the macOS break-reminder application. No product name appears in
this document, in the engine, or in the corpus — packs are portable.

**Scope boundary:** the app tells jokes. It does not make health claims. Nothing in the corpus
asserts a physiological, medical, or psychological effect of taking a break, and the lint in
§8 enforces that. The value proposition is "a timer that is funny enough that you don't kill
it in week two," not "a timer that fixes your body."

---

## 0. The problem this solves

A break reminder gets uninstalled when it becomes noise. It becomes noise when it is
predictable. The single design requirement that drives everything below:

> The same break event, fired twice, must produce meaningfully different output, and the
> difference must be *earned by context* rather than by a coin flip.

So the engine is a small rules system over a typed context, not `messages.randomElement()`.
Concretely, the same 90-minute break event produces:

| Context | Selected line |
|---|---|
| Cursor, `ai_pairing`, conf 0.91, level 1 | "Tab. Tab. Tab. Tab. You are 200 lines into a file you have never read..." |
| Cursor, `ai_pairing`, conf 0.91, level 3, 3 skips | "SKIP COUNT: 3. I HAVE BEEN PATIENT. I HAVE BEEN WHIMSICAL..." |
| Unknown app, conf 0.22, level 1 | "Something's had your full attention for 90 minutes. I don't know what..." |
| Xcode, `building`, 02:14 | "It is 2am and you just wrote a regex. Nobody has ever done that and been right." |

---

## 1. Selection model

### 1.1 The context

Everything the engine can reason about is in one value type. Nothing else is read at
selection time — this makes selection pure, and therefore testable and reproducible.

```swift
// MARK: - Context vocabulary

public enum AppKey: String, Codable, Sendable, CaseIterable {
    case cursor, vscode, zed, xcode, jetbrains, terminal, browser
    case figma, docker, slack, discord, unknown
}

public enum AppFamily: String, Codable, Sendable, CaseIterable {
    case aiEditor      // cursor, and other completion-forward editors
    case editor        // vscode, zed, sublime
    case ide           // xcode, jetbrains
    case terminal
    case browser
    case design
    case containers
    case chat
    case other
}

public enum ActivityKind: String, Codable, Sendable, CaseIterable {
    case aiPairing, editing, debugging, testing, building, reviewing
    case reading, chatting, browsing, designing, unknown
}

/// Continuous-work duration, bucketed. Bands, not raw minutes, are what templates match on:
/// raw minutes are a slot, bands are a predicate.
public enum WorkBand: String, Codable, Sendable, CaseIterable {
    case short      // < 25
    case focused    // 25 ..< 50
    case deep       // 50 ..< 90
    case marathon   // 90 ..< 150
    case absurd     // >= 150

    public init(minutes: Int) {
        switch minutes {
        case ..<25:   self = .short
        case ..<50:   self = .focused
        case ..<90:   self = .deep
        case ..<150:  self = .marathon
        default:      self = .absurd
        }
    }
}

public enum TimeBand: String, Codable, Sendable, CaseIterable {
    case earlyMorning   // 05:00 ..< 08:00
    case morning        // 08:00 ..< 12:00
    case afternoon      // 12:00 ..< 17:00
    case evening        // 17:00 ..< 21:00
    case night          // 21:00 ..< 01:00
    case lateNight      // 01:00 ..< 05:00

    public init(hour: Int) {
        switch hour {
        case 5..<8:   self = .earlyMorning
        case 8..<12:  self = .morning
        case 12..<17: self = .afternoon
        case 17..<21: self = .evening
        case 21..<24, 0: self = .night
        default:      self = .lateNight
        }
    }
}

public enum Weekday: String, Codable, Sendable, CaseIterable {
    case mon, tue, wed, thu, fri, sat, sun
}

/// Counters the ledger maintains across the day / session.
public enum StreakKey: String, Codable, Sendable, CaseIterable {
    case skippedToday          // breaks dismissed or snoozed today
    case skippedConsecutive    // dismissed in a row, resets on a taken break
    case takenToday
    case snoozeSecondsToday
    case buildsWatchedInSession
    case sameCommandRepeats    // terminal: identical command re-run count
}

/// Cheap booleans/strings the collectors can assert about the session.
public enum FactKey: String, Codable, Sendable, CaseIterable {
    case branchIsDefault       // on main/master
    case branchIsLongLived
    case hasUncommittedChanges
    case ciPending
    case prOpenInForeground
    case testsFailing
    case buildRunning
    case windowCount           // numeric fact
    case editorTabCount
}

public enum FactValue: Sendable, Hashable, Codable {
    case bool(Bool)
    case int(Int)
    case string(String)
}

public enum FactMatch: Sendable, Hashable, Codable {
    case isTrue
    case isFalse
    case intAtLeast(Int)
    case equalsString(String)
}
```

```swift
public struct DeveloperContext: Sendable {
    public var now: Date
    public var calendar: Calendar

    // Foreground application
    public var app: AppKey
    public var appFamily: AppFamily
    public var appDisplayName: String?          // "Cursor", "Xcode" — may be nil
    public var appConfidence: Double            // 0...1

    // Inferred activity
    public var activity: ActivityKind
    public var activityConfidence: Double       // 0...1

    // Timing
    public var continuousWorkMinutes: Int
    public var minutesSinceLastBreak: Int
    public var timeBand: TimeBand
    public var weekday: Weekday

    // Insistence
    public var escalation: EscalationLevel
    public var toneCeiling: Tone                // user preference, hard cap

    // Structured extras
    public var streaks: [StreakKey: Int]
    public var facts: [FactKey: FactValue]
    public var slots: [SlotKey: SlotValue]

    public var workBand: WorkBand { WorkBand(minutes: continuousWorkMinutes) }
}
```

### 1.2 Predicates

A template declares preconditions as a list of predicates. All predicates must hold
(conjunction). Disjunction lives *inside* a predicate, as a set — `app(in: [.vscode, .zed])`.
This keeps the language flat enough to validate in CI and to explain in a debug panel.

```swift
public enum Predicate: Sendable, Hashable, Codable {
    case app(Set<AppKey>)
    case appFamily(Set<AppFamily>)
    case activity(Set<ActivityKind>)
    case workBand(Set<WorkBand>)
    case timeBand(Set<TimeBand>)
    case weekday(Set<Weekday>)
    case minutesSinceBreak(atLeast: Int)
    case streak(StreakKey, atLeast: Int)
    case fact(FactKey, FactMatch)

    public func holds(in ctx: DeveloperContext) -> Bool {
        switch self {
        case .app(let s):            return s.contains(ctx.app)
        case .appFamily(let s):      return s.contains(ctx.appFamily)
        case .activity(let s):       return s.contains(ctx.activity)
        case .workBand(let s):       return s.contains(ctx.workBand)
        case .timeBand(let s):       return s.contains(ctx.timeBand)
        case .weekday(let s):        return s.contains(ctx.weekday)
        case .minutesSinceBreak(let n):
            return ctx.minutesSinceLastBreak >= n
        case .streak(let k, let n):
            return (ctx.streaks[k] ?? 0) >= n
        case .fact(let k, let m):
            guard let v = ctx.facts[k] else { return false }
            switch (m, v) {
            case (.isTrue, .bool(let b)):                 return b
            case (.isFalse, .bool(let b)):                return !b
            case (.intAtLeast(let n), .int(let i)):       return i >= n
            case (.equalsString(let s), .string(let t)):  return s == t
            default:                                      return false
            }
        }
    }
}
```

**A missing fact fails the predicate.** Absence is never treated as truth. This is the rule
that stops the engine claiming you are on `main` because the git collector hasn't reported yet.

### 1.3 Specificity weights

Specificity is what makes "a Cursor-specific joke beats a generic one" a property of the
system rather than a hope. Each predicate kind carries a weight reflecting how much of the
context it pins down:

```swift
extension Predicate {
    /// How much context this predicate commits to. Higher = more specific = better match.
    public var specificity: Int {
        switch self {
        case .app:                return 40
        case .activity:           return 30
        case .fact:               return 25
        case .streak:             return 20
        case .appFamily:          return 15
        case .workBand:           return 12
        case .timeBand:           return 12
        case .minutesSinceBreak:  return 8
        case .weekday:            return 5
        }
    }
}
```

Rationale for the ordering: `app` is the strongest signal a reader perceives ("it knows I'm in
Cursor"), `activity` next ("it knows I'm debugging"). Set size does not reduce weight — a
template matching `[.vscode, .zed]` is only marginally less specific than one matching
`[.vscode]`, and penalising set size would push contributors to duplicate lines per app.

The score adds two structural bonuses on top of the predicate sum:

```swift
public struct Scorer {
    public static let slotBonus = 4          // per required slot: the line commits to a detail
    public static let tightEscalationBonus = 6   // template targets exactly one level

    public static func score(_ t: MessageTemplate, in ctx: DeveloperContext) -> Int {
        var s = t.when.reduce(0) { $0 + $1.specificity }
        s += slotBonus * t.requiredSlots.count
        if t.escalation.lowerBound == t.escalation.upperBound { s += tightEscalationBonus }
        s += t.authorPriority          // pack-declared, clamped to -10...10 at load
        return s
    }
}
```

A Cursor + aiPairing + marathon template scores `40 + 30 + 12 = 82` plus bonuses. A generic
`workBand(.marathon)` template scores `12`. The Cursor line wins by construction, and it wins
by enough that no randomness can flip it (see the band rule below).

### 1.4 The algorithm

```swift
public struct SelectionResult: Sendable {
    public let message: RenderedMessage
    public let trace: SelectionTrace     // for the debug panel and for tests
}

public struct SelectionTrace: Sendable {
    public var totalTemplates: Int
    public var afterHardGates: Int
    public var afterRecency: Int
    public var relaxation: RelaxationStage
    public var topScore: Int
    public var bandSize: Int
    public var rejections: [String: RejectionReason]   // templateID -> why
}

public final class MessageEngine {
    private let corpus: Corpus
    private let ledger: RecencyLedger
    private let slots: SlotResolver
    private var rng: any RandomNumberGenerator

    public init(corpus: Corpus,
                ledger: RecencyLedger,
                slots: SlotResolver,
                rng: any RandomNumberGenerator = SystemRandomNumberGenerator()) { ... }

    public func select(for ctx: DeveloperContext) -> SelectionResult
}
```

Pipeline, in order:

**Step 1 — hard gates.** A template is eligible only if *all* of these hold. Failing any one
is disqualifying; there is no partial credit and no soft scoring around them.

1. `ctx.escalation` is inside `t.escalation` (a `ClosedRange<EscalationLevel>`).
2. `t.tone <= ctx.toneCeiling` (user preference is a ceiling, never a floor).
3. `t.tone` is permitted at `ctx.escalation` by the tone/escalation matrix in §5.
4. Every predicate in `t.when` holds.
5. Confidence gate passes (§6).
6. Every slot in `t.requiredSlots` resolves at or above the slot confidence floor (§2).
7. The pack is enabled and its `schemaVersion` is supported.

**Step 2 — recency filter.** Apply the ledger rules in §3 at the current relaxation stage.

**Step 3 — score and band.** Compute `Scorer.score` for survivors. Let `best` be the maximum.
Keep the *band*: every candidate with `score >= best - bandTolerance`, where
`bandTolerance = 10`. Ten is deliberately smaller than the cheapest strong predicate
(`appFamily`, 15) — so a template that pins the app or the activity can never be beaten by
one that doesn't. Within the band, templates are genuinely interchangeable in specificity,
so randomness is safe there and only there.

**Step 4 — weighted pick inside the band.** Randomness is injected as freshness-weighted
sampling, not uniform choice:

```swift
func pickWeight(_ t: MessageTemplate, now: Date) -> Double {
    let base = t.weight                                    // pack-declared, default 1.0
    guard let last = ledger.lastShown(templateID: t.id) else { return base }   // never shown
    let hours = now.timeIntervalSince(last) / 3600
    let recoveryHours = Double(t.cooldownHours ?? Policy.templateCooldownHours)
    let freshness = min(1.0, max(0.05, hours / recoveryHours))
    return base * freshness
}
```

Then cumulative-weight sampling over the band. Never-shown templates dominate naturally, so
a newly installed pack surfaces quickly without a special case.

**Step 5 — tie-break.** Exact float ties (and the deterministic test mode) break on a stable
hash so the same context on the same day yields the same line:

```swift
func tieBreakKey(_ t: MessageTemplate, ctx: DeveloperContext) -> UInt64 {
    var h = Hasher()
    h.combine(t.id)
    h.combine(ctx.calendar.startOfDay(for: ctx.now).timeIntervalSince1970)
    h.combine(ctx.escalation.rawValue)
    return UInt64(bitPattern: Int64(h.finalize()))
}
```

Order: higher weight → lower `tieBreakKey` → lexicographic `id`. Fully deterministic, so the
golden tests in §8 can assert exact output.

**Step 6 — render.** Fill slots (§2), record to the ledger, return with the trace.

---

## 2. Slot filling

### 2.1 Typed slots

```swift
public enum SlotKey: String, Codable, Sendable, CaseIterable {
    case app        // "Cursor"         — display name of the foreground app
    case minutes    // "94"             — continuous work minutes, localized number
    case project    // "payments-api"   — workspace/repo name
    case branch     // "fix/retry-loop" — current git branch
    case activity   // "debugging"      — human-readable activity noun
    case streak     // "3"              — skipped-breaks count
    case count      // "41"             — generic counter the collector supplies
    case hour       // "2:14am"         — localized time of day
}

public struct SlotValue: Sendable, Hashable {
    public let text: String
    public let confidence: Double        // 0...1
    public let provenance: Provenance

    public enum Provenance: String, Sendable, Codable {
        case exact        // read directly (git HEAD, window title, accessibility API)
        case derived      // computed from an exact value (minutes from a timestamp)
        case degraded     // family-level substitute ("your editor")
        case generic      // neutral filler ("this")
    }
}
```

### 2.2 Declaration is mandatory

Every template declares `requiredSlots` and `optionalSlots`. Lint (§8) enforces the
bidirectional invariant: every `{slot}` appearing in `text` is declared, and every declared
slot appears in `text`. This is the mechanism that guarantees **a template needing `{branch}`
is never selected when branch is unknown** — it isn't a runtime string check, it's a hard gate
in Step 1 that runs before the text is ever touched.

```swift
public struct SlotResolver {
    public static let requiredFloor: Double = 0.70   // required slots need this confidence
    public static let optionalFloor: Double = 0.50

    /// Hard gate: can this template's required slots all be satisfied *exactly or derived*?
    public func canSatisfyRequired(_ t: MessageTemplate, in ctx: DeveloperContext) -> Bool {
        t.requiredSlots.allSatisfy { key in
            guard let v = ctx.slots[key] else { return false }
            guard v.confidence >= Self.requiredFloor else { return false }
            return v.provenance == .exact || v.provenance == .derived
        }
    }

    public func fill(_ t: MessageTemplate, in ctx: DeveloperContext) throws -> String
}
```

### 2.3 The fallback chain

For each slot referenced by a template, in order:

1. **Exact.** The collector reported it with `confidence >= floor`. Use it.
2. **Derived.** Computed from an exact source (minutes from the session start timestamp;
   `hour` from `now`). Treated as exact for gating purposes.
3. **Degraded.** A family-level substitute: `{app}` → "your editor" / "your terminal" /
   "your browser"; `{project}` → "this project"; `{activity}` → "whatever this is".
   *Allowed for optional slots only.*
4. **Generic.** A neutral filler that can't be wrong: `{project}` → "this", `{app}` → "that".
   *Optional slots only.*
5. **Alt text.** If the template supplies `altText` (a variant sentence with the slot removed),
   use it. This is how a line keeps its joke when one detail goes missing.
6. **Ineligible.** If the slot is required, or is optional with no degraded form and no
   `altText`, the template is dropped in Step 1 and never reaches rendering.

Two slots never degrade, because a wrong value is worse than no line at all:

- `{branch}` — required-only. There is no "your branch" that is funny.
- `{streak}` — required-only. A wrong count destroys the joke's entire premise.

Number and time slots (`minutes`, `count`, `hour`, `streak`) are rendered through
`NumberFormatter` / `Date.FormatStyle` at fill time, never string-interpolated — see §9.

---

## 3. Repetition avoidance: the recency ledger

Repetition is the failure mode that gets the app uninstalled. The ledger is therefore
persistent (SQLite/`UserDefaults`-backed, survives relaunch) and enforced as a hard gate.

```swift
public protocol RecencyLedger: AnyObject, Sendable {
    func lastShown(templateID: String) -> Date?
    func showCount(templateID: String, since: Date) -> Int
    func shownToday(templateID: String, calendar: Calendar, now: Date) -> Bool
    func lastShown(category: String) -> Date?
    func lastShown(tone: Tone) -> Date?
    func recentTemplateIDs(limit: Int) -> [String]      // most-recent-first LRU
    func record(templateID: String, category: String, tone: Tone, at: Date)
    func purge(before: Date)                            // retention: 30 days
}
```

### 3.1 Policy

```swift
public enum Policy {
    public static let templateCooldownHours = 72        // a line rests 3 days
    public static let categoryCooldownMinutes = 45      // don't do two Docker jokes in a row
    public static let lruWindow = 60                    // last 60 shown IDs are excluded
    public static let nuclearPerDay = 1                 // at most one NUCLEAR per calendar day
    public static let toneRepeatWindow = 3              // avoid 3 identical tones in a row
    public static let ledgerRetentionDays = 30
}
```

Rules, all enforced at Step 2:

| Rule | Effect |
|---|---|
| **Same-day uniqueness** | A template shown today is ineligible today. Absolute at stages L0–L3. This is the rule users actually notice. |
| **Per-template cooldown** | 72h since last show (overridable per template via `cooldownHours`). |
| **Per-category cooldown** | 45 minutes since any template of the same `category`. |
| **LRU ring** | The last 60 template IDs shown (across all days) are excluded outright. |
| **Tone variety** | If the last 3 shows had the same tone, that tone is deprioritized (weight ×0.4), not blocked. |
| **NUCLEAR budget** | At most 1 NUCLEAR per calendar day, at most 1 per 6h. Scarcity is what makes it land. |

The LRU is a plain array of 60 strings, not a Bloom filter. A Bloom filter buys nothing at
n=60 and its false positives would silently blacklist good lines — the exact bug you cannot
debug from a user report.

### 3.2 Pool exhaustion: the relaxation ladder

Selection never returns nothing. If Step 2 empties the candidate set, the engine re-runs
Step 2 at the next stage and records the stage in the trace:

```swift
public enum RelaxationStage: Int, Sendable, Comparable {
    case strict = 0        // all rules
    case dropCategory = 1  // drop the 45-minute category cooldown
    case shrinkLRU = 2     // LRU window 60 -> 20
    case dropCooldown = 3  // drop the 72h template cooldown; same-day rule still absolute
    case allowSameDay = 4  // allow a same-day repeat, but only if >= 6h since that show
    case emergency = 5     // built-in fallback pool, tone forced to .friendly
}
```

Stage 5 draws from `Corpus.emergencyPool`, a small set compiled into the binary (not
loadable, not disable-able, `isFallback: true`). A unit test asserts the emergency pool is
non-empty at every escalation level, so `select` is total — it has no failure return and
cannot throw.

Stage is surfaced in the debug panel and in telemetry (opt-in, counts only). A user reaching
stage ≥ 3 regularly means their enabled packs are too small for their usage pattern, and the
app suggests enabling another pack rather than silently repeating itself.

---

## 4. Tone system

Four tiers. The distinction is **not** intensity of insult — it is *what the joke is about*
and *how the exaggeration works*.

```swift
public enum Tone: String, Codable, Sendable, CaseIterable, Comparable {
    case friendly, sarcastic, roast, nuclear
    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Tone, b: Tone) -> Bool { a.rank < b.rank }
}
```

### 4.1 What separates the tiers

| Tier | Target of the joke | Grammatical person | Exaggeration | Example |
|---|---|---|---|---|
| **FRIENDLY** | The *situation* or the *tooling*. Never the reader. | First person plural or impersonal. | None. | "Builds are slow. Breaks are free. Take one." |
| **SARCASTIC** | A *behavior*, observed dryly. The reader is in on it. | Second person, but deniable — the line would work as self-deprecation. | Understatement. | "You just ran `clear` to feel productive. I saw that." |
| **ROAST** | A *specific behavior in this session*, named directly. | Second person, direct, affectionate. | Mild hyperbole. | "You have added seven print statements and removed zero." |
| **NUCLEAR** | Still the behavior — but the *consequence* is escalated past physical possibility. | Second person, theatrical, often shouting. | **Literally impossible.** | "Sediment is forming. YOU ARE BECOMING A ROCK FORMATION." |

The load-bearing rule for NUCLEAR: **the impossibility is the safety mechanism.** A line that
is merely harsher than ROAST is not NUCLEAR, it is cruelty with a louder font. If the
exaggeration could be literally true, the line is ROAST at best and probably a rail violation.
"You have been sitting so long you are becoming sedimentary rock" is absurd, so it's funny.
"You have been sitting so long it shows" is a comment about a person, so it ships never.

### 4.2 Content safety rails (absolute)

A line **never** references, implies, or jokes about:

1. **Body weight, size, or eating.** No "get off the couch," no calorie jokes, no food shaming.
2. **Physical appearance.** Nothing about how the reader looks, smells, is dressed, or ages.
3. **Medical conditions.** No eye strain, RSI, back damage, sleep disorders, posture warnings —
   both because they'd be claims the app can't support, and because they're not funny.
4. **Mental health.** No burnout diagnoses, no "you seem depressed," no addiction framing,
   no clinical vocabulary used as a punchline.
5. **Competence.** The joke is never "you are bad at this." Behavior is fair game; ability is not.
   *"You've run the same failing command 23 times"* — fine, that's a fact about a session.
   *"You clearly don't know what you're doing"* — never.
6. **Job security.** No "your manager is watching," no "this is why you'll get fired," no
   performance-review framing. The app is not a threat.

Plus three structural rails:

7. **Punch direction.** The joke punches at the situation, the tooling, the code, the process,
   or a behavior. Never at the person's worth, identity, or group.
8. **No genuine demeaning.** If the line would land as a *verdict on the reader* rather than
   as ribbing about a moment, it is out — regardless of tier.
9. **No real-world targets.** No jokes at the expense of named people, companies as
   organizations, or communities. Mocking a *tool's behavior* is fine ("the storyboard adds
   a constraint every time you remove one"); mocking its users is not.

### 4.3 Contributor rubric

Apply all seven to every submitted line. Any single failure is a rejection.

1. **Target test.** Name the target in one word. If the answer is a *person* or a *trait*,
   reject. Acceptable answers: a behavior, a tool, the code, the clock, the situation.
2. **Standup test.** Could you say this out loud to a colleague at standup and have them
   laugh? If it would land as an insult in a room, it lands as one in a notification.
3. **Bad-day test.** Read it as someone having the worst week of their career. Does it still
   read as ribbing rather than as a verdict? If it kicks, cut it.
4. **Specificity test.** Could this line be about any app, any activity, any hour? If yes, it
   belongs in the generic pool with generic preconditions — not tagged to an app it doesn't
   actually reference. Mis-tagging is the most common contribution defect.
5. **Impossibility test (NUCLEAR only).** Is the exaggeration literally impossible or
   cosmically overblown? If it is merely meaner than ROAST, it is not NUCLEAR, it is cruel.
6. **Screenshot test.** Would a senior engineer screenshot this and post it? If it's "time for
   a break!" with extra words, cut it. Filler is a correctness bug in a humor corpus.
7. **Rails check.** Walk the nine rails in §4.2 explicitly. Write the result in the PR.

### 4.4 Lint / CI enforcement

`corpus-lint` is a SwiftPM command plugin (`swift package corpus-lint`) run on every PR
touching `docs/corpus-*.json` or `Resources/packs/**`. It enforces the *structural* parts of
the rubric — the parts a machine can decide. Rubric items 1–3 and 6 stay human, and the PR
template requires a reviewer to tick them.

**Hard failures:**

| # | Check |
|---|---|
| L1 | JSON Schema validation against `message-pack-1.json`. |
| L2 | `id` unique within and across enabled packs; matches `^[a-z0-9]+(\.[a-z0-9-]+){2,}$`. |
| L3 | Slot invariant: every `{slot}` in `text`/`altText` is declared; every declared slot is used. |
| L4 | `escalation.min <= escalation.max`, both in `1...4`. |
| L5 | Tone/escalation matrix: `nuclear` requires `escalation.min >= 3`; `friendly` at level 4 only if `isFallback`. |
| L6 | `minConfidence` in `0...1`. If `claimsActivity` is true, `minConfidence >= 0.75` **and** at least one `app` or `activity` predicate is present. |
| L7 | **Banned lexicon.** Case-insensitive regex over `text`+`altText` across six families: weight/eating, appearance, medical, mental-health, competence, employment. Stems include `\bfat\b`, `\bugly\b`, `\beye ?strain\b`, `\bcarpal\b`, `\bposture\b`, `\bburn(ed|t)? ?out\b`, `\bdepress\w*`, `\banxi\w*`, `\baddict\w*`, `\bincompetent\b`, `\bstupid\b`, `\bidiot\b`, `\byou('re| are) bad\b`, `\b(?:get|got|be|been|you're)\s+fired\b` (context-qualified: a bare `fired` legitimately describes an event firing), `\bperformance review\b`, `\bPIP\b`. The list lives in `Lint/banned-lexicon.json`, is append-only, and each entry carries a rationale string. |
| L8 | **Product-name denylist:** the app's own name tokens must not appear in any pack. |
| L9 | Length: `text` ≤ 240 chars; `title` ≤ 48 chars. |
| L10 | **Coverage floor.** For each (`appFamily` × escalation level) bucket, ≥ 6 eligible messages. For the generic low-confidence bucket, ≥ 12 at every level. Prevents a pack from starving a context into stage-5 fallback. |
| L11 | Emergency pool non-empty at all four levels (asserted against the compiled-in pool). |
| L12 | `weight` in `0.1...5.0`; `authorPriority` in `-10...10`. |

**Warnings (require an explicit reviewer ack in the PR body):**

| # | Check |
|---|---|
| W1 | **Trait detector.** `/\byou(?:'re\| are)\s+(?:a\|an\|so\|such\|just)\b/i` — this grammar usually attaches a *label to the person*, which is rail #7. Most hits are genuine violations. |
| W2 | **NUCLEAR absurdity marker.** A `nuclear` line must contain an impossibility marker (a regex set over geological/cosmic/anthropomorphic hyperbole) **or** a shouted run of ≥ 2 consecutive ALL-CAPS words **or** `"theatrical": true` with a named reviewer. Without one of these it is probably just mean. |
| W3 | Near-duplicate detection: token-level Jaccard ≥ 0.6 against any existing line. |
| W4 | Filler detector: flags lines whose non-stopword content is a subset of {time, break, take, now, stand, up, rest}. This is the "limp filler" check. |

**Golden tests** (`MessageEngineTests`) run alongside the lint over a fixture matrix of 500
synthetic contexts spanning every app × activity × band × level × confidence tier:

- `select` returns a message for all 500 (totality).
- `t.tone <= ctx.toneCeiling` for all 500 (ceiling never violated).
- No template ID repeats within any 60-selection window (LRU honored).
- No template repeats within a simulated calendar day at stages ≤ 3.
- Every rendered string contains zero unfilled `{...}` sequences.
- A Cursor context never selects a generic line while an eligible Cursor line exists
  (the specificity property, asserted directly).

---

## 5. Escalation

Four levels. Escalation is a property of the *user's response history*, not of elapsed time
alone: it advances on a skip and resets on a taken break.

```swift
public enum EscalationLevel: Int, Codable, Sendable, CaseIterable, Comparable {
    case nudge = 1
    case insistent = 2
    case confrontational = 3
    case intervention = 4

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct EscalationPolicy {
    /// Advance one level per skip; reset to .nudge on a completed break;
    /// decay one level for every 2 hours with no reminder fired.
    public func next(after outcome: ReminderOutcome,
                     from level: EscalationLevel,
                     idleSince: Date?,
                     now: Date) -> EscalationLevel
}

public enum ReminderOutcome: String, Codable, Sendable {
    case breakTaken, snoozed, dismissed, ignored, quietHours
}
```

Per-level treatment. Each level changes *three* things — the tone ceiling, the presentation,
and the cost of saying no:

| | **L1 Nudge** | **L2 Insistent** | **L3 Confrontational** | **L4 Intervention** |
|---|---|---|---|---|
| Tone cap | `sarcastic` | `roast` | `roast` (`nuclear` if opted in) | `nuclear` |
| Presentation | `UNNotification` banner | Banner, persistent | Alert-style + menu-bar pulse | Borderless `NSWindow` at `.statusBar` level, 40% screen |
| Sound | none | `NSSound` soft | `NSSound` distinct | distinct + repeat once at 10s |
| Dismissal | auto after 8s | stays until acted on | stays; "Later" needs a second click | 20s countdown; "I'm mid-thought" button dismisses |
| Actions | Later | Later (10m) · Start break | Later (5m, confirm) · Start break | Snooze 5m (once) · Start break |
| Snooze budget | unlimited | 3/hour | 1/hour | 1 per event |
| Frequency guard | — | — | ≥ 8 min since last | ≥ 15 min since last; max 3/day |

Two non-negotiables, enforced in the notification layer rather than the engine:

- **L4 never steals keyboard focus.** The window is non-activating
  (`NSWindow.StyleMask.nonactivatingPanel`, `becomesKeyOnlyIfNeeded = true`). It is visually
  loud and input-transparent to the app underneath. A break reminder that eats a keystroke
  mid-edit gets uninstalled that afternoon, correctly.
- **Screen sharing, Do Not Disturb, full-screen presentation, and camera-on states suppress
  L3 and L4 entirely**, downgrading them to L1 banners held until the state clears. Nobody
  wants a NUCLEAR roast rendering on a projector during a demo.

---

## 6. Confidence gating

Two independent confidences: `appConfidence` (which app is in front) and `activityConfidence`
(what you're doing in it). App detection is nearly always reliable; activity inference is not.
The rule: **the engine may only make a claim as specific as its weakest relevant signal.**

```swift
public enum ConfidenceTier: String, Sendable, CaseIterable {
    case high      // >= 0.85 — specific factual claims allowed
    case medium    // >= 0.60 — app-level claims only; no fine-grained activity claims
    case low       // >= 0.35 — app-family / neutral lines only
    case unknown   // <  0.35 — generic pool only

    public init(_ v: Double) {
        switch v {
        case 0.85...:      self = .high
        case 0.60..<0.85:  self = .medium
        case 0.35..<0.60:  self = .low
        default:           self = .unknown
        }
    }
}
```

Gate, evaluated in Step 1:

```swift
func confidenceGate(_ t: MessageTemplate, _ ctx: DeveloperContext) -> Bool {
    // A template that names an activity must clear its own floor on activity confidence.
    let usesActivity = t.when.contains { if case .activity = $0 { return true }; return false }
        || t.requiredSlots.contains(.activity)
        || t.claimsActivity

    let usesApp = t.when.contains { if case .app = $0 { return true }; return false }
        || t.requiredSlots.contains(.app)

    if usesActivity && ctx.activityConfidence < t.minConfidence { return false }
    if usesApp && ctx.appConfidence < max(t.minConfidence, 0.60) { return false }

    // Hard floor: below 0.35 on the relevant signal, only non-claiming templates survive.
    if ConfidenceTier(ctx.activityConfidence) == .unknown && usesActivity { return false }
    if ConfidenceTier(ctx.appConfidence) == .unknown && usesApp { return false }
    return true
}
```

Recommended `minConfidence` by how specific the claim is:

| Claim the line makes | `minConfidence` | Example |
|---|---|---|
| Names an app *and* a fine-grained activity ("you've accepted 41 suggestions") | 0.85 | Cursor + aiPairing lines |
| Names an app, generic activity ("long stretch in the editor") | 0.70 | VS Code lines |
| App family only ("your terminal has been busy") | 0.55 | family lines |
| No claim at all ("something's had your attention") | 0.00 | generic pool |

**The failure mode this prevents:** the collector sees Xcode in the foreground with a build
log scrolling and infers `testing` at 0.41. Without the gate, the app says "you've run the
same test 18 times" to someone who is not running tests. That single wrong claim costs more
credibility than ten good jokes earn — and the user *knows* it guessed, which retroactively
makes every accurate line look like a guess too. So at low confidence the engine falls back
to lines that are still funny but make no factual claim ("I could guess what you're doing,
but I'd be wrong and you'd screenshot it"). The generic pool is written to be *good*, not to
be a consolation prize; it carries ~10% of the corpus and gets the same rubric.

---

## 7. Corpus format

### 7.1 Pack envelope

```json
{
  "$schema": "https://schemas.invalid/break-message-pack/1.json",
  "schemaVersion": 1,
  "packId": "core.en-US",
  "packVersion": "0.1.0",
  "locale": "en-US",
  "title": "Core Pack",
  "author": "core",
  "license": "CC-BY-4.0",
  "defaultWeight": 1.0,
  "messages": []
}
```

### 7.2 JSON Schema (draft 2020-12)

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.invalid/break-message-pack/1.json",
  "title": "Break Message Pack",
  "type": "object",
  "required": ["schemaVersion", "packId", "packVersion", "locale", "messages"],
  "additionalProperties": false,
  "properties": {
    "$schema":       { "type": "string" },
    "schemaVersion": { "type": "integer", "const": 1 },
    "packId":        { "type": "string", "pattern": "^[a-z0-9]+(\\.[a-z0-9-]+)+$" },
    "packVersion":   { "type": "string", "pattern": "^\\d+\\.\\d+\\.\\d+$" },
    "locale":        { "type": "string", "pattern": "^[a-z]{2}(-[A-Z]{2})?$" },
    "title":         { "type": "string", "maxLength": 60 },
    "author":        { "type": "string", "maxLength": 80 },
    "license":       { "type": "string", "maxLength": 40 },
    "defaultWeight": { "type": "number", "minimum": 0.1, "maximum": 5.0 },
    "messages": {
      "type": "array",
      "minItems": 1,
      "items": { "$ref": "#/$defs/message" }
    }
  },
  "$defs": {
    "slotKey": {
      "enum": ["app", "minutes", "project", "branch", "activity", "streak", "count", "hour"]
    },
    "tone":     { "enum": ["friendly", "sarcastic", "roast", "nuclear"] },
    "appKey":   { "enum": ["cursor","vscode","zed","xcode","jetbrains","terminal",
                           "browser","figma","docker","slack","discord","unknown"] },
    "appFamily":{ "enum": ["aiEditor","editor","ide","terminal","browser",
                           "design","containers","chat","other"] },
    "activity": { "enum": ["aiPairing","editing","debugging","testing","building",
                           "reviewing","reading","chatting","browsing","designing","unknown"] },
    "workBand": { "enum": ["short","focused","deep","marathon","absurd"] },
    "timeBand": { "enum": ["earlyMorning","morning","afternoon","evening","night","lateNight"] },
    "weekday":  { "enum": ["mon","tue","wed","thu","fri","sat","sun"] },
    "streakKey":{ "enum": ["skippedToday","skippedConsecutive","takenToday",
                           "snoozeSecondsToday","buildsWatchedInSession","sameCommandRepeats"] },
    "factKey":  { "enum": ["branchIsDefault","branchIsLongLived","hasUncommittedChanges",
                           "ciPending","prOpenInForeground","testsFailing","buildRunning",
                           "windowCount","editorTabCount"] },

    "predicate": {
      "type": "object",
      "required": ["p"],
      "additionalProperties": false,
      "properties": {
        "p":       { "enum": ["app","appFamily","activity","workBand","timeBand",
                              "weekday","minutesSinceBreak","streak","fact"] },
        "in":      { "type": "array", "minItems": 1, "items": { "type": "string" } },
        "atLeast": { "type": "integer", "minimum": 0 },
        "key":     { "type": "string" },
        "match":   { "enum": ["isTrue","isFalse","intAtLeast","equalsString"] },
        "value":   { "type": ["string","integer","boolean"] }
      },
      "allOf": [
        { "if":   { "properties": { "p": { "const": "app" } } },
          "then": { "required": ["in"],
                    "properties": { "in": { "items": { "$ref": "#/$defs/appKey" } } } } },
        { "if":   { "properties": { "p": { "const": "activity" } } },
          "then": { "required": ["in"],
                    "properties": { "in": { "items": { "$ref": "#/$defs/activity" } } } } },
        { "if":   { "properties": { "p": { "const": "minutesSinceBreak" } } },
          "then": { "required": ["atLeast"] } },
        { "if":   { "properties": { "p": { "const": "streak" } } },
          "then": { "required": ["key", "atLeast"],
                    "properties": { "key": { "$ref": "#/$defs/streakKey" } } } },
        { "if":   { "properties": { "p": { "const": "fact" } } },
          "then": { "required": ["key", "match"],
                    "properties": { "key": { "$ref": "#/$defs/factKey" } } } }
      ]
    },

    "message": {
      "type": "object",
      "required": ["id", "text", "tone", "category", "escalation"],
      "additionalProperties": false,
      "properties": {
        "id":    { "type": "string", "pattern": "^[a-z0-9]+(\\.[a-z0-9-]+){2,}$" },
        "title": { "type": "string", "maxLength": 48 },
        "text":  { "type": "string", "minLength": 8, "maxLength": 240 },
        "altText": {
          "type": "string", "maxLength": 240,
          "description": "Variant with optional slots removed; used by fallback step 5."
        },
        "tone":     { "$ref": "#/$defs/tone" },
        "category": { "type": "string", "pattern": "^[a-z][a-z0-9_]{2,31}$" },
        "escalation": {
          "type": "object",
          "required": ["min", "max"],
          "additionalProperties": false,
          "properties": {
            "min": { "type": "integer", "minimum": 1, "maximum": 4 },
            "max": { "type": "integer", "minimum": 1, "maximum": 4 }
          }
        },
        "minConfidence": { "type": "number", "minimum": 0, "maximum": 1, "default": 0 },
        "claimsActivity": { "type": "boolean", "default": false },
        "requiredSlots": {
          "type": "array", "uniqueItems": true, "items": { "$ref": "#/$defs/slotKey" }
        },
        "optionalSlots": {
          "type": "array", "uniqueItems": true, "items": { "$ref": "#/$defs/slotKey" }
        },
        "when": { "type": "array", "items": { "$ref": "#/$defs/predicate" } },
        "weight":         { "type": "number", "minimum": 0.1, "maximum": 5.0, "default": 1.0 },
        "authorPriority": { "type": "integer", "minimum": -10, "maximum": 10, "default": 0 },
        "cooldownHours":  { "type": "integer", "minimum": 1, "maximum": 720 },
        "isFallback":     { "type": "boolean", "default": false },
        "theatrical":     { "type": "boolean", "default": false },
        "plural": {
          "type": "object",
          "description": "Slot -> CLDR plural category -> variant text. See localization notes.",
          "additionalProperties": {
            "type": "object",
            "additionalProperties": { "type": "string", "maxLength": 240 },
            "propertyNames": { "enum": ["zero","one","two","few","many","other"] }
          }
        },
        "notes": { "type": "string", "maxLength": 300 }
      }
    }
  }
}
```

### 7.3 Swift decoding

```swift
public struct MessagePack: Codable, Sendable {
    public let schemaVersion: Int
    public let packId: String
    public let packVersion: String
    public let locale: String
    public let title: String?
    public let author: String?
    public let license: String?
    public let defaultWeight: Double?
    public let messages: [MessageTemplate]
}

public struct MessageTemplate: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String?
    public let text: String
    public let altText: String?
    public let tone: Tone
    public let category: String
    public let escalation: ClosedRange<EscalationLevel>   // decoded from {min,max}
    public let minConfidence: Double
    public let claimsActivity: Bool
    public let requiredSlots: [SlotKey]
    public let optionalSlots: [SlotKey]
    public let when: [Predicate]
    public let weight: Double
    public let authorPriority: Int
    public let cooldownHours: Int?
    public let isFallback: Bool
    public let theatrical: Bool
    public let plural: [SlotKey: [String: String]]?
    public let notes: String?
}

public struct Corpus: Sendable {
    public let packs: [MessagePack]
    public let templates: [MessageTemplate]          // flattened, id-deduped, lint-validated
    public static let emergencyPool: [MessageTemplate]   // compiled in, never empty
}
```

**Packs ship in-tree only. There is no runtime pack loading, and this is a decision
rather than a gap.**

An earlier draft of this document described loading packs from
`~/Library/Application Support/<app>/packs/*.json`. That was never built, and the document
was wrong to describe it as though it were. The contribution path is a pull request against
`app/Sources/SigstopCore/Message/corpus.json`: every line that ships has been read by a
human, which is the only defence that actually works against the real risk here. A pack is
data, not code, so it cannot execute anything or reach the network. What it *can* contain is
hostile or manipulative text, and no schema catches that. Review does.

Loading packs from disk would trade that review for convenience, and the people who would
use it are contributors, who are already editing Swift in this repository.

If runtime loading is ever added, the validation rules still stand: validate against the
schema at load time and reject a failing pack wholesale with a diagnostic, never partially,
because a half-loaded pack produces exactly the coverage holes the lint exists to prevent.

### 7.4 Localization readiness

Humor does not translate; it gets rewritten. The format is built for that.

- **Locale packs are originals, not translations.** `de-DE` is a pack a German-speaking
  developer wrote, not a machine rendering of `en-US`. The schema has no `sourceId` field on
  purpose — there is nothing to trace back to.
- **Sparse locale packs are expected.** If the active locale's packs can't fill a context,
  the engine falls back to the base-locale pool with the tone ceiling clamped to `sarcastic`.
  Reading a ROAST in a second language reads meaner than it is; clamping is the cheap fix.
- **Slots are named, never positional.** `{branch}`, not `%@` or `%1$s`. Translators can
  reorder freely, and the lint's slot invariant still applies per locale.
- **Numbers and times format at fill time.** `{minutes}`, `{count}`, `{streak}` go through
  `NumberFormatter`; `{hour}` through `Date.FormatStyle` with the user's locale and 12/24h
  preference. Never `"\(minutes)"`.
- **Plurals use the `plural` map**, keyed by slot and CLDR category — the JSON equivalent of
  a `.stringsdict`. English needs `one`/`other`; Arabic, Polish and Russian need more, and the
  schema already accepts all six categories.
- **Length budget.** Translations run roughly 35% longer than English. `text` caps at 240, but
  localizable lines should target ≤ 180 so a translation still fits a notification body
  without truncation.
- **No concatenation, no glue punctuation.** A line is one sentence in the pack; the engine
  never joins fragments. Possessives and contractions live inside the localized string.
- **RTL-safe.** No ASCII art, no alignment that depends on LTR, no leading emoji adjacent to
  a slot (bidi reordering moves it).
- **The ALL-CAPS convention for NUCLEAR is English-specific.** Locales without case (Japanese,
  Arabic, Chinese) satisfy the W2 absurdity check via the `theatrical` flag plus their own
  emphasis conventions, and the lint accepts that path for non-cased scripts.

---

## 8. Open questions

1. **Activity inference accuracy is unmeasured.** The confidence thresholds in §6 are
   reasoned, not fitted. They need calibration against labeled sessions before the 0.85 tier
   can be trusted; until then, ship conservative (raise floors, accept more generic lines).
2. **The ledger's 72h cooldown assumes a ~40-line-per-context corpus.** With the 139-line
   starter corpus, a heavy user in one app will hit relaxation stage 2–3 within a week. Either
   the corpus grows or the cooldown shortens — instrument before choosing.
3. **NUCLEAR opt-in default.** Defaulting it off means most users never see the best lines;
   defaulting it on risks a bad first impression. Suggest: off by default, offered explicitly
   after the third completed break.
4. **`{project}` and `{branch}` from non-editor apps.** Only reliably available when a git
   collector is running. Lines requiring them are effectively editor-only today.
