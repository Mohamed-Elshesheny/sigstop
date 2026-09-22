import Foundation
import SigstopCore

enum CallHoldLedger {
    private struct Record: Codable {
        var dayIndex: Int
        var heldSeconds: TimeInterval
    }

    private static var file: URL {
        AppPaths.storageRoot.appendingPathComponent("call-hold.json", isDirectory: false)
    }

    static func load(dayIndex: Int) -> TimeInterval {
        guard let data = FileManager.default.contents(atPath: file.path),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.dayIndex == dayIndex else { return 0 }
        return max(0, record.heldSeconds)
    }

    static func save(seconds: TimeInterval, dayIndex: Int) {
        let record = Record(dayIndex: dayIndex, heldSeconds: max(0, seconds))
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(
            at: AppPaths.storageRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard SecureFile.isOwnDirectory(AppPaths.storageRoot) else { return }
        try? SecureFile.write(data, to: file)
    }
}
