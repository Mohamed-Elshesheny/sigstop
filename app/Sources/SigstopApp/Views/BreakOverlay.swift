import AppKit
import Foundation
import SigstopCore
import SwiftUI

// MARK: - The window

/// A panel that never takes the app to the front.
///
/// `.nonactivatingPanel` is the whole trick: the panel can be shown, and its controls can
/// be clicked, without `NSApp` activating. The build in your terminal keeps its focus,
/// keeps receiving keystrokes, and does not get yanked out from under a running command.
/// That is a hard requirement, not a nicety — an overlay that steals focus mid-build is an
/// overlay people uninstall the app over.
///
/// `canBecomeKey` is `true` so that *if* the user clicks the overlay, Escape works from
/// then on. It is never made key programmatically: the panel is shown with
/// `orderFrontRegardless()`, which orders without activating and without taking key.
final class NonActivatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape. `cancelOperation` is the responder-chain name for it, and using it rather
    /// than sniffing key codes means the standard Cmd-. also works.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// MARK: - The controller

/// Owns every overlay window: one full-screen break overlay per screen, plus the small
/// fallback prompt panel used when notifications are unavailable.
///
/// Screens come and go — a cable is pulled, a display sleeps, the user joins a meeting
/// and mirrors. So the set is rebuilt from `NSScreen.screens` on every
/// `didChangeScreenParameters`, and torn down completely on dismissal. A leftover panel
/// on a screen that no longer exists is a window the user cannot reach and cannot close.
@MainActor
final class BreakOverlayController {
    private var breakPanels: [NonActivatingPanel] = []
    private var fallbackPanel: NonActivatingPanel?
    private var screenObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private weak var model: AppModel?

    /// The virtual key code for Escape.
    private static let escapeKeyCode: UInt16 = 53

    // MARK: Break overlay

