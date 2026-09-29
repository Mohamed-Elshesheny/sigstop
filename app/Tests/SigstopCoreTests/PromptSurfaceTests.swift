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

@Suite("the card stays under the menu bar, hidden or not")
struct PromptCardMenuBarTests {

    @Test("a visible frame that already stops under the menu bar is left alone")
    func visibleMenuBarNeedsNothing() {
        let visible = PromptCardPlacement.Box(x: 0, y: 87, width: 1728, height: 997)
        let clipped = PromptCardPlacement.belowMenuBar(visible, screenTop: 1117, hiddenMenuBar: 33)
        #expect(clipped == visible)
    }

    @Test("a hidden menu bar is reserved, so the card sits below where the bar slides in")
    func hiddenMenuBarIsReserved() {
        let visible = PromptCardPlacement.Box(x: 0, y: 87, width: 1728, height: 1030)
        let clipped = PromptCardPlacement.belowMenuBar(visible, screenTop: 1117, hiddenMenuBar: 33)
        #expect(clipped.maxY == 1117 - 33)
        #expect(clipped.y == visible.y)
        #expect(clipped.x == visible.x && clipped.width == visible.width)
        let card = PromptCardPlacement.place(width: 420, height: 180, in: clipped)
        #expect(card.maxY == 1117 - 33 - PromptCardPlacement.inset)
    }

    @Test("a bar taller than the frame cannot push the card off the bottom")
    func absurdMenuBarClampsToNothing() {
        let visible = PromptCardPlacement.Box(x: 0, y: 0, width: 800, height: 20)
        let clipped = PromptCardPlacement.belowMenuBar(visible, screenTop: 20, hiddenMenuBar: 40)
        #expect(clipped.height == 0)
        #expect(clipped.y == 0)
    }
}

@Suite("the card goes to the display of the window in front")
struct PromptCardDisplayTests {

    private static let primary = PromptCardPlacement.Box(x: 0, y: 0, width: 1920, height: 1080)
    private static let right = PromptCardPlacement.Box(x: 1920, y: 0, width: 2560, height: 1440)
    private static let above = PromptCardPlacement.Box(x: 0, y: 1080, width: 1920, height: 1080)
    private static let displays = [primary, right, above]

    @Test("a window on the second display picks the second display, wherever the pointer is")
    func windowOnTheSecondDisplay() {
        let window = PromptCardPlacement.Box(x: 2400, y: 200, width: 1200, height: 900)
        #expect(PromptCardPlacement.display(for: window, among: Self.displays) == 1)
    }

    @Test("a window straddling two displays goes where its centre is")
    func straddlingWindowFollowsItsCentre() {
        let mostlyPrimary = PromptCardPlacement.Box(x: 1500, y: 100, width: 800, height: 600)
        #expect(PromptCardPlacement.display(for: mostlyPrimary, among: Self.displays) == 0)
        let mostlyRight = PromptCardPlacement.Box(x: 1700, y: 100, width: 800, height: 600)
        #expect(PromptCardPlacement.display(for: mostlyRight, among: Self.displays) == 1)
    }

    @Test("a window whose centre hangs off every display goes where most of it is")
    func partlyOffscreenWindowFollowsItsOverlap() {
        let window = PromptCardPlacement.Box(x: -700, y: 100, width: 1000, height: 400)
        #expect(PromptCardPlacement.display(for: window, among: Self.displays) == 0)
    }

    @Test("a window on no display, or with no size, picks nothing so the pointer decides")
    func unplaceableWindowPicksNothing() {
        let offscreen = PromptCardPlacement.Box(x: -3000, y: -3000, width: 400, height: 300)
        #expect(PromptCardPlacement.display(for: offscreen, among: Self.displays) == nil)
        let empty = PromptCardPlacement.Box(x: 100, y: 100, width: 0, height: 0)
        #expect(PromptCardPlacement.display(for: empty, among: Self.displays) == nil)
        #expect(PromptCardPlacement.display(for: offscreen, among: []) == nil)
    }

    @Test("window-server bounds are flipped into screen coordinates around the primary display")
    func windowServerBoundsAreFlipped() {
        let cg = PromptCardPlacement.Box(x: 100, y: 50, width: 400, height: 300)
        let ns = cg.flippedVertically(primaryHeight: 1080)
        #expect(ns == PromptCardPlacement.Box(x: 100, y: 730, width: 400, height: 300))

        let aboveInCG = PromptCardPlacement.Box(x: 100, y: -900, width: 400, height: 300)
        let aboveInNS = aboveInCG.flippedVertically(primaryHeight: 1080)
        #expect(aboveInNS.y == 1680)
        #expect(PromptCardPlacement.display(for: aboveInNS, among: Self.displays) == 2)
    }
}
