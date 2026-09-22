import Foundation
import SigstopCore
import SigstopSensors

enum AppPaths {
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "dev.sigstop.app" }

    static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    static var storageRoot: URL {
        FileEventStore.defaultRoot(applicationSupport: applicationSupport, bundleID: bundleID)
    }

    static var settingsFile: URL {
        storageRoot.appendingPathComponent("settings.json", isDirectory: false)
    }
}

enum SettingsStore {
    static func load() -> SigstopSettings {
        guard let data = FileManager.default.contents(atPath: AppPaths.settingsFile.path) else {
            return .default
        }
        tightenPermissions()
        return (try? JSONDecoder().decode(SigstopSettings.self, from: data)) ?? .default
    }

    private static func tightenPermissions() {
        let manager = FileManager.default
        for url in [AppPaths.settingsFile, AppPaths.storageRoot] {
            guard let attributes = try? manager.attributesOfItem(atPath: url.path),
                  let type = attributes[.type] as? FileAttributeType,
                  type == .typeRegular || type == .typeDirectory,
                  let mode = attributes[.posixPermissions] as? NSNumber
            else { continue }
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
            guard SecureFile.isOwnDirectory(AppPaths.storageRoot) else { return false }
            try SecureFile.write(encoder.encode(settings), to: AppPaths.settingsFile)
            return true
        } catch {
            return false
        }
    }
}

final class WorkClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: WorkClockReading = .zero

    func publish(_ reading: WorkClockReading) { lock.withLock { value = reading } }
    func read() -> WorkClockReading { lock.withLock { value } }
}

enum Format {
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

    static func logOdds(_ value: Double) -> String {
        String(format: "%+.2f", value)
    }

    static func minuteOfDay(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
}
