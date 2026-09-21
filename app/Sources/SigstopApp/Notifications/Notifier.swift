import Foundation
import SigstopCore
/// `@preconcurrency` because `UNNotificationSettings` is not `Sendable` in the macOS 15
/// SDK, so `await center.notificationSettings()` is an error on Xcode 16.4 and compiles
/// clean on newer toolchains. This built here and failed in CI on its first run, which is
/// the whole reason CI builds against the SDK most people actually have.
@preconcurrency import UserNotifications

/// What the developer did with a delivered notification.
enum PromptResponse: Sendable, Hashable {
    case take
    case snooze
    case skip
}

/// `UNUserNotificationCenter`, and nothing else.
///
/// Three things this type deliberately does **not** do:
///
/// 1. **It does not cap anything.** The daily cap, the per-cycle cap, the minimum spacing
///    and the ignore backoff are all enforced by `InterruptionPolicy` before a
///    `deliverPrompt` effect is ever produced. A second cap here would be a second,
///    disagreeing source of truth, and the one that silently won would be this one.
/// 2. **It does not ask for authorization at launch.** docs/PRIVACY.md §3.2 says the
///    prompt appears at the first break, not at startup, and that is a promise about the
///    first ten seconds of the app's life.
/// 3. **It does not decide anything.** It renders a `PromptRequest` the engine produced
///    and reports what the user pressed.
///
/// When notifications are unavailable, no bundle (a `swift run` build), or the user said
/// no, `onFallbackNeeded` fires and the app draws its own panel instead. That fallback is
/// documented in §3.2 and needs no permission at all.
@MainActor
final class Notifier: NSObject {

    /// Category identifiers, one per escalation rung, because the action set narrows as
    /// the ladder climbs: snooze stops being offered once the engine stops offering it.
    private enum Category {
        static let full = "dev.sigstop.prompt.full"
        static let noSnooze = "dev.sigstop.prompt.nosnooze"
    }

    private enum Action {
        static let take = "dev.sigstop.action.take"
        static let snooze = "dev.sigstop.action.snooze"
        static let skip = "dev.sigstop.action.skip"
    }

    var onResponse: ((PromptResponse) -> Void)?
    var onStateChange: ((AppModel.NotificationAvailability) -> Void)?
    var onFallbackNeeded: ((PromptRequest, RenderedMessage) -> Void)?

    private var center: UNUserNotificationCenter?
    private var registered = false
    private var authorizationAsked = false
    private var delivered: [CycleID: Set<String>] = [:]

    override init() {
        super.init()
    }

    // MARK: - Delivery

    func deliver(_ request: PromptRequest, message: RenderedMessage) {
        guard let center = resolveCenter() else {
            onStateChange?(
                .unavailable(
                    "Notifications need a real .app bundle, this build is running as a "
                        + "bare executable. Run `make run` for the bundled app. Falling back "
                        + "to the app's own panel."
                )
            )
            onFallbackNeeded?(request, message)
            return
        }
        registerCategoriesIfNeeded(center)

        let identifier = self.identifier(for: request)
        delivered[request.cycle, default: []].insert(identifier)

        let content = UNMutableNotificationContent()
        content.title = message.title ?? request.signal
        content.body = message.text
        content.categoryIdentifier = request.snoozeOffered.isEmpty ? Category.noSnooze : Category.full
        content.interruptionLevel = Self.interruptionLevel(for: request.level)
        content.threadIdentifier = "dev.sigstop.cycle.\(request.cycle.rawValue)"
        if request.channel == .notificationWithSound {
            content.sound = .default
        }

        let notification = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil
        )

        Task { [weak self] in
            guard let self else { return }
            guard await self.ensureAuthorized(center) else {
                self.onFallbackNeeded?(request, message)
                return
            }
            do {
                try await center.add(notification)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let shown = await center.deliveredNotifications().contains { $0.request.identifier == identifier }
                if !shown {
                    self.onFallbackNeeded?(request, message)
                }
                self.onStateChange?(.available)
            } catch {
                self.onStateChange?(.unavailable("macOS refused the notification, \(error)"))
                self.onFallbackNeeded?(request, message)
            }
        }
    }

    /// The escalation ladder, mapped onto what macOS is willing to do about it.
    ///
    /// `.timeSensitive` additionally requires the time-sensitive entitlement; without it
    /// macOS silently treats the notification as `.active`, which is the correct
    /// degradation and not an error. The app never asks for `.critical`, which would
    /// bypass Do Not Disturb, a menu bar app that overrides Focus has misunderstood what
    /// it is for.
    static func interruptionLevel(for level: EscalationLevel) -> UNNotificationInterruptionLevel {
        switch level {
        case .first:            return .passive
        case .second, .third:   return .active
        case .incident:         return .timeSensitive
        }
    }

    // MARK: - Withdrawal

    func withdraw(cycle: CycleID) {
        guard let center, let identifiers = delivered.removeValue(forKey: cycle) else { return }
        center.removeDeliveredNotifications(withIdentifiers: Array(identifiers))
        center.removePendingNotificationRequests(withIdentifiers: Array(identifiers))
    }

    func withdrawAll() {
        guard let center else { return }
        let identifiers = delivered.values.flatMap { $0 }
        delivered.removeAll()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    // MARK: - Plumbing

    private func identifier(for request: PromptRequest) -> String {
        "dev.sigstop.\(request.cycle.rawValue).\(request.level.rawValue)"
    }

    private func resolveCenter() -> UNUserNotificationCenter? {
        if let center { return center }
        guard AppPaths.isBundled else { return nil }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        self.center = center
        return center
    }

    private func registerCategoriesIfNeeded(_ center: UNUserNotificationCenter) {
        guard !registered else { return }
        registered = true

        let take = UNNotificationAction(
            identifier: Action.take, title: "Take it", options: [.foreground]
        )
        let snooze = UNNotificationAction(
            identifier: Action.snooze, title: "Snooze (SIGALRM)", options: []
        )
        let skip = UNNotificationAction(identifier: Action.skip, title: "Skip", options: [])

        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Category.full, actions: [take, snooze, skip],
                intentIdentifiers: [], options: []
            ),
            UNNotificationCategory(
                identifier: Category.noSnooze, actions: [take, skip],
                intentIdentifiers: [], options: []
            ),
        ])
    }

    /// Asks once, at the first break. A refusal is remembered by macOS, so re-asking is
    /// both impossible and pointless, the fallback panel takes over instead.
    private func ensureAuthorized(_ center: UNUserNotificationCenter) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            onStateChange?(
                .unavailable(
                    "Notifications are turned off for sigstop in System Settings. Falling "
                        + "back to the app's own panel, which does not respect Do Not "
                        + "Disturb, the app's quiet hours are the only mute."
                )
            )
            return false
        case .notDetermined:
            guard !authorizationAsked else { return false }
            authorizationAsked = true
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            if !granted {
                onStateChange?(.unavailable("You declined notifications. Falling back to the app's own panel."))
            }
            return granted
        @unknown default:
            return false
        }
    }
}

// MARK: - Responses

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case Action.take, UNNotificationDefaultActionIdentifier:
                self.onResponse?(.take)
            case Action.snooze:
                self.onResponse?(.snooze)
            case Action.skip:
                self.onResponse?(.skip)
            default:
                break
            }
        }
    }

    /// Show the banner even while sigstop is frontmost. The app is a menu bar item, so
    /// "frontmost" usually means its own popover is open, precisely when the prompt is
    /// still worth seeing.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
