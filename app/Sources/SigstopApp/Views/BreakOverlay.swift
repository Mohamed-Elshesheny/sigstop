import AppKit
import Foundation
import SigstopCore
import SwiftUI

final class NonActivatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
final class BreakOverlayController {
    private var breakPanels: [NonActivatingPanel] = []
    private var fallbackPanels: [NonActivatingPanel] = []
    private var screenObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private weak var model: AppModel?

    private static let escapeKeyCode: UInt16 = 53

    private static let overlayAppearance = NSAppearance(named: .darkAqua)

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
            let hosting = NSHostingView(
                rootView: BreakOverlayView(model: model).environment(\.locale, DisplayLocale.english(from: .current))
            )
            hosting.appearance = Self.overlayAppearance
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

    @discardableResult
    func presentPromptPanel(_ request: PromptRequest, message: RenderedMessage, model: AppModel) -> Bool {
        dismissPromptPanel()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return false }

        for screen in screens {
            let frame = screen.frame
            let panel = NonActivatingPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.onCancel = { [weak model, weak self] in
                self?.dismissPromptPanel()
                model?.ignorePrompt()
            }
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isMovable = false
            panel.hidesOnDeactivate = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.setFrame(frame, display: true)

            let hosting = NSHostingView(
                rootView: FallbackPromptView(
                    request: request,
                    message: message,
                    skipQuiet: model.policy.rearmAfterSkip,
                    onTake: { [weak model, weak self] in self?.dismissPromptPanel(); model?.acceptBreak() },
                    onSnooze: { [weak model, weak self] in self?.dismissPromptPanel(); model?.snooze() },
                    onIgnore: { [weak model, weak self] in self?.dismissPromptPanel(); model?.ignorePrompt() },
                    onSkip: { [weak model, weak self] in self?.dismissPromptPanel(); model?.skip() }
                )
                .environment(\.locale, DisplayLocale.english(from: .current))
            )
            hosting.appearance = Self.overlayAppearance
            hosting.sizingOptions = []
            panel.contentView = hosting
            panel.orderFrontRegardless()
            fallbackPanels.append(panel)
        }
        return !fallbackPanels.isEmpty
    }

    var promptPanelIsOnScreen: Bool {
        return fallbackPanels.contains { Self.isOnScreen(windowNumber: $0.windowNumber) }
    }

    func reassertPromptPanel() {
        for panel in fallbackPanels {
            panel.orderFrontRegardless()
        }
    }

    private static func cornerFrame(on screen: NSScreen) -> NSRect {
        let size = NSSize(width: 400, height: 208)
        let inset: CGFloat = 16
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.maxX - size.width - inset,
            y: visible.maxY - size.height - inset,
            width: size.width,
            height: size.height
        )
    }

    private static func promptScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    private static func isOnScreen(windowNumber: Int) -> Bool {
        guard windowNumber > 0,
              let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowNumber)) as? [[String: Any]],
              let info = list.first
        else { return false }
        return (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }

    func dismissPromptPanel() {
        for panel in fallbackPanels {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        fallbackPanels.removeAll()
    }

    func dismissAll() {
        dismissBreak()
        dismissPromptPanel()
    }
}

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
                    animated: false,
                    tint: Brand.Dark.amber,
                    track: Brand.Dark.line,
                    height: 3
                )
                .frame(width: 320)
                .padding(.top, 4)
            }
        }
    }

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

struct FallbackPromptView: View {
    let request: PromptRequest
    let message: RenderedMessage
    var skipQuiet: TimeInterval = 20 * 60
    let onTake: () -> Void
    var onSnooze: () -> Void = {}
    let onIgnore: () -> Void
    let onSkip: () -> Void

    private var isIncident: Bool { request.level == .incident }

    private var standsInForNotification: Bool {
        request.channel == .notification || request.channel == .notificationWithSound
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.78))
                .ignoresSafeArea()

            VStack(alignment: .center, spacing: 0) {
                HStack(spacing: 10) {
                    StateDot(state: isIncident ? .alert : .suspend)
                    Text(request.signal)
                        .font(Brand.mono(13, weight: .semibold))
                        .tracking(3)
                        .foregroundStyle(isIncident ? Brand.alert : Brand.Dark.amber)
                    Text("L\(request.level.rawValue)")
                        .font(Brand.mono(12))
                        .foregroundStyle(Brand.Dark.fgFaint)
                }

                Text("\(DurationText.short(request.continuousWork)) continuous")
                    .font(Brand.mono(12))
                    .foregroundStyle(Brand.Dark.fgFaint)
                    .padding(.top, 10)

                if let title = message.title {
                    Text(title)
                        .font(Brand.sans(20, weight: .semibold))
                        .foregroundStyle(Brand.Dark.fgMuted)
                        .padding(.top, 34)
                }

                Text(message.text)
                    .font(Brand.sans(38, weight: .medium))
                    .foregroundStyle(Brand.Dark.fg)
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 820, alignment: .center)
                    .padding(.top, message.title == nil ? 34 : 14)

                HStack(spacing: 14) {
                    TerminalButton("Take it", style: .filled, shortcut: .defaultAction, action: onTake)
                        .fixedSize()
                    if standsInForNotification {
                        if !request.snoozeOffered.isEmpty {
                            TerminalButton("Snooze (SIGALRM)", action: onSnooze)
                                .fixedSize()
                        }
                        TerminalButton("Skip, quiet for \(DurationText.short(skipQuiet))", action: onSkip)
                            .fixedSize()
                    }
                    TerminalButton("Ignore it", action: onIgnore)
                        .fixedSize()
                }
                .padding(.top, 44)

                Text("esc to ignore, it comes back in 90 seconds")
                    .font(Brand.mono(11))
                    .foregroundStyle(Brand.Dark.fgFaint)
                    .padding(.top, 18)
            }
            .padding(48)
        }
    }
}
