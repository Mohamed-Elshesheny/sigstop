import AppKit
import SigstopCore
import SwiftUI

@main
enum SigstopEntryPoint {
    static func main() {
        if CommandLine.arguments.contains("--doctor") {
            runDoctorAndExit()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-installer") {
            let args = CommandLine.arguments
            let stem = index + 1 < args.count ? args[index + 1] : "installer-backdrop"
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                InstallerBackdropRenderer.runAndExit(stem: stem)
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-panel") {
            let args = CommandLine.arguments
            let stem = index + 1 < args.count ? args[index + 1] : "panel"
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                PanelRenderer.runAndExit(stem: stem)
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-settings") {
            let args = CommandLine.arguments
            let pane = index + 1 < args.count ? args[index + 1] : "about"
            let stem = index + 2 < args.count ? args[index + 2] : "settings"
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                SettingsPaneRenderer.runAndExit(pane: pane, stem: stem)
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-badges") {
            let next = index + 1
            let stem = next < CommandLine.arguments.count ? CommandLine.arguments[next] : "badges"
            renderBadgesAndExit(stem: stem)
        }
        SigstopScene.main()
    }

    private static func renderBadgesAndExit(stem: String) -> Never {
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.prohibited)
            BadgeSheetRenderer.runAndExit(stem: stem)
        }
    }

    private static func runDoctorAndExit() -> Never {
        Task { @MainActor in
            await Doctor.run()
            exit(0)
        }
        dispatchMain()
    }
}

struct SigstopScene: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = StatusItemController()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.openSettings()
        return true
    }
}

@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private static let autosaveName = "sigstop"

    private static let itemLength: CGFloat = 26

    private static let panelGap = 6.0
    private static let screenInset = 8.0

    private let model = AppModel()
    private let item: NSStatusItem
    private let panel = MenuBarPanel()
    private lazy var content = PanelHostingController(
        rootView: PanelChrome(model: model, openSettings: { [weak self] in self?.openSettings() })
    )
    private var settingsWindow: NSWindow?
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    private var isDismissing = false

    override init() {
        item = NSStatusBar.system.statusItem(withLength: Self.itemLength)
        super.init()

        item.autosaveName = Self.autosaveName
        item.behavior = .removalAllowed

        Brand.apply(model.settings.appearance, pinning: item.button)
        model.onAppearanceChanged = { [weak self] preference in
            guard let self else { return }
            Brand.apply(preference, pinning: self.item.button)
            self.renderIcon()
        }

        if let button = item.button {
            button.action = #selector(toggle)
            button.target = self
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageOnly
            renderIcon()
            trackIcon()
        }

        content.sizingOptions = [.preferredContentSize]
        content.onPreferredContentSizeChange = { [weak self] in self?.layoutPanel() }
        panel.contentViewController = content
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.dismiss() }

        applyActivationPolicy()
        model.onSettingsChanged = { [weak self] in self?.applyActivationPolicy() }
        model.start()
    }

    private func applyActivationPolicy() {
        let wanted: NSApplication.ActivationPolicy = model.settings.showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
    }

    private var dismissedAt = Date.distantPast

    private func renderIcon() {
        let appearance = item.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let renderer = ImageRenderer(
            content: MenuBarIcon(fraction: model.workFraction, indicator: model.indicator, dark: isDark)
                .frame(width: 18, height: 18)
                .transaction { $0.animation = nil }
        )
        renderer.scale = item.button?.window?.backingScaleFactor ?? 2

        item.button?.toolTip = model.iconTooltip

        guard let image = renderer.nsImage else { return }
        image.isTemplate = false
        item.button?.image = image
    }

    private func trackIcon() {
        withObservationTracking {
            _ = model.workFraction
            _ = model.indicator
            _ = model.iconTooltip
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.renderIcon()
                self.trackIcon()
            }
        }
    }

    @objc private func toggle() {
        if panel.isVisible {
            dismiss()
        } else if Date().timeIntervalSince(dismissedAt) > 0.2 {
            show()
        }
    }

    private func show() {
        model.refreshRollup(force: true)
        if panel.contentView !== content.view {
            panel.contentView = content.view
        }
        layoutPanel()
        panel.orderFrontRegardless()
        panel.makeKey()
        item.button?.highlight(true)
        installMonitors()
    }

    private func dismiss() {
        guard panel.isVisible, !isDismissing else { return }
        isDismissing = true
        defer { isDismissing = false }
        removeMonitors()
        item.button?.highlight(false)
        panel.orderOut(nil)
        panel.contentView = nil
        dismissedAt = Date()
    }

    private func layoutPanel() {
        guard let button = item.button, let bar = button.window else { return }
        let anchor = bar.convertToScreen(button.convert(button.bounds, to: nil))
        var size = content.preferredContentSize
        if size.width < 1 || size.height < 1 {
            size = content.view.fittingSize
        }
        var origin = NSPoint(
            x: anchor.midX - size.width / 2,
            y: bar.frame.minY - Self.panelGap - size.height
        )
        let anchorCenter = NSPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(anchorCenter) } ?? NSScreen.main
        if let screen {
            let limit = screen.frame.insetBy(dx: Self.screenInset, dy: 0)
            origin.x = min(max(origin.x, limit.minX), limit.maxX - size.width)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
    }

    private func installMonitors() {
        removeMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.dismiss()
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.panel.isVisible else { return event }
            self.dismiss()
            return nil
        }
    }

    private func removeMonitors() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    private static func centredOrigin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return .zero }
        return NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.08
        )
    }

    func openSettings() {
        dismiss()

        if let existing = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let content = NSRect(x: 0, y: 0, width: 800, height: 620)
        let window = NSWindow(
            contentRect: content,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "sigstop Settings"
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window.isReleasedWhenClosed = false
        var frame = window.frameRect(forContentRect: content)
        frame.origin = Self.centredOrigin(for: frame.size)
        window.setFrame(frame, display: false)
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private final class MenuBarPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

private final class PanelHostingController: NSHostingController<PanelChrome> {
    var onPreferredContentSizeChange: (() -> Void)?

    override var preferredContentSize: NSSize {
        didSet {
            if preferredContentSize != oldValue {
                onPreferredContentSizeChange?()
            }
        }
    }
}

private struct PanelChrome: View {
    let model: AppModel
    let openSettings: () -> Void

    private static let cornerRadius = 12.0

    var body: some View {
        MenuBarView(model: model, openSettings: openSettings)
            .background(PopoverMaterial())
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
    }
}

private struct PopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
