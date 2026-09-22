import Foundation
import Testing
@testable import SigstopCore

private let utc = TimeZone(identifier: "UTC")!

private var fixedCalendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = utc
    c.locale = Locale(identifier: "en_US_POSIX")
    return c
}

private func date(hour: Int, minute: Int = 0, day: Int = 12) -> Date {
    var c = DateComponents()
    c.year = 2024; c.month = 6; c.day = day
    c.hour = hour; c.minute = minute
    c.timeZone = utc
    return fixedCalendar.date(from: c)!
}

private func bundleID(for app: AppKey) -> String? {
    switch app {
    case .cursor:    return "com.todesktop.230313mzl4w4u92"
    case .vscode:    return "com.microsoft.VSCode"
    case .zed:       return "dev.zed.Zed"
    case .xcode:     return "com.apple.dt.Xcode"
    case .jetbrains: return "com.jetbrains.intellij"
    case .terminal:  return "com.googlecode.iterm2"
    case .browser:   return "com.google.Chrome"
    case .figma:     return "com.figma.Desktop"
    case .docker:    return "com.docker.docker"
    case .slack:     return "com.tinyspeck.slackmacgap"
    case .discord:   return "com.hnc.Discord"
    case .unknown:   return "com.example.mystery"
    }
}

private func displayName(for app: AppKey) -> String {
    switch app {
    case .cursor: return "Cursor"
    case .vscode: return "Code"
    case .zed: return "Zed"
    case .xcode: return "Xcode"
    case .jetbrains: return "IntelliJ IDEA"
    case .terminal: return "iTerm2"
    case .browser: return "Google Chrome"
    case .figma: return "Figma"
    case .docker: return "Docker Desktop"
    case .slack: return "Slack"
    case .discord: return "Discord"
    case .unknown: return "Mystery"
    }
}

private func makeContext(
    app: AppKey = .cursor,
    activity: Activity = .aiCoding,
    confidence: Double = 0.92,
    minutes: Int = 95,
    minutesSinceBreak: Int? = nil,
    hour: Int = 14,
    day: Int = 12,
    escalation: EscalationLevel = .second,
    tone: Tone = .roast,
    project: String? = nil,
    branch: String? = nil,
    streaks: [StreakKey: Int] = [:],
    facts: [FactKey: FactValue] = [:],
    slotOverrides: [SlotKey: SlotValue] = [:],
    withheldSlots: Set<SlotKey> = []
) -> MessageContext {
    let dev = DeveloperContext(
        timestamp: date(hour: hour, day: day),
        application: AppIdentity(
            bundleID: bundleID(for: app), localizedName: displayName(for: app), pid: 501),
        activity: activity,
        confidence: Confidence(confidence),
        context: ActivityContext(projectName: project, branch: branch),
        continuousWork: TimeInterval(minutes * 60),
        timeSinceLastBreak: minutesSinceBreak.map { TimeInterval($0 * 60) }
    )
    return MessageContext(
        developer: dev,
        escalation: escalation,
        toneCeiling: tone,
        streaks: streaks,
        facts: facts,
        slotOverrides: slotOverrides,
        calendar: fixedCalendar,
        locale: Locale(identifier: "en_US_POSIX"),
        withheldSlots: withheldSlots
    )
}

private func makeEngine(
    corpus: Corpus = .bundled, seed: UInt64 = 42, ledger: RecencyLedger = RecencyLedger()
) -> MessageEngine {
    MessageEngine(corpus: corpus, ledger: ledger, rng: SeededRandomSource(seed: seed))
}

@Suite("Corpus")
struct CorpusTests {

    @Test("The bundled corpus decodes cleanly and is big enough to not repeat itself")
    func decodesCleanly() throws {
        let corpus = try Corpus.loadBundled()
        #expect(corpus.templates.count >= 130)
        #expect(corpus.packs.allSatisfy { $0.isSupported })
    }

