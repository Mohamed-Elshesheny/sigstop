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
public enum WorkBand: String, Codable, Sendable, CaseIterable, Hashable {
    case short
    case focused
    case deep
    case marathon
    case absurd

    public init(minutes: Int) {
        switch minutes {
        case ..<25:  self = .short
        case ..<50:  self = .focused
        case ..<90:  self = .deep
        case ..<150: self = .marathon
        default:     self = .absurd
        }
    }
}

public enum TimeBand: String, Codable, Sendable, CaseIterable, Hashable {
    case earlyMorning
    case morning
    case afternoon
    case evening
    case night
    case lateNight

    public init(hour: Int) {
        switch hour {
        case 5..<8:      self = .earlyMorning
        case 8..<12:     self = .morning
        case 12..<17:    self = .afternoon
        case 17..<21:    self = .evening
        case 21..<24, 0: self = .night
        default:         self = .lateNight
        }
    }
}
```

`WorkBand` and `TimeBand`, from `app/Sources/SigstopCore/Message/MessageContext.swift`. Beside them
are `AppKey` (`cursor`, `vscode`, `zed`, `xcode`, `jetbrains`, `terminal`, `browser`, `figma`,
`docker`, `slack`, `discord`, `unknown`), `AppFamily`, `Weekday`, `StreakKey`, `FactKey`,
`FactValue` and `FactMatch`. There is no `ActivityKind`: predicates and slots use `Activity`, the
detector's own enum (`docs/ACTIVITY-DETECTION.md` §3).

The one value type is `MessageContext`, in the same `MessageContext.swift`. It wraps the detector's
`DeveloperContext`:

```swift
public struct MessageContext: Sendable, Hashable {
    public var developer: DeveloperContext
    public var escalation: EscalationLevel
    public var toneCeiling: Tone
    public var streaks: [StreakKey: Int]
    public var facts: [FactKey: FactValue]
    public var slotOverrides: [SlotKey: SlotValue]
    public var calendar: Calendar
    public var locale: Locale
    public var appConfidenceOverride: Double?
    public var withheldSlots: Set<SlotKey>
```

`app`, `appFamily`, `appConfidence`, `activity`, `activityConfidence`, `continuousWorkMinutes`,
`minutesSinceLastBreak`, `workBand`, `timeBand` and `weekday` are computed from those fields.
`appConfidence` is 0.95 for a known app, 0.50 for an unknown bundle id and 0.20 with none, and
`activity` is the detector's `claimableActivity`, so below 0.6 it has already fallen back to the
parent.

### 1.2 Predicates

A template declares preconditions as a list of predicates. All predicates must hold
(conjunction). Disjunction lives *inside* a predicate, as a set — `app(in: [.vscode, .zed])`.
This keeps the language flat enough to validate in CI and to explain in a debug panel.

```swift
public enum Predicate: Sendable, Hashable, Codable {
    case app(Set<AppKey>)
    case appFamily(Set<AppFamily>)
    case activity(Set<Activity>)
    case workBand(Set<WorkBand>)
    case timeBand(Set<TimeBand>)
    case weekday(Set<Weekday>)
    case minutesSinceBreak(atLeast: Int)
    case streak(StreakKey, atLeast: Int)
    case fact(FactKey, FactMatch)

