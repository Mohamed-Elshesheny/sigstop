import Foundation
import SigstopCore
@preconcurrency import UserNotifications

enum PromptResponse: Sendable, Hashable {
    case take
    case snooze
    case skip
}

@MainActor
final class Notifier: NSObject {

    private enum Category {
        static let full = "dev.sigstop.prompt.full"
        static let noSnooze = "dev.sigstop.prompt.nosnooze"
    }

    private enum Action {
        static let take = "dev.sigstop.action.take"
        static let snooze = "dev.sigstop.action.snooze"
        static let skip = "dev.sigstop.action.skip"
    }

    var onResponse: ((PromptResponse, CycleID?) -> Void)?
    var onStateChange: ((AppModel.NotificationAvailability) -> Void)?
    var onFallbackNeeded: ((PromptRequest, RenderedMessage) -> Void)?

    private var center: UNUserNotificationCenter?
    private var registered = false
    private var authorizationAsked = false
    private var delivered: [CycleID: Set<String>] = [:]
    private var serial = 0

    override init() {
        super.init()
    }

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
            let authorized = await self.ensureAuthorized(center)
            guard self.isWanted(identifier, cycle: request.cycle) else { return }
            guard authorized else {
                self.onFallbackNeeded?(request, message)
                return
            }
            do {
                try await center.add(notification)
                self.onStateChange?(.available)
                guard self.isWanted(identifier, cycle: request.cycle) else {
                    center.removeDeliveredNotifications(withIdentifiers: [identifier])
                    center.removePendingNotificationRequests(withIdentifiers: [identifier])
                    return
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard self.isWanted(identifier, cycle: request.cycle) else { return }
                let shown = await center.deliveredNotifications().contains { $0.request.identifier == identifier }
                if !shown {
                    self.onFallbackNeeded?(request, message)
                }
            } catch {
                self.onStateChange?(.unavailable("macOS refused the notification, \(error)"))
                self.onFallbackNeeded?(request, message)
            }
        }
    }

    static func interruptionLevel(for level: EscalationLevel) -> UNNotificationInterruptionLevel {
        switch level {
        case .first:            return .passive
        case .second, .third:   return .active
        case .incident:         return .timeSensitive
        }
    }

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

    private func identifier(for request: PromptRequest) -> String {
        serial += 1
        return "dev.sigstop.\(request.cycle.rawValue).\(request.level.rawValue).\(serial)"
    }

    private func isWanted(_ identifier: String, cycle: CycleID) -> Bool {
        delivered[cycle]?.contains(identifier) == true
    }

    private func resolveCenter() -> UNUserNotificationCenter? {
        if let center { return center }
        guard AppPaths.isBundled else { return nil }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        self.center = center
        return center
    }

    var skipQuiet: TimeInterval = 20 * 60

    private func registerCategoriesIfNeeded(_ center: UNUserNotificationCenter) {
        guard !registered else { return }
        registered = true

        let take = UNNotificationAction(
            identifier: Action.take, title: "Take it", options: [.foreground]
        )
        let snooze = UNNotificationAction(
            identifier: Action.snooze, title: "Snooze (SIGALRM)", options: []
        )
        let skip = UNNotificationAction(
            identifier: Action.skip, title: "Skip, quiet for \(DurationText.short(skipQuiet))", options: []
        )

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

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let thread = response.notification.request.content.threadIdentifier
        let cycle = Int(thread.replacingOccurrences(of: "dev.sigstop.cycle.", with: "")).map(CycleID.init)
        await MainActor.run {
            switch action {
            case Action.take, UNNotificationDefaultActionIdentifier:
                self.onResponse?(.take, cycle)
            case Action.snooze:
                self.onResponse?(.snooze, cycle)
            case Action.skip:
                self.onResponse?(.skip, cycle)
            default:
                break
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