    @Test("Template ids are unique")
    func idsAreUnique() {
        let ids = Corpus.bundled.templates.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Slot declarations and slot usage agree, in both directions")
    func slotInvariant() {
        for t in Corpus.bundled.templates {
            let declared = Set(t.allSlots)
            var used = Set<SlotKey>()
            for key in SlotKey.allCases {
                let token = "{\(key.rawValue)}"
                if t.text.contains(token) || (t.altText?.contains(token) ?? false) {
                    used.insert(key)
                }
            }
            #expect(declared == used, "slot mismatch in \(t.id): declared \(declared), used \(used)")
        }
    }

    @Test("A line that claims an activity is gated at 0.75 or higher and names something")
    func claimingTemplatesAreGated() {
        for t in Corpus.bundled.templates where t.claimsActivity {
            #expect(t.minConfidence >= 0.75, "\(t.id) claims an activity too cheaply")
            let names = t.when.contains {
                if case .app = $0 { return true }
                if case .activity = $0 { return true }
                return false
            }
            #expect(names, "\(t.id) claims an activity without an app or activity predicate")
        }
    }

    @Test("NUCLEAR never appears below level 3, and SIGKILL never appears at all")
    func toneEscalationMatrix() {
        for t in Corpus.bundled.templates {
            if t.tone == .nuclear {
                #expect(t.escalation.lowerBound >= .third, "\(t.id) is nuclear too early")
            }
            if t.tone == .friendly && t.escalation.upperBound == .incident {
                #expect(t.isFallback, "\(t.id) is friendly at L4 without being a fallback")
            }
            let lowered = t.text.lowercased()
            #expect(!lowered.contains("sigkill"), "\(t.id) mentions SIGKILL")
            #expect(t.text.count <= 240)
        }
    }

    @Test("The humor rails hold structurally across the corpus")
    func bannedLexicon() {
        let banned = [
            "fat", "ugly", "eye strain", "eyestrain", "carpal", "posture", "burnout",
            "burned out", "burnt out", "depress", "anxiet", "anxious", "addict",
            "incompetent", "stupid", "idiot", "performance review",
        ]
        for t in Corpus.bundled.templates {
            let text = (t.text + " " + (t.altText ?? "")).lowercased()
            for word in banned {
                #expect(!text.contains(word), "\(t.id) trips the rail '\(word)'")
            }
        }
    }

    @Test("The emergency pool is non-empty at every escalation level")
    func emergencyPoolCoverage() {
        for level in EscalationLevel.allCases {
            let usable = Corpus.emergencyPool.filter {
                $0.escalation.contains(level) && $0.tone == .friendly && $0.isFallback
            }
            #expect(!usable.isEmpty, "no emergency line at level \(level.rawValue)")
        }
    }

    @Test("A template round-trips through Codable unchanged")
    func codableRoundTrip() throws {
        let t = Corpus.bundled.templates.first { !$0.when.isEmpty && !$0.requiredSlots.isEmpty }
        let template = try #require(t)
        let data = try JSONEncoder().encode(template)
        let back = try JSONDecoder().decode(MessageTemplate.self, from: data)
        #expect(back == template)
    }
}

@Suite("MessageEngine selection")
struct MessageEngineSelectionTests {

    @Test("The same template is never returned twice in a row")
    func neverRepeatsBackToBack() {
        let engine = makeEngine()
        let ctx = makeContext()
        var previous: String?
        for i in 0..<80 {
            let id = engine.select(for: ctx).message.templateID
            #expect(id != previous, "repeated \(id) on iteration \(i)")
            previous = id
        }
    }

    @Test("A specific joke beats a generic one")
    func specificityBeatsGenerality() {
        let engine = makeEngine()
        let ctx = makeContext(app: .cursor, activity: .aiCoding, confidence: 0.92, minutes: 95)
        let result = engine.select(for: ctx)
        #expect(result.message.templateID.hasPrefix("cursor."),
                "picked \(result.message.templateID) over an eligible Cursor line")
        #expect(result.trace.bandIDs.allSatisfy { $0.hasPrefix("cursor.") })
    }

    @Test("Specificity holds for every app that has its own lines")
    func specificityHoldsPerApp() {
        let cases: [(AppKey, Activity, String)] = [
            (.cursor, .aiCoding, "cursor."),
            (.vscode, .coding, "vscode."),
            (.zed, .coding, "zed."),
            (.xcode, .debugging, "xcode."),
            (.jetbrains, .debugging, "jetbrains."),
            (.terminal, .terminalWork, "terminal."),
            (.figma, .browsing, "figma."),
            (.docker, .terminalWork, "docker."),
        ]
        for (app, activity, prefix) in cases {
            let engine = makeEngine()
            let ctx = makeContext(
                app: app, activity: activity, confidence: 0.92, minutes: 160,
                escalation: .third, tone: .roast)
            let id = engine.select(for: ctx).message.templateID
            #expect(id.hasPrefix(prefix), "\(app.rawValue) selected \(id)")
        }
    }

