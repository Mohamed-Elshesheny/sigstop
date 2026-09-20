import AppKit
import SigstopCore
import SwiftUI

/// The process entry point.
///
/// Deliberately **not** `@main` on the `App` type. `SwiftUI.App.main()` installs an
/// `NSApplication` and never returns, which would make `--doctor` impossible to run
/// without a window server, and the whole value of `--doctor` is that a sceptic can run
/// it from a shell, pipe it, and paste it into an issue.
@main
enum SigstopEntryPoint {
    static func main() {
        if CommandLine.arguments.contains("--doctor") {
            runDoctorAndExit()
        }
        SigstopScene.main()
    }

    /// `dispatchMain()` rather than a semaphore: the collectors and the context engine are
    /// `@MainActor`-isolated, so blocking the main thread to wait for them would deadlock
    /// against the executor that has to run them.
    private static func runDoctorAndExit() -> Never {
        Task { @MainActor in
            await Doctor.run()
            exit(0)
        }
        dispatchMain()
    }
}

/// The scene exists only because `App` requires one. Every piece of UI this app has is
/// owned by `StatusItemController`, for a reason worth writing down:
///
/// `MenuBarExtra` never assigns its `NSStatusItem` an `autosaveName`. Without one, macOS
/// has nothing to persist the icon's position under, so the item cannot be placed, cannot
/// remember a place, and lands wherever the system puts it. On a machine running Ice,
/// Bartender or Dozer that is usually behind the divider, and the app looks like it
/// failed to launch. Owning the status item is the only way to fix that.
struct SigstopScene: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bare `swift run` builds have no Info.plist, so the activation policy is set here
        // too rather than silently being a normal app with a Dock icon.
        // The policy is re-applied from settings by the controller; this is only the
        // pre-settings default so a bare `swift run` never flashes a Dock icon.
        NSApp.setActivationPolicy(.accessory)
        controller = StatusItemController()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon of an app with no windows has to do something, and for a
    /// menu bar app the only thing it can usefully do is open Settings. Doing nothing
    /// reads as a hang.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.openSettings()
        return true
    }
}

// MARK: - Status item

