import Foundation
import SigstopCore

enum StatusLineFile {
    static var url: URL {
        AppPaths.storageRoot.appendingPathComponent(StatusLine.fileName, isDirectory: false)
    }

    static func write(_ line: String) throws {
        try FileManager.default.createDirectory(
            at: AppPaths.storageRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard SecureFile.isOwnDirectory(AppPaths.storageRoot) else {
            throw StoreError.notWritable(
                path: AppPaths.storageRoot.path, reason: "not a folder of yours"
            )
        }
        do {
            try SecureFile.write(Data(line.utf8), to: url)
        } catch StoreError.notWritable(_, let reason) {
            throw StoreError.notWritable(path: url.path, reason: reason)
        }
    }

    static func remove() {
        _ = unlink(url.path)
    }
}