    @Test("Identical seeds produce identical sequences")
    func seededSelectionIsReproducible() {
        let ctx = makeContext()
        func run() -> [String] {
            let engine = makeEngine(seed: 1234)
            return (0..<25).map { _ in engine.select(for: ctx).message.templateID }
        }
        #expect(run() == run())
    }

    @Test("Selection is total: every context yields a renderable line")
    func alwaysReturnsSomething() {
        var checked = 0
        for app in AppKey.allCases {
            for activity in Activity.allCases {
                for minutes in [5, 40, 70, 120, 200] {
                    for level in EscalationLevel.allCases {
                        for confidence in [0.1, 0.45, 0.72, 0.95] {
                            let engine = makeEngine()
                            let ctx = makeContext(
                                app: app, activity: activity, confidence: confidence,
                                minutes: minutes, hour: (minutes % 24), escalation: level,
                                tone: .nuclear)
                            let text = engine.select(for: ctx).message.text
                            #expect(!text.isEmpty)
                            #expect(!text.contains("{"), "unfilled slot in: \(text)")
                            #expect(!text.contains("}"))
                            checked += 1
                        }
                    }
                }
            }
        }
        #expect(checked == AppKey.allCases.count * Activity.allCases.count * 5 * 4 * 4)
    }

    @Test("An empty corpus still returns a line instead of crashing")
    func emptyCorpusFallsBackToTheEmergencyPool() {
        let engine = makeEngine(corpus: Corpus(packs: []))
        let result = engine.select(for: makeContext())
        #expect(!result.message.text.isEmpty)
        #expect(result.message.isFallback)
        #expect(result.trace.relaxation == .emergency)
    }

    @Test("A pool of one never repeats into an empty result")
    func singleTemplateCorpusStaysTotal() {
        let only = MessageTemplate(
            id: "test.solo.only-line", text: "Only line.", tone: .friendly,
            category: "test_solo", escalation: EscalationLevel.first...EscalationLevel.incident)
        let corpus = Corpus(packs: [MessagePack(packId: "test.solo", messages: [only])])
        let engine = makeEngine(corpus: corpus)
        let ctx = makeContext(tone: .friendly)
        let first = engine.select(for: ctx).message.templateID
        let second = engine.select(for: ctx).message.templateID
        #expect(first == "test.solo.only-line")
        #expect(second != first)
    }
}

@Suite("Hard gates")
struct MessageEngineGatingTests {

    @Test("A template requiring {branch} is unselectable when the branch is unknown")
    func branchTemplateNeedsABranch() throws {
        let template = try #require(
            Corpus.bundled.templates.first { $0.requiredSlots.contains(.branch) })
        let resolver = SlotResolver()

        let without = makeContext(branch: nil)
        #expect(!resolver.canSatisfyRequired(template, in: without))
        #expect(resolver.fill(template, in: without) == nil)

