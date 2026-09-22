import Foundation
import SigstopCore

struct BreakContent: Sendable, Hashable {
    let prompt: String
    let quest: String?

    static let prompts: [String] = [
        "Stand up.",
        "Look at something further away.",
        "Stand up. The stack is saved.",
        "Look out a window. Anything past arm's reach.",
        "Both feet on the floor, then stand.",
    ]

    static let quests: [String] = [
        "Refill your water.",
        "Walk to the furthest room and come back.",
        "Open a window.",
        "Put the mug in the sink. Yes, that one.",
        "Stand somewhere you can see outside.",
        "Take the stairs to nowhere in particular.",
        "Say the last thing you were doing out loud. It will still be there.",
    ]

    static func make(for context: DeveloperContext, settings: SigstopSettings, seed: UInt64) -> BreakContent {
        var rng = SeededGenerator(seed: seed)
        let prompt = prompts.randomElement(using: &rng) ?? "Stand up."
        let quest = settings.breakQuestsEnabled ? quests.randomElement(using: &rng) : nil
        _ = context
        return BreakContent(prompt: prompt, quest: quest)
    }
}
