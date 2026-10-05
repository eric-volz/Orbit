import Darwin
import Foundation

/// Files only the user can read: a directory with mode 0700 and new files with
/// mode 0600, created without following symlinks and never replacing a file.
enum PrivateFile {
    enum Failure: Error, Sendable, Equatable {
        case directory
        case create(errno: Int32)
        case write
    }

    /// Creates `directory` (and its parents) and restricts it to the user.
    static func prepareDirectory(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw Failure.directory
        }
    }

    /// Creates a new file with `contents` (fails if something exists at `url`).
    static func create(at url: URL, contents: Data) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.create(errno: errno) }
        defer { close(fd) }
        try contents.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written > 0 {
                    pointer += written
                    remaining -= written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw Failure.write
                }
            }
        }
    }
}