        let with = makeContext(branch: "fix/retry-loop")
        #expect(resolver.canSatisfyRequired(template, in: with))
        let filled = try #require(resolver.fill(template, in: with))
        #expect(filled.contains("fix/retry-loop"))
    }

    @Test("Every template that needs a branch is selectable once one is known")
    func branchTemplatesComeAliveWithABranch() throws {
        let needBranch = Corpus.bundled.templates.filter { $0.requiredSlots.contains(.branch) }
        #expect(needBranch.count == 2)
        let resolver = SlotResolver()
        let ctx = makeContext(
            activity: .coding, confidence: 0.9, minutes: 95, hour: 23,
            branch: "main", facts: [.branchIsDefault: .bool(true)])
        for template in needBranch {
            #expect(resolver.canSatisfyRequired(template, in: ctx), "\(template.id)")
            let filled = try #require(resolver.fill(template, in: ctx))
            #expect(filled.contains("main"))
        }
    }

    @Test("Facts the collectors cannot answer keep their templates unselectable")
    func unansweredFactsKeepTheirTemplatesOut() {
        let engine = makeEngine()
        for _ in 0..<60 {
            let ctx = makeContext(
                activity: .coding, confidence: 0.9, minutes: 95, hour: 14,
                branch: "main", facts: [.branchIsDefault: .bool(true)])
            let result = engine.select(for: ctx)
            let template = Corpus.bundled.template(id: result.message.templateID)
            let needsUncommitted = template?.when.contains { predicate in
                if case .fact(.hasUncommittedChanges, _) = predicate { return true }
                return false
            }
            #expect(needsUncommitted != true)
        }
    }

    @Test("No selection ever names a branch when there is no branch")
    func branchIsNeverInvented() {
        for level in EscalationLevel.allCases {
            let engine = makeEngine()
            for _ in 0..<40 {
                let ctx = makeContext(
                    app: .browser, activity: .codeReview, confidence: 0.9, minutes: 120,
                    hour: 1, escalation: level, tone: .nuclear, branch: nil,
                    facts: [.branchIsDefault: .bool(true), .prOpenInForeground: .bool(true)])
                let result = engine.select(for: ctx)
                let template = Corpus.bundled.template(id: result.message.templateID)
                #expect(template?.requiredSlots.contains(.branch) != true)
            }
        }
    }

    @Test("A withheld slot cannot be named, and cannot be reintroduced by an override")
    func withheldSlotsNeverReachARenderedLine() {
        let secret = "acme-4417-billing"
        for level in EscalationLevel.allCases {
            let engine = makeEngine()
            for hour in [1, 14] {
                let ctx = makeContext(
                    activity: .coding, confidence: 0.9, minutes: 120, hour: hour,
                    escalation: level, tone: .nuclear, branch: secret,
                    facts: [.branchIsDefault: .bool(true)],
                    slotOverrides: [
                        .branch: SlotValue(text: secret, confidence: 0.99, provenance: .exact)
                    ],
                    withheldSlots: [.branch]
                )
                let result = engine.select(for: ctx)
                let template = Corpus.bundled.template(id: result.message.templateID)
                #expect(template?.allSlots.contains(.branch) != true)
                #expect(!result.message.text.contains(secret))
                #expect(SlotResolver().table(for: ctx)[.branch] == nil)
            }
        }
    }

    @Test("Nothing else stops a branch line being chosen")
    func branchLinesAreOtherwiseSelectable() {
        let ctx = makeContext(
            activity: .coding, confidence: 0.9, minutes: 120, hour: 1,
            escalation: .second, tone: .nuclear, branch: "acme-4417-billing")
        let resolver = SlotResolver()
        #expect(resolver.table(for: ctx)[.branch] != nil)
        let branchLines = Corpus.bundled.templates.filter { $0.allSlots.contains(.branch) }
        #expect(!branchLines.isEmpty)
        #expect(branchLines.contains { resolver.fill($0, in: ctx) != nil })
    }

    @Test("A template that claims an activity is unselectable below its minConfidence")
    func claimsActivityRespectsConfidence() throws {
        let claiming = try #require(
            Corpus.bundled.templates.first { $0.claimsActivity && $0.minConfidence >= 0.85 })
        let resolver = SlotResolver()
        let table = { (c: MessageContext) in resolver.table(for: c) }

        let low = makeContext(confidence: 0.84)
        #expect(!MessageEngine.confidenceGate(claiming, low))
        #expect(MessageEngine.hardGateRejection(
            claiming, low, ceiling: .nuclear, slots: resolver, table: table(low)) != nil)

        let high = makeContext(confidence: 0.9)
        #expect(MessageEngine.confidenceGate(claiming, high))
    }

    @Test("Low confidence never produces a specific claim about the activity")
    func lowConfidenceNeverClaims() {
        for confidence in [0.0, 0.2, 0.4, 0.55] {
            for app in AppKey.allCases {
                let engine = makeEngine()
                for _ in 0..<6 {
                    let ctx = makeContext(
                        app: app, activity: .debugging, confidence: confidence,
                        minutes: 130, escalation: .third, tone: .nuclear)
                    let id = engine.select(for: ctx).message.templateID
                    let template = Corpus.bundled.template(id: id)
                    if let template {
                        #expect(!template.claimsActivity,
                                "\(id) claimed an activity at confidence \(confidence)")
                        #expect(template.minConfidence <= confidence
                                || !template.usesActivityClaim)
                    }
                }
            }
        }
    }

    @Test("The user's tone preference is a hard ceiling")
    func toneCeilingIsRespected() {
        for ceiling in Tone.allCases {
            let engine = makeEngine()
            for level in EscalationLevel.allCases {
                for _ in 0..<25 {
                    let ctx = makeContext(
                        minutes: 150, escalation: level, tone: ceiling,
                        streaks: [.skippedToday: 5, .skippedConsecutive: 5])
                    let message = engine.select(for: ctx).message
                    #expect(message.tone <= ceiling,
                            "\(message.templateID) is \(message.tone) under a \(ceiling) ceiling")
                }
            }
        }
    }

    @Test("Escalation level filters the pool, in both directions")
    func escalationFiltering() {
        for level in EscalationLevel.allCases {
            let engine = makeEngine()
            for _ in 0..<30 {
                let ctx = makeContext(minutes: 140, escalation: level, tone: .nuclear)
                let id = engine.select(for: ctx).message.templateID
                let template = Corpus.bundled.template(id: id) ?? Corpus.emergencyPool
                    .first { $0.id == id }
                if let template {
                    #expect(template.escalation.contains(level),
                            "\(id) fired at level \(level.rawValue)")
                }
            }
        }
    }

    @Test("Level 1 never gets a roast, level 4 may")
    func toneMatrixPerLevel() {
        #expect(MessageEngine.effectiveToneCeiling(at: .first, userCeiling: .nuclear) == .sarcastic)
        #expect(MessageEngine.effectiveToneCeiling(at: .second, userCeiling: .nuclear) == .roast)
        #expect(MessageEngine.effectiveToneCeiling(at: .third, userCeiling: .roast) == .roast)
        #expect(MessageEngine.effectiveToneCeiling(at: .third, userCeiling: .nuclear) == .nuclear)
        #expect(MessageEngine.effectiveToneCeiling(at: .incident, userCeiling: .nuclear) == .nuclear)
        #expect(MessageEngine.effectiveToneCeiling(at: .incident, userCeiling: .friendly) == .friendly)

        let engine = makeEngine()
        for _ in 0..<40 {
            let ctx = makeContext(minutes: 140, escalation: .first, tone: .nuclear)
            #expect(engine.select(for: ctx).message.tone <= .sarcastic)
        }
    }

    @Test("NUCLEAR is rationed to once a day")
    func nuclearBudget() {
        let engine = makeEngine()
        var nuclearCount = 0
        for _ in 0..<60 {
            let ctx = makeContext(
                minutes: 200, escalation: .incident, tone: .nuclear,
                streaks: [.skippedToday: 6, .skippedConsecutive: 6])
            if engine.select(for: ctx).message.tone == .nuclear { nuclearCount += 1 }
        }
        #expect(nuclearCount <= Policy.nuclearPerDay)
    }

    @Test("A missing fact fails the predicate rather than defaulting to true")
    func missingFactIsNotTruth() {
        let p = Predicate.fact(.testsFailing, .isTrue)
        #expect(!p.holds(in: makeContext()))
        #expect(p.holds(in: makeContext(facts: [.testsFailing: .bool(true)])))
        #expect(!p.holds(in: makeContext(facts: [.testsFailing: .bool(false)])))
        #expect(!p.holds(in: makeContext(facts: [.testsFailing: .int(3)])))
    }

    @Test("An activity predicate matches ancestors but never siblings")
    func activityPredicateWalksTheTaxonomy() {
        let coding = Predicate.activity([.coding])
        let debugging = Predicate.activity([.debugging])
        #expect(coding.holds(in: makeContext(activity: .debugging, confidence: 0.9)))
        #expect(coding.holds(in: makeContext(activity: .testing, confidence: 0.9)))
        #expect(!debugging.holds(in: makeContext(activity: .testing, confidence: 0.9)))
        #expect(!debugging.holds(in: makeContext(activity: .documentation, confidence: 0.9)))
        #expect(!debugging.holds(in: makeContext(activity: .debugging, confidence: 0.3)))
        #expect(coding.holds(in: makeContext(activity: .debugging, confidence: 0.3)))
    }
}

