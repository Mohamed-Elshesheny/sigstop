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

    // MARK: Break overlay

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

        // Escape while sigstop happens to be the active application. A *global* monitor
        // would catch it everywhere, but that needs Accessibility or Input Monitoring —
        // permissions this app refuses to require for a convenience. So: Escape works when
        // the overlay or the app has focus, and the SIGCONT button always works.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // 53 = Escape
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
            // Above the menu bar, and visible over another app's fullscreen space —
            // without joining it, so leaving the break does not shuffle spaces.
            panel.level = .statusBar
            panel.collectionBehavior = [
                .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
            ]
            panel.setFrame(screen.frame, display: true)
            panel.contentView = NSHostingView(rootView: BreakOverlayView(model: model))
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
    func presentPromptPanel(_ request: PromptRequest, message: RenderedMessage, model: AppModel) {
        dismissPromptPanel()
        guard let screen = NSScreen.main else { return }

        let size = NSSize(width: 380, height: 150)
        let origin = NSPoint(
            x: screen.visibleFrame.maxX - size.width - 18,
            y: screen.visibleFrame.maxY - size.height - 18
        )
        let panel = NonActivatingPanel(
            contentRect: NSRect(origin: origin, size: size),
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
        panel.contentView = NSHostingView(
            rootView: FallbackPromptView(
                request: request,
                message: message,
                onTake: { [weak model, weak self] in self?.dismissPromptPanel(); model?.acceptBreak() },
                onSnooze: { [weak model, weak self] in self?.dismissPromptPanel(); model?.snooze() },
                onSkip: { [weak model, weak self] in self?.dismissPromptPanel(); model?.skip() }
            )
        )
        panel.orderFrontRegardless()
        fallbackPanel = panel
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

struct BreakOverlayView: View {
    let model: AppModel

    var body: some View {
        ZStack {
            // Dimmed, not opaque: the work is still there, and the point of the name is
            // that nothing was lost.
            Rectangle()
                .fill(.black.opacity(0.62))
                .ignoresSafeArea()

            VStack(spacing: 26) {
                Text("SIGSTOP")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(.white.opacity(0.55))

                countdown

                Text(model.breakContent?.prompt ?? "Stand up.")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                if let quest = model.breakContent?.quest {
                    Text(quest)
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }

                Button(action: { model.endBreak() }) {
                    Text("SIGCONT")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .background(.white.opacity(0.14), in: Capsule())
                .foregroundStyle(.white)
                .padding(.top, 6)

                Text("Your process is stopped, not killed. Escape resumes.")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(48)
        }
    }

    /// The countdown is driven by a timeline, not by a stored counter that something has
    /// to remember to advance. It reads `breakEndsAt` — a real timestamp — so a screen
    /// that was asleep for a minute shows the truth when it comes back.
    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, (model.breakEndsAt ?? context.date).timeIntervalSince(context.date))
            Text(Format.clock(remaining))
                .font(.system(size: 76, weight: .thin, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
    }
}

// MARK: - The fallback prompt view

struct FallbackPromptView: View {
    let request: PromptRequest
    let message: RenderedMessage
    let onTake: () -> Void
    let onSnooze: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(request.signal)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(DurationText.short(request.continuousWork))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let title = message.title {
                Text(title).font(.headline)
            }
            Text(message.text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button("Take it", action: onTake).keyboardShortcut(.defaultAction)
                if !request.snoozeOffered.isEmpty {
                    Button("Snooze (SIGALRM)", action: onSnooze)
                }
                Button("Skip", action: onSkip)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }
}
