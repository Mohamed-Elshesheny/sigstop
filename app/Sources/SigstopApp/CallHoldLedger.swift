import Foundation

/// How many seconds the call latch has held a break back today, across relaunches.
///
/// The latch itself is deliberately **not** persisted: a latch restored from disk is a
/// suppression that can outlive the bug that created it, invisibly, and quitting the app
/// is a user's crude escape hatch that must keep working. This counter is the exact
/// opposite. It can only ever cause the latch to stop holding sooner, so persisting it
/// carries none of that risk, and without it the three-hour daily ceiling is defeated by
/// quitting and reopening the app.
///
/// One small JSON file next to the event log, at mode 0600 like the rest of the folder.
/// Nothing here is personal: a day index and a number of seconds.
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

    /// Written at most once a minute of accrual, because a break held for twenty minutes
    /// should not mean two hundred and forty file writes.
    static func save(seconds: TimeInterval, dayIndex: Int) {
        let record = Record(dayIndex: dayIndex, heldSeconds: max(0, seconds))
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(
            at: AppPaths.storageRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