/// Owns the status item and the panel that drops down from it.
///
/// The panel is a plain `NSPanel` that this controller sizes, positions and orders
/// itself, **not** an `NSPopover`, and the reason is specific to how the menu bar works
/// now. On macOS 27 (observed on 27.0) the status item's `NSStatusBarWindow` is a
/// placeholder: its window number is `0x1_0000_0000`, it is never on the active space,
/// and its pixels are hosted remotely inside the window server's own menu bar window.
/// `NSPopover.show(relativeTo:of:)` attaches the popover as a child of the anchor view's
/// window and orders it relative to that window, so the popover inherits a parent the
/// window server cannot order against. The result is a popover that is `isShown == true`,
/// correctly sized and placed, at the right level, fully opaque, and never composited:
/// `CGWindowListCopyWindowInfo` reports it `onscreen = false` for as long as it is "open".
/// Nothing about the popover's behaviour or the app's activation state changes that. A
/// panel ordered directly with `orderFrontRegardless()` has no parent to inherit from and
/// shows every time.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    /// The key macOS stores the icon's menu bar position under. It is derived from
    /// `autosaveName`, so the name has to stay stable across releases: change it and
    /// everyone's icon jumps back to wherever the system feels like.
    private static let autosaveName = "sigstop"
    private static var positionKey: String { "NSStatusItem Preferred Position \(autosaveName)" }

    /// Where to sit the very first time, in points from the right edge of the menu bar.
    /// Small enough to land in the always-visible zone rather than behind a menu bar
    /// manager's divider. Only ever written once: after that the number is the user's,
    /// because they moved it.
    private static let firstRunPosition = 128.0

    /// Points between the bottom of the menu bar and the top of the panel, and between
    /// the panel and the edge of the screen when the icon sits near it.
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
        Self.claimVisiblePositionOnFirstRun()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        item.autosaveName = Self.autosaveName
        item.behavior = .removalAllowed

        if let button = item.button {
            button.action = #selector(toggle)
            button.target = self
            // Mouse *down*, like a menu, so the toggle runs before anything else can react
            // to the click; and both buttons, so a right click opens the same panel rather
            // than nothing.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])

            let icon = PassthroughHostingView(rootView: StatusIcon(model: model))
            icon.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
            ])
        }

        // The panel follows the SwiftUI content's ideal size: the disclosure opens, the
        // action rows change with state, and the window has to grow and shrink with them
        // while staying hung from the menu bar.
        content.sizingOptions = [.preferredContentSize]
        content.onPreferredContentSizeChange = { [weak self] in self?.layoutPanel() }
        panel.contentViewController = content
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.dismiss() }

        applyActivationPolicy()
        model.onSettingsChanged = { [weak self] in self?.applyActivationPolicy() }
        model.start()
    }

    /// `.regular` puts the app in the Dock and the Cmd-Tab switcher; `.accessory` keeps it
    /// menu bar only. Changing this at runtime is supported and takes effect immediately.
    private func applyActivationPolicy() {
        let wanted: NSApplication.ActivationPolicy = model.settings.showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
    }

    /// Seed a position only when the user has never expressed one. Overwriting a stored
    /// value would mean moving somebody's icon out from under them on every launch.
    private static func claimVisiblePositionOnFirstRun() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: positionKey) == nil else { return }
        defaults.set(firstRunPosition, forKey: positionKey)
    }

    // MARK: Panel

    /// When the panel was last dismissed. A click on the icon while the panel is open
    /// could reach this controller twice, first as a focus change that dismisses the
    /// panel and then as the button's action; without the check the action would reopen
    /// what the focus change just closed, and the icon could never close the panel.
    private var dismissedAt = Date.distantPast

    @objc private func toggle() {
        if panel.isVisible {
            dismiss()
        } else if Date().timeIntervalSince(dismissedAt) > 0.2 {
            show()
        }
    }

    private func show() {
        model.refreshRollup(force: true)
        layoutPanel()
        // `orderFrontRegardless` orders without activating; `makeKey` on a
        // `.nonactivatingPanel` takes keyboard focus for Escape without taking the app
        // to the front. The frontmost app stays frontmost, which is also what lets
        // `windowDidResignKey` mean "the user clicked somewhere else".
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
        dismissedAt = Date()
    }

    /// Sizes the panel to its content and hangs it under the icon, kept on screen.
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

    /// Dismissal without permissions. A *global* monitor sees mouse events delivered to
    /// other apps, and unlike key events that needs no Accessibility or Input Monitoring
    /// grant; it covers clicks on the desktop, on another app's window and on other menu
    /// bar items. The panel also resigns key when another window takes focus, which
    /// `windowDidResignKey` turns into a dismissal. Escape is a local monitor because the
    /// panel is the key window while it is open, so the key event arrives here.
    private func installMonitors() {
        removeMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.dismiss()
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 53 = Escape
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

    // MARK: Settings

    func openSettings() {
        dismiss()

        if let existing = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "sigstop Settings"
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - The panel

/// The dropdown's window. `.nonactivatingPanel` lets it take keyboard focus without
/// activating the app; `canBecomeKey` is what makes Escape and `windowDidResignKey`
/// work at all, since a borderless window refuses key status by default.
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
        // NSPanel hides itself when the app deactivates by default. This app is never
        // active while the panel is open, so leaving that on would make the very first
        // deactivation notice — whenever it happened — close the panel under the user.
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        // The same level as the status item itself, so the panel sits above every
        // ordinary and floating window of every app, and over another app's full-screen
        // space without joining it.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape and Cmd-. through the responder chain.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Reports the SwiftUI content's ideal size as it changes, so the panel can follow it.
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

/// Popover-style chrome around the dropdown: the popover material behind the content,
/// continuous rounded corners, and a hairline edge. The window itself is transparent, so
/// its shadow follows this shape.
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

/// A hosted view that refuses every hit test.
///
/// Adding any subview to an `NSStatusItem`'s button silently breaks it: the subview wins
/// hit testing, the button never sees the mouse, and the action never fires. The symptom
/// is an icon that draws perfectly and does nothing when clicked. Returning nil here hands
/// every event back to the button, which is the thing that actually has the target/action.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Bridges the observable model into the status item's hosted icon.
private struct StatusIcon: View {
    let model: AppModel

    var body: some View {
        MenuBarIcon(fraction: model.workFraction, indicator: model.indicator)
    }
}

