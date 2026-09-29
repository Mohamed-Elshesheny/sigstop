import Foundation
import Testing

@testable import SigstopCore

@Suite("the first two rungs are a card, the last two cover the screen")
struct PromptSurfaceTests {

    @Test("SIGTSTP and SIGINT are drawn as a card")
    func lowRungsAreACard() {
        #expect(PromptSurface(level: .first) == .card)
        #expect(PromptSurface(level: .second) == .card)
    }

    @Test("SIGTERM and SIGSTOP keep the full-screen panel")
    func highRungsCoverTheScreen() {
        #expect(PromptSurface(level: .third) == .fullScreen)
        #expect(PromptSurface(level: .incident) == .fullScreen)
    }

    @Test("the card sits in the top-right corner of the visible frame, inset on both sides")
    func cardSitsTopRight() {
        let visible = PromptCardPlacement.Box(x: 1512, y: 0, width: 1920, height: 1055)
        let frame = PromptCardPlacement.place(width: 420, height: 180, in: visible)
        #expect(frame.maxX == visible.maxX - PromptCardPlacement.inset)
        #expect(frame.maxY == visible.maxY - PromptCardPlacement.inset)
        #expect(frame.width == 420)
        #expect(frame.height == 180)
        #expect(visible.contains(frame))
    }

    @Test("a card taller than the display is pinned inside the visible frame, not pushed off it")
    func tallCardStaysOnScreen() {
        let visible = PromptCardPlacement.Box(x: 0, y: 25, width: 800, height: 100)
        let frame = PromptCardPlacement.place(width: 420, height: 400, in: visible)
        #expect(visible.contains(frame))
        #expect(frame.y == visible.y)
        #expect(frame.maxX == visible.maxX - PromptCardPlacement.inset)
    }
}