    /// Shows the overlay on every screen and installs a *local* Escape monitor.
    ///
    /// Escape works while sigstop happens to be the active application. A global monitor
    /// would catch it everywhere, but that needs Accessibility or Input Monitoring —
    /// permissions this app refuses to require for a convenience. So: Escape works when
    /// the overlay or the app has focus, and the SIGCONT button always works.
    func presentBreak(model: AppModel) {
        self.model = model
        dismissBreak()
        buildBreakPanels(model: model)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let model = self.model, !self.breakPanels.isEmpty else { return }
                self.tearDownBreakPanels()
                self.buildBreakPanels(model: model)
            }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == Self.escapeKeyCode else { return event }
            self?.model?.endBreak()
            return nil
        }
    }

    func dismissBreak() {
        tearDownBreakPanels()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// One panel per screen at `.statusBar` level: above the menu bar, and visible over
    /// another app's fullscreen space without joining it, so leaving the break does not
    /// shuffle spaces.
    private func buildBreakPanels(model: AppModel) {
        for screen in NSScreen.screens {
            let panel = NonActivatingPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.onCancel = { [weak model] in model?.endBreak() }
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isMovable = false
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false
            panel.level = .statusBar
            panel.collectionBehavior = [
                .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
            ]
            panel.setFrame(screen.frame, display: true)
            let hosting = NSHostingView(rootView: BreakOverlayView(model: model))
            hosting.sizingOptions = []
            panel.contentView = hosting
            panel.orderFrontRegardless()
            breakPanels.append(panel)
        }
    }

    private func tearDownBreakPanels() {
        for panel in breakPanels {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        breakPanels.removeAll()
    }

    // MARK: The prompt panel

    /// The app drawing a prompt itself, rather than asking macOS to. Two callers:
    ///
    ///   * escalation 4, `SIGSTOP` — the ladder's last rung is a panel by design
    ///     (docs/BREAK-DECISION.md §7.5), not a louder notification;
    ///   * the notification fallback of docs/PRIVACY.md §3.2, when there is no bundle or
    ///     the user declined notifications.
    ///
    /// It needs no permission, and it does **not** respect Do Not Disturb — which is
    /// exactly why it is reserved for those two cases, and why it is deliberately small,
    /// corner-anchored, dismissible and never fullscreen.
    ///
    /// Returns `false` only when there is no screen to draw on at all. Ordering the panel
    /// front is a request to the window server, not a fact about pixels: the caller
    /// confirms delivery afterwards with `promptPanelIsOnScreen` and re-asserts with
    /// `reassertPromptPanel()` if the request was not honoured.
    @discardableResult
    func presentPromptPanel(_ request: PromptRequest, message: RenderedMessage, model: AppModel) -> Bool {
        dismissPromptPanel()
        guard let screen = Self.promptScreen() else { return false }

        let panel = NonActivatingPanel(
            contentRect: Self.promptFrame(on: screen),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.onCancel = { [weak self] in self?.dismissPromptPanel() }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let hosting = NSHostingView(
            rootView: FallbackPromptView(
                request: request,
                message: message,
                onTake: { [weak model, weak self] in self?.dismissPromptPanel(); model?.acceptBreak() },
                onSnooze: { [weak model, weak self] in self?.dismissPromptPanel(); model?.snooze() },
                onSkip: { [weak model, weak self] in self?.dismissPromptPanel(); model?.skip() }
            )
        )
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.orderFrontRegardless()
        fallbackPanel = panel
        return true
    }

    /// Whether the prompt panel is composited on screen right now, according to the
    /// window server rather than to AppKit.
    ///
    /// `NSWindow.isVisible` reports what the app *asked for*. The status item's placeholder
    /// window on macOS 27 taught this project that the two can differ: a popover can be
    /// shown, sized, placed, opaque, and never drawn. The only report the app trusts is
    /// `kCGWindowIsOnscreen` for the panel's own window number, which is the same bit a
    /// screenshot sees. It needs no permission for the process's own windows.
    var promptPanelIsOnScreen: Bool {
        guard let panel = fallbackPanel else { return false }
        return Self.isOnScreen(windowNumber: panel.windowNumber)
    }

    /// Puts the prompt panel back where it belongs and orders it front again. Idempotent
    /// and cheap, so the model can call it on every tick until the window server agrees.
    func reassertPromptPanel() {
        guard let panel = fallbackPanel, let screen = Self.promptScreen() else { return }
        panel.setFrame(Self.promptFrame(on: screen), display: true)
        panel.orderFrontRegardless()
    }

    /// The screen with the menu bar. `NSScreen.main` is the screen of this app's key
    /// window, which a menu bar app rarely has; it falls back to the first screen, and
    /// only a machine with no display at all yields `nil`.
    private static func promptScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    /// Top-right corner of the visible area, inset, and clamped so the whole panel is on
    /// the screen whatever the visible area turns out to be.
    private static func promptFrame(on screen: NSScreen) -> NSRect {
        let size = FallbackPromptView.size
        let area = screen.visibleFrame
        let origin = NSPoint(
            x: max(area.minX, area.maxX - size.width - 18),
            y: max(area.minY, area.maxY - size.height - 18)
        )
        return NSRect(origin: origin, size: size)
    }

    private static func isOnScreen(windowNumber: Int) -> Bool {
        guard windowNumber > 0,
              let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowNumber)) as? [[String: Any]],
              let info = list.first
        else { return false }
        return (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }

    func dismissPromptPanel() {
        fallbackPanel?.orderOut(nil)
        fallbackPanel?.contentView = nil
        fallbackPanel?.close()
        fallbackPanel = nil
    }

    func dismissAll() {
        dismissBreak()
        dismissPromptPanel()
    }
}

// MARK: - The break view

/// The screen while the process is in state T.
///
/// Dimmed, not opaque: the work is still there, and the point of the name is that
/// nothing was lost. The palette is the fixed dark one because the backdrop is black
/// whatever the system appearance is. The countdown is the hero; under it a bar fills
/// with the break as it elapses, which is the mark's own idea — outline for the whole,
/// fill for how much has passed — turned on its side for a five-minute span.
struct BreakOverlayView: View {
    let model: AppModel

    @State private var hoveringResume = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.7))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    BrandMark(size: 16, fill: 0, tint: Brand.Dark.amber, fillTint: Brand.Dark.amber)
                    Text("STATE T · SIGSTOP")
                        .font(Brand.mono(12, weight: .semibold))
                        .tracking(3)
                        .foregroundStyle(Brand.Dark.amber)
                }

                countdown
                    .padding(.top, 30)

                Text(model.breakContent?.prompt ?? "Stand up.")
                    .font(Brand.sans(34, weight: .medium))
                    .foregroundStyle(Brand.Dark.fg)
                    .multilineTextAlignment(.center)
                    .padding(.top, 44)

                if let quest = model.breakContent?.quest {
                    Text(quest)
                        .font(Brand.sans(17))
                        .foregroundStyle(Brand.Dark.fgMuted)
                        .multilineTextAlignment(.center)
                        .padding(.top, 12)
                }

                resume
                    .padding(.top, 44)

                Text("Your process is stopped, not killed. Escape resumes.")
                    .font(Brand.mono(12))
                    .foregroundStyle(Brand.Dark.fgMuted)
                    .padding(.top, 20)
            }
            .padding(48)
        }
    }

    /// Driven by a timeline, not by a stored counter that something has to remember to
    /// advance. It reads `breakEndsAt` — a real timestamp — so a screen that was asleep
    /// for a minute shows the truth when it comes back.
    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let total = max(1, TimeInterval(model.settings.breakDurationMinutes * 60))
            let remaining = max(0, (model.breakEndsAt ?? context.date).timeIntervalSince(context.date))
            VStack(spacing: 14) {
                Text(Format.clock(remaining))
                    .font(Brand.mono(120, weight: .light))
                    .tracking(-4)
                    .monospacedDigit()
                    .foregroundStyle(Brand.Dark.fg)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("remaining")
                    Text("·")
                    Text("of \(Format.clock(total))")
                }
                .font(Brand.mono(12))
                .foregroundStyle(Brand.Dark.fgMuted)
                TransferBar(
                    fraction: min(1, max(0, 1 - remaining / total)),
                    tint: Brand.Dark.amber,
                    track: Brand.Dark.line,
                    height: 3
                )
                .frame(width: 320)
                .padding(.top, 4)
            }
        }
    }

    /// `SIGCONT`, filled amber with black text. The one action the screen exists for,
    /// and never labelled "Dismiss".
    private var resume: some View {
        Button(action: { model.endBreak() }) {
            Text("SIGCONT")
                .font(Brand.mono(13, weight: .semibold))
                .tracking(2.5)
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Brand.Dark.onAmber)
        .background(
            Brand.Dark.amber.opacity(hoveringResume ? 0.88 : 1),
            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
        .onHover { hoveringResume = $0 }
    }
}

