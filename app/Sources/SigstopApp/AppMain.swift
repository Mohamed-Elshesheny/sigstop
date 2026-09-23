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
            let stem = renderStem(at: index + 1, or: "installer-backdrop")
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                InstallerBackdropRenderer.runAndExit(stem: stem)
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-panel") {
            let stem = renderStem(at: index + 1, or: "panel")
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                PanelRenderer.runAndExit(stem: stem)
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-settings") {
            let args = CommandLine.arguments
            let pane = index + 1 < args.count ? args[index + 1] : "about"
            let stem = renderStem(at: index + 2, or: "settings")
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                SettingsPaneRenderer.runAndExit(pane: pane, stem: stem)
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-prompt") {
            let args = CommandLine.arguments
            let stem = renderStem(at: index + 1, or: "prompt")
            let id = index + 2 < args.count ? args[index + 2] : "cursor.ai.tab-tab-tab"
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                PromptRenderer.runAndExit(stem: stem, templateID: id)
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-badges") {
            renderBadgesAndExit(stem: renderStem(at: index + 1, or: "badges"))
        }
        MainActor.assumeIsolated {
            guard InstanceLock.acquire(in: AppPaths.storageRoot) else {
                FileHandle.standardError.write(Data("sigstop is already running, so this copy is leaving.\n".utf8))
                exit(0)
            }
        }
        SigstopScene.main()
    }

    private static func renderStem(at position: Int, or fallback: String) -> String {
        let args = CommandLine.arguments
        let stem = position < args.count ? args[position] : fallback
        let parts = stem.split(separator: "/", omittingEmptySubsequences: false)
        guard !stem.isEmpty, !stem.hasPrefix("/"), !stem.hasPrefix("~"), !parts.contains("..") else {
            FileHandle.standardError.write(Data("render output has to be a relative path below the current folder, not \(stem)\n".utf8))
            exit(2)
        }
        return stem
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
        panel.contentView = nil
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.dismiss() }

        applyActivationPolicy()
        model.onSettingsChanged = { [weak self] in self?.applyActivationPolicy() }
        model.start()
        if CommandLine.arguments.contains("--bench-break") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.model.takeBreakNow()
            }
        }
    }

    private func applyActivationPolicy() {
        let wanted: NSApplication.ActivationPolicy = model.settings.showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
    }

    private var dismissedAt = Date.distantPast

    private struct IconKey: Equatable {
        let step: Int
        let indicator: IndicatorState
        let dark: Bool
        let scale: CGFloat
    }

    private var lastIconKey: IconKey?

    private func renderIcon() {
        let appearance = item.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let tooltip = model.iconTooltip
        if item.button?.toolTip != tooltip { item.button?.toolTip = tooltip }

        let scale = item.button?.window?.backingScaleFactor ?? 2
        let key = IconKey(
            step: Int((model.workFraction * 64).rounded()),
            indicator: model.indicator,
            dark: isDark,
            scale: scale
        )
        guard key != lastIconKey else { return }
        lastIconKey = key

        let renderer = ImageRenderer(
            content: MenuBarIcon(fraction: Double(key.step) / 64, indicator: key.indicator, dark: isDark)
                .frame(width: 18, height: 18)
                .transaction { $0.animation = nil }
        )
        renderer.scale = scale

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
        guard notification.object as? NSWindow === panel else { return }
        dismiss()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        window.contentViewController = nil
        settingsWindow = nil
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
        model.refreshRollup(force: true)

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
        window.contentViewController = NSHostingController(
            rootView: SettingsView(model: model).environment(\.locale, DisplayLocale.english(from: .current))
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
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
            .environment(\.locale, DisplayLocale.english(from: .current))
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

@MainActor
enum InstanceLock {
    private static var held: Int32 = -1

    static func acquire(in root: URL) -> Bool {
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let fd = open(
            root.appendingPathComponent(FileEventStore.lockFileName).path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard fd >= 0 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let taken = errno == EWOULDBLOCK
            close(fd)
            return !taken
        }
        if held >= 0 { close(held) }
        held = fd
        return true
    }
}