@Suite("Recency ledger")
struct RecencyLedgerTests {

    @Test("A template shown today is not shown again today")
    func sameDayUniqueness() {
        let ledger = RecencyLedger()
        let engine = makeEngine(ledger: ledger)
        let ctx = makeContext(minutes: 140, escalation: .third, tone: .roast)
        var seen: [String] = []
        for _ in 0..<30 {
            let result = engine.select(for: ctx)
            if result.trace.relaxation <= .dropCooldown {
                #expect(!seen.contains(result.message.templateID),
                        "\(result.message.templateID) repeated inside one day")
            }
            seen.append(result.message.templateID)
        }
    }

    @Test("The relaxation ladder is climbed only when the pool is empty")
    func relaxationLadder() {
        let engine = makeEngine()
        let ctx = makeContext(app: .figma, activity: .browsing, confidence: 0.9, minutes: 100)
        let first = engine.select(for: ctx)
        #expect(first.trace.relaxation == .strict)

        var stages: [RelaxationStage] = [first.trace.relaxation]
        for _ in 0..<40 { stages.append(engine.select(for: ctx).trace.relaxation) }
        #expect(zip(stages, stages.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("Freshness recovers with time and a never-shown line is fully fresh")
    func freshnessCurve() {
        let ledger = RecencyLedger()
        let t = Corpus.bundled.templates[0]
        let now = date(hour: 12)
        #expect(ledger.freshness(t, now: now) == 1.0)

        ledger.record(t, at: now)
        #expect(ledger.freshness(t, now: now) == 0.05)
        #expect(ledger.freshness(t, now: now.addingTimeInterval(36 * 3600)) == 0.5)
        #expect(ledger.freshness(t, now: now.addingTimeInterval(200 * 3600)) == 1.0)
    }

    @Test("Purge drops old entries and keeps recent ones")
    func purge() {
        let ledger = RecencyLedger()
        let now = date(hour: 12)
        ledger.record(templateID: "a.b.c", category: "x", tone: .friendly,
                      at: now.addingTimeInterval(-40 * 86400))
        ledger.record(templateID: "d.e.f", category: "x", tone: .friendly, at: now)
        ledger.purge(before: now.addingTimeInterval(-Double(Policy.ledgerRetentionDays) * 86400))
        #expect(ledger.snapshot.map(\.templateID) == ["d.e.f"])
    }

    @Test("A ledger survives a round trip through its snapshot")
    func snapshotRoundTrip() throws {
        let ledger = RecencyLedger()
        ledger.record(templateID: "a.b.c", category: "x", tone: .roast, at: date(hour: 9))
        let data = try JSONEncoder().encode(ledger.snapshot)
        let entries = try JSONDecoder().decode([LedgerEntry].self, from: data)
        let restored = RecencyLedger(entries: entries)
        #expect(restored.lastShown(templateID: "a.b.c") == date(hour: 9))
    }
}