// MARK: - The fallback prompt view

/// The corner prompt: the signal this rung is named after, the joke, and three
/// monospaced buttons. The signal is amber at levels 1–3 and red at level 4, which is
/// the only red in the product — `SIGSTOP` is the one rung that cannot be ignored, and
/// the colour says so once.
struct FallbackPromptView: View {
    let request: PromptRequest
    let message: RenderedMessage
    let onTake: () -> Void
    let onSnooze: () -> Void
    let onSkip: () -> Void

    /// The panel's size, owned by the view so the frame the controller opens and the
    /// frame the view lays out for are the same number. The hosting view is told not to
    /// size its window, because a `Spacer` in a flexible frame reports an ideal height
    /// the window would otherwise grow to.
    static let size = CGSize(width: 420, height: 176)

    private var isIncident: Bool { request.level == .incident }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StateDot(state: isIncident ? .alert : .suspend)
                Text(request.signal)
                    .font(Brand.mono(11, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(isIncident ? Brand.alert : Brand.amber)
                Text("L\(request.level.rawValue)")
                    .font(Brand.mono(10))
                    .foregroundStyle(Brand.fgFaint)
                Spacer()
                Text("\(DurationText.short(request.continuousWork)) continuous")
                    .font(Brand.mono(10))
                    .foregroundStyle(Brand.fgFaint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Brand.surface)

            Rule()

            VStack(alignment: .leading, spacing: 5) {
                if let title = message.title {
                    Text(title)
                        .font(Brand.sans(13, weight: .semibold))
                        .foregroundStyle(Brand.fg)
                }
                Text(message.text)
                    .font(Brand.sans(13))
                    .foregroundStyle(Brand.fg)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Spacer(minLength: 10)

            HStack(spacing: 6) {
                TerminalButton("Take it", style: .filled, shortcut: .defaultAction, action: onTake)
                    .fixedSize()
                if !request.snoozeOffered.isEmpty {
                    TerminalButton("Snooze · SIGALRM", action: onSnooze)
                        .fixedSize()
                }
                TerminalButton("Skip", style: .quiet, action: onSkip)
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(Brand.bgRaised)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Brand.lineHi, lineWidth: 1)
        )
    }
}
