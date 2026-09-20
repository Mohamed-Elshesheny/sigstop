import Foundation
import SigstopCore

/// What the break overlay says.
///
/// Deliberately tiny and local to the app layer. The message engine owns the *voice* of
/// an interruption — it has a corpus, a recency ledger and a tone ladder. This is the
/// opposite job: one steady line during the break itself, which should not be a joke and
/// should not vary with how annoyed the app is.
///
/// Copy rails, from CLAUDE.md §4.5 and docs/BREAK-DECISION.md §16:
///
///   * no medical claims, ever — this is a workflow tool, not a health product;
///   * "your posture", never "your health";
///   * never about the body beyond the mechanics of standing up and looking away;
///   * the resume control is `SIGCONT`. It is never labelled "Dismiss".
struct BreakContent: Sendable, Hashable {
    /// The one instruction. Plain, imperative, always true.
    let prompt: String
    /// Optional, and genuinely optional: nil when quests are switched off.
    let quest: String?

    /// The two prompts named in the product spec, plus a small number of variations that
    /// say the same two things. Nothing here is a claim about a body.
    static let prompts: [String] = [
        "Stand up.",
        "Look at something further away.",
        "Stand up. The stack is saved.",
        "Look out a window. Anything past arm's reach.",
        "Both feet on the floor, then stand.",
    ]

    /// Small, concrete, finishable inside the break. A quest is a nudge to leave the
    /// chair, not a task list and not a score.
    static let quests: [String] = [
        "Refill your water.",
        "Walk to the furthest room and come back.",
        "Open a window.",
        "Put the mug in the sink. Yes, that one.",
        "Stand somewhere you can see outside.",
        "Take the stairs to nowhere in particular.",
        "Say the last thing you were doing out loud. It will still be there.",
    ]

    /// Deterministic in `seed`, so the line does not reshuffle if the overlay redraws.
    static func make(for context: DeveloperContext, settings: SigstopSettings, seed: UInt64) -> BreakContent {
        var rng = SeededGenerator(seed: seed)
        let prompt = prompts.randomElement(using: &rng) ?? "Stand up."
        let quest = settings.breakQuestsEnabled ? quests.randomElement(using: &rng) : nil
        _ = context
        return BreakContent(prompt: prompt, quest: quest)
    }
}