@Suite("Slot filling")
struct SlotFillerTests {

    @Test("Numbers and times are formatted, not interpolated")
    func rendersNumbersAndTimes() throws {
        let resolver = SlotResolver()
        let ctx = makeContext(minutes: 94, hour: 2)
        let table = resolver.table(for: ctx)
        #expect(table[.minutes]?.text == "94")
        #expect(table[.hour]?.text.contains("2") == true)
        #expect(table[.minutes]?.provenance == .derived)
    }

    @Test("An optional slot degrades; a required one does not")
    func degradationRules() throws {
        let resolver = SlotResolver()
        let ctx = makeContext(app: .terminal, project: nil)

        let optional = MessageTemplate(
            id: "test.slots.optional-project", text: "Still on {project}.", tone: .friendly,
            category: "test_slots", escalation: EscalationLevel.first...EscalationLevel.incident,
            optionalSlots: [.project])
        #expect(resolver.fill(optional, in: ctx) == "Still on this project.")

        let required = MessageTemplate(
            id: "test.slots.required-project", text: "Still on {project}.", tone: .friendly,
            category: "test_slots", escalation: EscalationLevel.first...EscalationLevel.incident,
            requiredSlots: [.project])
        #expect(resolver.fill(required, in: ctx) == nil)
    }

