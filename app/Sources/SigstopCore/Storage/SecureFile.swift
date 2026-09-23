import Foundation

public enum SecureFile {

    public static func write(_ data: Data, to destination: URL) throws {
        let temp = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)"
        )
        var fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw StoreError.notWritable(path: temp.path, reason: String(cString: strerror(errno)))
        }
        do {
            try writeAll(data, to: fd, path: temp.path)
            guard fsync(fd) == 0 else {
                throw StoreError.notWritable(path: temp.path, reason: String(cString: strerror(errno)))
            }
            close(fd)
            fd = -1
            guard rename(temp.path, destination.path) == 0 else {
                throw StoreError.notWritable(path: destination.path, reason: String(cString: strerror(errno)))
            }
        } catch {
            if fd >= 0 { close(fd) }
            unlink(temp.path)
            throw error
        }
    }

    public static func append(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw StoreError.notWritable(path: url.path, reason: String(cString: strerror(errno)))
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1
        else {
            throw StoreError.notWritable(path: url.path, reason: "not a plain file of yours")
        }
        if info.st_size > 0 {
            var last: UInt8 = 0
            if pread(fd, &last, 1, info.st_size - 1) == 1, last != 0x0A {
                try writeAll(Data([0x0A]), to: fd, path: url.path)
            }
        }
        try writeAll(data, to: fd, path: url.path)
        guard fsync(fd) == 0 else {
            throw StoreError.notWritable(path: url.path, reason: String(cString: strerror(errno)))
        }
    }

    public enum ReadResult: Sendable, Equatable {
        case absent
        case unreadable
        case contents(Data)
    }

    public static func read(_ url: URL, limit: Int) -> ReadResult {
        read(url, limit: limit) { handle, count in try handle.read(upToCount: count) }
    }

    static func read(
        _ url: URL,
        limit: Int,
        reader: (FileHandle, Int) throws -> Data?
    ) -> ReadResult {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .absent : .unreadable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else {
            return .unreadable
        }
        let read: Data?
        do {
            read = try reader(handle, limit + 1)
        } catch {
            return .unreadable
        }
        guard let data = read else { return .contents(Data()) }
        return data.count > limit ? .unreadable : .contents(data)
    }

    public static func isOwnDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
    }

    private static func writeAll(_ data: Data, to fd: Int32, path: String) throws {
        try data.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let written = Darwin.write(fd, base, left)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw StoreError.notWritable(path: path, reason: String(cString: strerror(errno)))
                }
                left -= written
                base = base.advanced(by: written)
            }
        }
    }
}
