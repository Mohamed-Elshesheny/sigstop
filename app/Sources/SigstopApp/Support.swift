import Foundation
import SigstopCore
import SigstopSensors

// MARK: - Where things live

enum AppPaths {
    /// The Info.plist identifier when bundled; the same literal when run straight from
    /// `swift run`, so a development run and a bundled run share one store instead of
    /// silently keeping two histories.
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "dev.sigstop.app" }

    /// True only inside a real `.app`. `swift run sigstop` is false, and several macOS
    /// APIs (UNUserNotificationCenter, SMAppService) are unusable without a bundle, so
    /// the app degrades and says so instead of trapping.
    static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// `~/Library/Application Support/dev.sigstop.app`
    static var storageRoot: URL {
        FileEventStore.defaultRoot(applicationSupport: applicationSupport, bundleID: bundleID)
    }

    static var settingsFile: URL {
        storageRoot.appendingPathComponent("settings.json", isDirectory: false)
    }
}

// MARK: - Settings persistence

/// Settings are one small JSON file next to the event log, not `UserDefaults`.
///
/// `UserDefaults` writes into a preferences plist the user cannot easily read, cannot
/// diff, and cannot delete along with the rest of their data. A file in the same
/// directory as everything else means "Delete my data" really does remove everything,
/// and `cat` stays a complete audit tool (docs/PRIVACY.md §4.6).
///
/// Written at mode 0600 like everything else in the folder. An atomic write lands at
/// the umask, 0644, which is not what docs/PRIVACY.md §4.2 promises for this file.
enum SettingsStore {
    static func load() -> SigstopSettings {
        guard let data = FileManager.default.contents(atPath: AppPaths.settingsFile.path) else {
            return .default
        }
        tightenPermissions()
        return (try? JSONDecoder().decode(SigstopSettings.self, from: data)) ?? .default
    }

    /// Repairs a file already on disk at the wrong mode.
    ///
    /// Writing new files at 0600 fixes nothing for anyone who already has one: an atomic
    /// write lands at the umask, so every install that predates that fix has a
    /// world-readable `settings.json` while `docs/PRIVACY.md` §4.2 says 0600, and would
    /// keep it until the user happened to change a setting. A promise about a file on
    /// disk has to be true of the file that is there.
    private static func tightenPermissions() {
        let manager = FileManager.default
        for url in [AppPaths.settingsFile, AppPaths.storageRoot] {
            guard let mode = (try? manager.attributesOfItem(atPath: url.path))?[.posixPermissions]
                as? NSNumber else { continue }
            let wanted = url == AppPaths.storageRoot ? 0o700 : 0o600
            guard mode.intValue & 0o077 != 0 else { continue }
            try? manager.setAttributes([.posixPermissions: wanted], ofItemAtPath: url.path)
        }
    }

    @discardableResult
    static func save(_ settings: SigstopSettings) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: AppPaths.storageRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(settings).write(to: AppPaths.settingsFile, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: AppPaths.settingsFile.path
            )
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Cross-isolation box

/// The context engine asks for the work clock through a `@Sendable` closure, from
/// whatever isolation it happens to be on. The clock itself lives in a
/// main-actor-isolated `SessionTracker`. This lock-guarded box is the whole bridge: the
/// model publishes a reading after each tick, the closure reads the last published one.
///
/// The one-tick lag is deliberate and harmless, the number is used for display and for
/// message slots, while every decision reads the tracker directly.
final class WorkClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: WorkClockReading = .zero

    func publish(_ reading: WorkClockReading) { lock.withLock { value = reading } }
    func read() -> WorkClockReading { lock.withLock { value } }
}

// MARK: - Small formatting helpers

enum Format {
    /// `h:mm:ss` / `m:ss`, for a clock that is being watched tick by tick.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    /// Signed log-odds, the unit the confidence model actually works in. Printed so a
    /// reader can add the column up and land on the number the app is claiming.
    static func logOdds(_ value: Double) -> String {
        String(format: "%+.2f", value)
    }

    /// `HH:mm`, 24-hour, used for quiet-hours labels where a locale-dependent string
    /// would make the two ends of the window hard to compare at a glance.
    static func minuteOfDay(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
}