    public func holds(in ctx: MessageContext) -> Bool {
        switch self {
        case .app(let s):
            return s.contains(ctx.app)
        case .appFamily(let s):
            return s.contains(ctx.appFamily)
        case .activity(let s):
            var node: Activity? = ctx.activity
            while let n = node {
                if s.contains(n) { return true }
                node = n.parent
            }
            return false
        case .workBand(let s):
            return s.contains(ctx.workBand)
        case .timeBand(let s):
            return s.contains(ctx.timeBand)
        case .weekday(let s):
            return s.contains(ctx.weekday)
        case .minutesSinceBreak(let n):
            return ctx.minutesSinceLastBreak >= n
        case .streak(let key, let n):
            return ctx.streak(key) >= n
        case .fact(let key, let match):
            guard let v = ctx.facts[key] else { return false }
            switch (match, v) {
            case (.isTrue, .bool(let b)):                return b
            case (.isFalse, .bool(let b)):               return !b
            case (.intAtLeast(let n), .int(let i)):      return i >= n
            case (.equalsString(let s), .string(let t)): return s == t
            default:                                     return false
            }
        }
    }
```

`Predicate`, in `app/Sources/SigstopCore/Message/MessageTemplate.swift`. An `activity` predicate also
holds for a parent: a template for `coding` matches while you are debugging.

**A missing fact fails the predicate.** Absence is never treated as truth. This is the rule
that stops the engine claiming you are on `main` because the git collector hasn't reported yet.

### 1.3 Specificity weights

Specificity is what makes "a Cursor-specific joke beats a generic one" a property of the
system rather than a hope. Each predicate kind carries a weight reflecting how much of the
context it pins down:

```swift
public var specificity: Int {
    switch self {
    case .app:               return 40
    case .activity:          return 30
    case .fact:              return 25
    case .streak:            return 20
    case .appFamily:         return 15
    case .workBand:          return 12
    case .timeBand:          return 12
    case .minutesSinceBreak: return 8
    case .weekday:           return 5
    }
}
```

`Predicate.specificity`, in the same `MessageTemplate.swift`.

Rationale for the ordering: `app` is the strongest signal a reader perceives ("it knows I'm in
Cursor"), `activity` next ("it knows I'm debugging"). Set size does not reduce weight — a
template matching `[.vscode, .zed]` is only marginally less specific than one matching
`[.vscode]`, and penalising set size would push contributors to duplicate lines per app.

The score adds two structural bonuses on top of the predicate sum:

```swift
public enum Scorer {
    public static let slotBonus = 4
    public static let tightEscalationBonus = 6
    public static let bandTolerance = 10

    public static func score(_ t: MessageTemplate) -> Int {
        var s = t.when.reduce(0) { $0 + $1.specificity }
        s += slotBonus * t.requiredSlots.count
        if t.escalation.lowerBound == t.escalation.upperBound { s += tightEscalationBonus }
        s += t.authorPriority
        return s
    }
}
```

`Scorer`, in `MessageTemplate.swift`. The score depends on the template alone, and `bandTolerance`
lives here too.

A Cursor + aiCoding + marathon template scores `40 + 30 + 12 = 82` plus bonuses. A generic
`workBand(.marathon)` template scores `12`. The Cursor line wins by construction, and it wins
by enough that no randomness can flip it (see the band rule below).

### 1.4 The algorithm

```swift
public struct SelectionTrace: Sendable, Hashable {
    public var totalTemplates: Int = 0
    public var afterHardGates: Int = 0
    public var afterRecency: Int = 0
    public var relaxation: RelaxationStage = .strict
    public var topScore: Int = 0
    public var bandSize: Int = 0
    public var effectiveToneCeiling: Tone = .friendly
    public var bandIDs: [String] = []
    public var rejections: [String: RejectionReason] = [:]
}

public struct SelectionResult: Sendable, Hashable {
    public let message: RenderedMessage
    public let trace: SelectionTrace
}

public final class MessageEngine: @unchecked Sendable {
    public let corpus: Corpus
    public let ledger: RecencyLedger
    public let slots: SlotResolver
    private let rng: any RandomSource

