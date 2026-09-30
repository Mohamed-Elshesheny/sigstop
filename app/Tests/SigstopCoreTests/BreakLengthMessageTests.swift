import Foundation
import Testing

@testable import SigstopCore

@Suite("messages say the break length the user set")
struct BreakLengthMessageTests {

    static let lengths = [1, 2, 5, 10, 15, 30, 60]

    static let spelled: [Int: String] = [
        1: "one minute", 2: "two minutes", 5: "five minutes", 10: "ten minutes",
        15: "fifteen minutes", 21: "twenty-one minutes", 30: "thirty minutes",
        45: "forty-five minutes", 60: "sixty minutes",
    ]

    static let determiners: Set<String> = [
        "a", "an", "the", "all", "every", "each", "full", "whole", "those", "these",
        "another", "next", "last", "first", "this", "that",
    ]

    static let pluralOnlyVerbs: Set<String> = [
        "are", "were", "have", "do", "don't", "aren't", "weren't", "haven't",
    ]

    static let pluralPronouns: Set<String> = ["them", "they", "those", "these", "their"]

    private static func calendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private static func context(
        breakMinutes: Int, locale: Locale = Locale(identifier: "en_US_POSIX")
    ) throws -> MessageContext {
        let when = try #require(
            calendar().date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 14)))
        let developer = DeveloperContext(
            timestamp: when,
            application: AppIdentity(
                bundleID: "com.microsoft.VSCode", localizedName: "Code", pid: 501),
            activity: .coding,
            confidence: Confidence(0.9),
            context: ActivityContext(projectName: "sigstop", branch: "main"),
            continuousWork: 95 * 60
        )
        return MessageContext(
            developer: developer,
            escalation: .third,
            settings: SigstopSettings(breakDurationMinutes: breakMinutes, tone: .nuclear),
            streaks: [.skippedToday: 4, .skippedConsecutive: 2, .takenToday: 1],
            facts: [.branchIsDefault: .bool(true)],
            calendar: calendar(),
            locale: locale
        )
    }

    private static var everyLine: [MessageTemplate] {
        Corpus.bundled.templates + Corpus.emergencyPool + [Corpus.lastResort]
    }

    private static func words(_ s: Substring) -> [String] {
        s.lowercased()
            .split { !($0.isLetter || $0 == "'") }
            .map(String.init)
    }

    @Test("the break length set in Settings reaches the message context")
    func settingsCarryTheLength() throws {
        let fifteen = try Self.context(breakMinutes: 15)
        #expect(fifteen.breakMinutes == 15)

        let plain = MessageContext(developer: fifteen.developer)
        #expect(plain.breakMinutes == SigstopSettings.default.breakDurationMinutes)
    }

    @Test("{breakLength} spells the length out with its unit, and is singular only at one")
    func spelledOut() throws {
        let resolver = SlotResolver()
        for (minutes, expected) in Self.spelled {
            let table = resolver.table(for: try Self.context(breakMinutes: minutes))
            #expect(table[.breakLength]?.text == expected, "at \(minutes)")
            #expect(table[.breakLength]?.provenance == .derived)
        }
        for minutes in 1...60 {
            let text = resolver.table(for: try Self.context(breakMinutes: minutes))[.breakLength]?.text ?? ""
            #expect(!text.contains { $0.isNumber }, "\(minutes) printed digits: \(text)")
            #expect(text.hasSuffix(minutes == 1 ? " minute" : " minutes"), "\(minutes): \(text)")
            #expect(!text.hasPrefix(" ") && !text.contains("  "), "\(minutes): \(text)")
        }
    }

    @Test("{breakSeconds} is a bare integer a shell would accept, in any locale")
    func secondsAreAShellArgument() throws {
        let resolver = SlotResolver()
        for locale in ["en_US", "de_DE", "ar_EG", "en_US_POSIX"] {
            let an = Locale(identifier: locale)
            #expect(resolver.table(for: try Self.context(breakMinutes: 5, locale: an))[.breakSeconds]?.text == "300")
            #expect(resolver.table(for: try Self.context(breakMinutes: 60, locale: an))[.breakSeconds]?.text == "3600")
        }
    }

    @Test("every line renders at every break length, and the grammar the slot relies on holds")
    func everyLineAtEveryLength() throws {
        let resolver = SlotResolver()
        var usesTheLength = 0
        for template in Self.everyLine {
            for source in [template.text] + (template.altText.map { [$0] } ?? []) {
                if source.contains("{breakLength}") { usesTheLength += 1 }
                Self.checkPlacement(of: "{breakLength}", in: source, id: template.id)
                if let range = source.range(of: "{breakSeconds}") {
                    #expect(source[..<range.lowerBound].hasSuffix("sleep "),
                            "\(template.id): {breakSeconds} is only a shell argument")
                }
            }
            for minutes in Self.lengths {
                let ctx = try Self.context(breakMinutes: minutes)
                let table = resolver.table(for: ctx)
                let isLastResort = template.id == Corpus.lastResort.id
                let rendered = isLastResort
                    ? template.text
                    : resolver.fill(template, table: table, family: ctx.appFamily)
                let text = try #require(rendered, "\(template.id) did not render at \(minutes)")
                #expect(!text.contains("{") && !text.contains("}"), "\(template.id) at \(minutes): \(text)")
                if template.text.contains("{breakLength}") {
                    let phrase = try #require(Self.spelled[minutes])
                    #expect(text.contains(phrase), "\(template.id) at \(minutes): \(text)")
                }
                if template.text.contains("{breakSeconds}") {
                    #expect(text.contains("sleep \(minutes * 60).") || text.contains("sleep \(minutes * 60) "),
                            "\(template.id) at \(minutes): \(text)")
                }
                #expect(!text.lowercased().contains("one minutes"), "\(template.id): \(text)")
            }
        }
        #expect(usesTheLength >= 60, "only \(usesTheLength) lines name the length")
    }

    private static func checkPlacement(of token: String, in source: String, id: String) {
        var searchFrom = source.startIndex
        while let range = source.range(of: token, range: searchFrom..<source.endIndex) {
            searchFrom = range.upperBound
            let before = source[..<range.lowerBound]
            let lead = before.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"")))
            let startsSentence = lead.isEmpty
                || ".!?".contains(lead.last ?? ".")
                || !lead.contains { $0.isLetter }
            #expect(!startsSentence, "\(id): \(token) starts a sentence, so it would print lowercase")

            if let previous = words(before).last {
                #expect(!determiners.contains(previous),
                        "\(id): '\(previous) \(token)' reads wrongly at one minute or at sixty")
            }

            let after = source[range.upperBound...]
            #expect(!after.hasPrefix("-"), "\(id): \(token) used as a hyphenated adjective")
            if let next = words(after).first {
                #expect(!pluralOnlyVerbs.contains(next),
                        "\(id): '\(token) \(next)' is plural, and one minute is not")
            }
            let pronouns = Set(words(after)).intersection(pluralPronouns)
            #expect(pronouns.isEmpty,
                    "\(id): '\(pronouns.sorted().joined(separator: ", "))' after \(token) points back at a plural")
        }
    }

    @Test("no line, in the corpus or the fallbacks, states a break length of its own")
    func noLiteralLength() throws {
        let many = "(?:two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|[0-9]+)"
        let patterns = [
            "\\btake (?:all |the |another )?\(many)\\b",
            "\\bback in \(many)\\b",
            "(?<![-\\w])(?:one|\(many))-minute\\b",
            "(?<![-\\w])five[- ]minutes?\\b",
            "\\bfor \(many)(?=\\s*[.,:;!?])",
            "\\bsleep [0-9]",
            "\\bshort break\\b",
        ]
        let regexes = try patterns.map { try NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        for template in Self.everyLine {
            for source in [template.text] + (template.altText.map { [$0] } ?? []) {
                let whole = NSRange(source.startIndex..., in: source)
                for regex in regexes {
                    let hit = regex.firstMatch(in: source, range: whole) != nil
                    #expect(!hit, "\(template.id) states a break length: \(source)")
                }
            }
        }
    }

    @Test("naming the break length earns a line no specificity")
    func lengthIsNotSpecificity() {
        let bare = MessageTemplate(
            id: "test.length.bare", text: "Stand up.", tone: .friendly, category: "test",
            escalation: EscalationLevel.first...EscalationLevel.incident)
        let named = MessageTemplate(
            id: "test.length.named", text: "Stand up for {breakLength}, or sleep {breakSeconds}.",
            tone: .friendly, category: "test",
            escalation: EscalationLevel.first...EscalationLevel.incident,
            requiredSlots: [.breakLength, .breakSeconds])
        #expect(Scorer.score(bare) == Scorer.score(named))
    }

    @Test("the engine prints the length from the context it was handed")
    func engineUsesTheContext() throws {
        let line = MessageTemplate(
            id: "test.length.engine", text: "Take {breakLength}.", tone: .friendly, category: "test",
            escalation: EscalationLevel.first...EscalationLevel.incident,
            requiredSlots: [.breakLength])
        let corpus = Corpus(packs: [MessagePack(packId: "test", messages: [line])])
        for (minutes, phrase) in [(1, "one minute"), (30, "thirty minutes")] {
            let engine = MessageEngine(corpus: corpus, rng: SeededRandomSource(seed: 7))
            let text = engine.select(for: try Self.context(breakMinutes: minutes)).message.text
            #expect(text == "Take \(phrase).")
        }
    }
}