    @Test("altText carries the joke when an optional detail is missing")
    func altTextFallback() {
        let resolver = SlotResolver()
        let template = MessageTemplate(
            id: "test.slots.alt-text",
            text: "You have accepted {count} suggestions.",
            altText: "You have accepted a great many suggestions.",
            tone: .sarcastic, category: "test_slots",
            escalation: EscalationLevel.first...EscalationLevel.incident,
            optionalSlots: [.count])
        #expect(resolver.fill(template, in: makeContext()) ==
                "You have accepted a great many suggestions.")
        let withCount = makeContext(
            slotOverrides: [.count: SlotValue(text: "41", confidence: 0.99, provenance: .exact)])
        #expect(resolver.fill(template, in: withCount) == "You have accepted 41 suggestions.")
    }

    @Test("{activity} only ever prints the claimable activity")
    func activitySlotDegradesWithConfidence() throws {
        let resolver = SlotResolver()
        let sure = resolver.table(for: makeContext(activity: .debugging, confidence: 0.9))
        #expect(sure[.activity]?.text == Activity.debugging.displayName)

        let unsure = resolver.table(for: makeContext(activity: .debugging, confidence: 0.3))
        #expect(unsure[.activity]?.text == Activity.coding.displayName)
        #expect((unsure[.activity]?.confidence ?? 1) < SlotResolver.requiredFloor)
    }
}

@Suite("App identification")
struct AppKeyTests {

    @Test("Bundle identifiers resolve to the app the corpus talks about")
    func bundleIDMapping() {
        #expect(AppKey(bundleID: "com.todesktop.230313mzl4w4u92") == .cursor)
        #expect(AppKey(bundleID: "com.microsoft.VSCode") == .vscode)
        #expect(AppKey(bundleID: "dev.zed.Zed") == .zed)
        #expect(AppKey(bundleID: "com.apple.dt.Xcode") == .xcode)
        #expect(AppKey(bundleID: "com.jetbrains.intellij") == .jetbrains)
        #expect(AppKey(bundleID: "com.googlecode.iterm2") == .terminal)
        #expect(AppKey(bundleID: "com.google.Chrome") == .browser)
        #expect(AppKey(bundleID: "com.figma.Desktop") == .figma)
        #expect(AppKey(bundleID: "com.tinyspeck.slackmacgap") == .slack)
        #expect(AppKey(bundleID: nil) == .unknown)
        #expect(AppKey(bundleID: "") == .unknown)
        #expect(AppKey(bundleID: "com.example.whatever") == .unknown)
    }

    @Test("A bundle-less process is not confidently identified")
    func bundleLessProcessHasLowAppConfidence() {
        let dev = DeveloperContext(
            timestamp: date(hour: 11),
            application: AppIdentity(bundleID: nil, localizedName: "a.out", pid: 9),
            activity: .terminalWork,
            confidence: Confidence(0.8))
        let ctx = MessageContext(developer: dev, calendar: fixedCalendar)
        #expect(ctx.appConfidence < 0.35)
        let appTemplate = MessageTemplate(
            id: "test.gate.app-line", text: "Long stretch in the editor.", tone: .friendly,
            category: "test_gate", escalation: EscalationLevel.first...EscalationLevel.incident,
            minConfidence: 0.7, when: [.app([.vscode])])
        #expect(!MessageEngine.confidenceGate(appTemplate, ctx))
    }

    @Test("Bands are computed from real numbers, never from tick counts")
    func bands() {
        #expect(WorkBand(minutes: 0) == .short)
        #expect(WorkBand(minutes: 24) == .short)
        #expect(WorkBand(minutes: 25) == .focused)
        #expect(WorkBand(minutes: 89) == .deep)
        #expect(WorkBand(minutes: 90) == .marathon)
        #expect(WorkBand(minutes: 400) == .absurd)
        #expect(TimeBand(hour: 2) == .lateNight)
        #expect(TimeBand(hour: 6) == .earlyMorning)
        #expect(TimeBand(hour: 23) == .night)
        #expect(TimeBand(hour: 0) == .night)
        #expect(Weekday(calendarWeekday: 1) == .sun)
        #expect(Weekday(calendarWeekday: 7) == .sat)
    }
}