    public init(
        corpus: Corpus = .bundled,
        ledger: RecencyLedger = RecencyLedger(),
        slots: SlotResolver = SlotResolver(),
        rng: any RandomSource = SystemRandomSource()
    ) {
        self.corpus = corpus
        self.ledger = ledger
        self.slots = slots
        self.rng = rng
    }
```

From `app/Sources/SigstopCore/Message/MessageEngine.swift`. Selection is `select(for:record:)`, which
takes a `MessageContext` and returns a `SelectionResult`.

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
public func freshness(_ t: MessageTemplate, now: Date) -> Double {
    guard let last = lastShown(templateID: t.id) else { return 1.0 }
    let hours = now.timeIntervalSince(last) / 3600
    let recovery = Double(t.cooldownHours ?? Policy.templateCooldownHours)
    guard recovery > 0 else { return 1.0 }
    return min(1.0, max(0.05, hours / recovery))
}
```

`RecencyLedger.freshness(_:now:)`, in `app/Sources/SigstopCore/Message/RecencyLedger.swift`, and the
sampling that uses it, `MessageEngine.weightedPick` in `MessageEngine.swift`:

```swift
func weightedPick(_ band: [MessageTemplate], now: Date) -> MessageTemplate {
    precondition(!band.isEmpty, "weightedPick requires a non-empty band")
    if band.count == 1 { return band[0] }

    let weights = band.map { t -> Double in
        let toneFactor = ledger.toneIsOverused(t.tone) ? Policy.toneRepeatWeightMultiplier : 1.0
        return max(0.0001, t.weight * ledger.freshness(t, now: now) * toneFactor)
    }
    let total = weights.reduce(0, +)
    guard total > 0, total.isFinite else { return band[0] }

    var target = rng.nextUniform() * total
    for (i, w) in weights.enumerated() {
        target -= w
        if target < 0 { return band[i] }
    }
    return band[band.count - 1]
}
```

Then cumulative-weight sampling over the band. Never-shown templates dominate naturally, so
a newly installed pack surfaces quickly without a special case.

**Step 5 — tie-break.** Exact float ties (and the deterministic test mode) break on a stable
hash so the same context on the same day yields the same line:

```swift
public static func tieBreakKey(_ t: MessageTemplate, ctx: MessageContext) -> UInt64 {
    let day = ctx.calendar.startOfDay(for: ctx.now).timeIntervalSince1970
    return StableHash.fnv1a("\(t.id)|\(Int(day))|\(ctx.escalation.rawValue)")
}
```

`MessageEngine.tieBreakKey`, in `MessageEngine.swift`. `StableHash.fnv1a` is FNV-1a over the id,
the start of the day and the level, so the key is the same on every launch.

Order: higher weight → lower `tieBreakKey` → lexicographic `id`. Fully deterministic, so the
golden tests in §8 can assert exact output.

**Step 6 — render.** Fill slots (§2), record to the ledger, return with the trace.

---

## 2. Slot filling

### 2.1 Typed slots

```swift
public enum SlotKey: String, Codable, Sendable, CaseIterable, Hashable {
    case app
    case minutes
    case project
    case branch
    case activity
    case streak
    case count
    case hour

    public var canDegrade: Bool {
        switch self {
        case .branch, .streak, .minutes, .count, .hour: return false
        case .app, .project, .activity:                 return true
        }
    }
}

public struct SlotValue: Sendable, Hashable, Codable {
    public let text: String
    public let confidence: Double
    public let provenance: Provenance

    public enum Provenance: String, Sendable, Codable, Hashable {
        case exact
        case derived
        case degraded
        case generic
    }

    public init(text: String, confidence: Double, provenance: Provenance) {
        self.text = text
        self.confidence = min(max(confidence, 0), 1)
        self.provenance = provenance
    }

    public var isHardEnoughForRequiredSlot: Bool {
        provenance == .exact || provenance == .derived
    }
}
```

From `app/Sources/SigstopCore/Message/SlotFiller.swift`. `canDegrade` is false for `branch`,
`streak`, `minutes`, `count` and `hour`.

### 2.2 Declaration is mandatory

Every template declares `requiredSlots` and `optionalSlots`. Lint (§8) enforces the
bidirectional invariant: every `{slot}` appearing in `text` is declared, and every declared
slot appears in `text`. This is the mechanism that guarantees **a template needing `{branch}`
is never selected when branch is unknown** — it isn't a runtime string check, it's a hard gate
in Step 1 that runs before the text is ever touched.

```swift
public func canSatisfyRequired(_ t: MessageTemplate, table: [SlotKey: SlotValue]) -> Bool {
    t.requiredSlots.allSatisfy { key in
        guard let v = table[key] else { return false }
        guard v.confidence >= Self.requiredFloor else { return false }
        return v.isHardEnoughForRequiredSlot
    }
}
```

`SlotResolver.canSatisfyRequired(_:table:)`, in the same `SlotFiller.swift`. `requiredFloor` is 0.70 and
`optionalFloor` 0.50. `fill(_:table:family:)` renders a template or returns `nil`.

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

Repetition is the failure mode that gets the app uninstalled. The ledger is therefore enforced as
a hard gate. It is not persistent: `AppModel` holds one `MessageEngine` with a fresh
`RecencyLedger`, nothing writes it to disk, and a relaunch starts it empty.

`RecencyLedger`, in `app/Sources/SigstopCore/Message/RecencyLedger.swift`, is a class, not a
protocol. It holds `LedgerEntry` values (template id, category, tone, time shown) in memory, answers
the lookups this section needs, and decides eligibility in `allows(_:at:now:calendar:)`.
`purge(before:)` exists and nothing calls it.

### 3.1 Policy

```swift
public enum Policy {
    public static let templateCooldownHours = 72
    public static let categoryCooldownMinutes = 45
    public static let lruWindow = 60
    public static let relaxedLRUWindow = 20
    public static let nuclearPerDay = 1
    public static let nuclearCooldownHours = 6
    public static let toneRepeatWindow = 3
    public static let toneRepeatWeightMultiplier = 0.4
    public static let sameDayRepeatMinimumHours = 6.0
    public static let ledgerRetentionDays = 30
}
```

`ledgerRetentionDays` is declared and nothing reads it.

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
public enum RelaxationStage: Int, Sendable, Codable, Hashable, CaseIterable, Comparable {
    case strict = 0
    case dropCategory = 1
    case shrinkLRU = 2
    case dropCooldown = 3
    case allowSameDay = 4
    case emergency = 5

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var lruWindow: Int {
        self >= .shrinkLRU ? Policy.relaxedLRUWindow : Policy.lruWindow
    }
    public var enforcesCategoryCooldown: Bool { self < .dropCategory }
    public var enforcesTemplateCooldown: Bool { self < .dropCooldown }
    public var enforcesSameDayUniqueness: Bool { self < .allowSameDay }
}
```

`RelaxationStage`, also in `RecencyLedger.swift`. At `allowSameDay` a same-day repeat still needs 6
hours since that show (`sameDayRepeatMinimumHours`).

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
public enum Tone: String, Sendable, Codable, CaseIterable, Hashable, Comparable {
    case friendly
    case sarcastic
    case roast
    case nuclear

    public var rank: Int {
        switch self {
        case .friendly: return 0
        case .sarcastic: return 1
        case .roast: return 2
        case .nuclear: return 3
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
```

The first lines of `Tone`, in `app/Sources/SigstopCore/Model/Settings.swift`. It also carries a
`displayName` and a one-line `blurb`.

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

`.github/scripts/check-corpus.py` runs on every push and pull request, as a step in
`.github/workflows/ci.yml`. It reads `app/Sources/SigstopCore/Message/corpus.json` and
`.github/lint/banned-lexicon.json`. Hard failures exit non-zero and fail the build;
warnings print and do not, because each has a false-positive mode a person has to judge.

**This section used to describe something else, and that is worth stating plainly**
because `CLAUDE.md` §4.5 points here as the thing enforcing the humour rails. It described
a `swift package corpus-lint` command plugin with twelve checks, four warnings, a JSON
Schema and a `Lint/banned-lexicon.json`, run on pull requests touching `docs/corpus-*.json`
or `Resources/packs/**`. None of it existed: no plugin, no schema, no lexicon, no packs
directory, no CI step, and the corpus is at neither of those paths. The rail that can
actually hurt somebody was enforced by a paragraph. What is below is what runs.

**Hard failures:**

| # | Check |
|---|---|
| L2 | `id` unique, and matches `^[a-z0-9]+(\.[a-z0-9-]+){2,}$`, which is the `<context>.<subject>.<slug>` convention every line already follows. |
| L3 | Slot invariant: every `{slot}` in `text`/`altText` is declared, and every declared slot is used. |
| L4 | `escalation.min <= escalation.max`, both in `1...4`. |
| L5 | Tone and escalation agree: `nuclear` requires `escalation.min >= 3`; `friendly` reaches rung 4 only if `isFallback`. |
| L6 | `minConfidence` in `0...1`. If `claimsActivity` is true, `minConfidence >= 0.75` **and** at least one `app` or `activity` predicate is present. |
| L7 | **Banned lexicon.** Case-insensitive regexes over `text`+`altText` across the six families §4.2 forbids. Each family carries a rationale that is printed with the failure, so a contributor is told which rail they hit rather than which regex. `.github/lint/banned-lexicon.json`, append-only. |
| L9 | `text` at most 240 characters. |

**Warnings:**

| # | Check |
|---|---|
| W1 | **Trait detector.** `/\byou(?:'re\| are)\s+(?:a\|an\|so\|such\|just)\b/i`. That grammar usually attaches a label to the *person*, which is rail 7. |
| W2 | **NUCLEAR absurdity.** A `nuclear` line must contain a shouted run of two or more consecutive all-caps words. Without one it is probably just mean. |
| W3 | Near-duplicate detection: token Jaccard at or above 0.6 against any other line. |

**What is not checked, and why**, rather than implied:

- **Schema validation (was L1).** There is no `message-pack-1.json` to validate against.
  The `$schema` key in the corpus points at a file that does not exist.
- **Product-name denylist (L8), coverage floor (L10), emergency pool (L11), weight and
  author priority ranges (L12).** These assume a multi-pack format with `appFamily`,
  `weight` and `authorPriority` fields. The shipped corpus is one pack and has none of
  them. When packs land, these come with them.
- **`theatrical` is no longer an exemption for W2.** The old text let a line skip the
  absurdity check by setting `"theatrical": true` "with a named reviewer", and the format
  has no reviewer field, so the flag was a free opt-out. All eleven nuclear lines set it,
  which means the check could not fire on anything. It is the shouted run or nothing now,
  and all eleven still pass.

**Every check above has been run against a deliberately broken copy of the corpus and
seen to fail.** A lint nobody has watched fail is a lint nobody should trust, and this one
started life as two regexes that were too broad: an earlier `\byou look\b` flagged
"the cursor keeps blinking in your peripheral vision after you look away", which is gaze
and not appearance. The script takes a path argument for exactly this reason.

The rubric items a machine cannot decide, §4.3's target, standup, bad-day and specificity
tests, stay human. `.github/PULL_REQUEST_TEMPLATE.md` asks for them.

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

Four levels, one per rung of the break engine's ladder. A rung is reached by leaving a prompt
unanswered, not by skipping: a skip closes the cycle, and the next cycle starts again at the first
rung.

```swift
public enum EscalationLevel: Int, Sendable, Codable, CaseIterable, Hashable, Comparable {
    case first = 1
    case second = 2
    case third = 3
    case incident = 4

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var next: EscalationLevel { EscalationLevel(rawValue: rawValue + 1) ?? .incident }
}
```

`EscalationLevel`, in `app/Sources/SigstopCore/Model/Settings.swift`. There is no
`EscalationPolicy` and no `ReminderOutcome`: the level a line is chosen for comes from the
`PromptRequest` being delivered (`docs/BREAK-DECISION.md` §11).

Per level, the message engine decides one thing, the tone ceiling
(`MessageEngine.effectiveToneCeiling`), and the user's own tone setting caps it further:

| | **L1 Nudge** | **L2 Insistent** | **L3 Confrontational** | **L4 Intervention** |
|---|---|---|---|---|
| Tone cap | `sarcastic` | `roast` | `roast` (`nuclear` if opted in) | `nuclear` |

Presentation, sound, the actions a prompt offers and the spacing between prompts belong to the break
engine, and `docs/BREAK-DECISION.md` §7.5, §9 and §11 describe what ships. The rows this table used
to carry for them, a 40% window, countdowns, snooze budgets per hour and longer spacing at L3 and
L4, were a design that was not built.

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

There is no `ConfidenceTier` type. The gate compares against numbers directly: 0.35 as the floor for
any claim, 0.60 as the least an app claim needs, and each template's own `minConfidence`.

Gate, evaluated in Step 1:

```swift
public static func confidenceGate(_ t: MessageTemplate, _ ctx: MessageContext) -> Bool {
    let usesActivity = t.usesActivityClaim
    let usesApp = t.usesAppPredicate

    if usesActivity && ctx.activityConfidence < t.minConfidence { return false }
    if usesApp && ctx.appConfidence < max(t.minConfidence, 0.60) { return false }

    if usesActivity && ctx.activityConfidence < 0.35 { return false }
    if usesApp && ctx.appConfidence < 0.35 { return false }
    return true
}
```

`MessageEngine.confidenceGate`, in `app/Sources/SigstopCore/Message/MessageEngine.swift`.
`usesActivityClaim` and `usesAppPredicate` are properties of `MessageTemplate`.

Recommended `minConfidence` by how specific the claim is:

| Claim the line makes | `minConfidence` | Example |
|---|---|---|
| Names an app *and* a fine-grained activity ("you've accepted 41 suggestions") | 0.85 | Cursor + aiCoding lines |
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

From `app/Sources/SigstopCore/Message/MessageTemplate.swift`, the stored fields of
`MessageTemplate`. `escalation` is decoded from `{min, max}`, and `minConfidence`, `weight` and
`authorPriority` are clamped when a template is built:

```swift
public struct MessageTemplate: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String?
    public let text: String
    public let altText: String?
    public let tone: Tone
    public let category: String
    public let escalation: ClosedRange<EscalationLevel>
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
```

and of a pack, `MessagePack` in the same `MessageTemplate.swift`:

```swift
public struct MessagePack: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let packId: String
    public let packVersion: String
    public let locale: String
    public let title: String?
    public let author: String?
    public let license: String?
    public let defaultWeight: Double?
    public let messages: [MessageTemplate]
```

`Corpus` flattens the packs whose `schemaVersion` is supported and drops repeated ids.
`Corpus.emergencyPool` is six lines compiled into the binary, and `Corpus.lastResort` is a seventh.

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
- **Numbers and times format at fill time, in English with Latin digits.** `{minutes}` and
  `{streak}` are formatted as numbers and `{hour}` through `Date.FormatStyle`, all with the
  locale `DisplayLocale.english(from:)` builds: English, Latin digits, and the user's region and
  12 or 24 hour clock. An Arabic or Persian Mac would otherwise put native digits inside an
  English sentence. Every clock and number the app prints uses the same locale: these slots,
  `WaitingLine`, the menu bar subtitle and every SwiftUI root. That is right for the one pack
  that ships, `en-US`, and a pack in another language would have to change it. Never
  `"\(minutes)"`.
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
2. **The ledger's 72h cooldown assumes a ~40-line-per-context corpus.** With the 187-line
   corpus, a heavy user in one app will hit relaxation stage 2–3 within a week. Either
   the corpus grows or the cooldown shortens — instrument before choosing.
3. **NUCLEAR opt-in default.** Defaulting it off means most users never see the best lines;
   defaulting it on risks a bad first impression. Suggest: off by default, offered explicitly
   after the third completed break.
4. **`{project}` and `{branch}` from non-editor apps.** Only reliably available when a git
   collector is running. Lines requiring them are effectively editor-only today.
