import Darwin
import Foundation

/// Path helpers shared by the file tools and instant search. Everything is
/// lexical (pure) except `canonical`, which asks the file system.
enum FilePath {
    /// "/a/./b//c/../d/" → "/a/b/d". Symlinks are not resolved; ".." above the
    /// root stays at the root.
    static func normalize(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if let last = parts.last, last != ".." {
                    parts.removeLast()
                } else if !isAbsolute {
                    parts.append(component)
                }
            default:
                parts.append(component)
            }
        }
        let joined = parts.joined(separator: "/")
        return isAbsolute ? "/" + joined : (joined.isEmpty ? "." : joined)
    }

    /// A path argument as the user or model wrote it: surrounding quotes and
    /// whitespace removed, `file://` URLs converted, "~" expanded with `home`,
    /// normalized. Relative paths stay relative (callers reject them).
    static func expand(_ input: String, home: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes: Set<Character> = ["\"", "'", "“", "”", "„", "‘", "’", "`"]
        while text.count >= 2, let first = text.first, let last = text.last, quotes.contains(first), quotes.contains(last) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if text.lowercased().hasPrefix("file://"), let url = URL(string: text), url.isFileURL {
            text = url.path(percentEncoded: false)
        }
        if text == "~" {
            text = home
        } else if text.hasPrefix("~/") {
            text = home + text.dropFirst()
        }
        return normalize(text)
    }

    /// "/Users/me/Documents/a.pdf" → "~/Documents/a.pdf" (paths shown to the model).
    static func abbreviate(_ path: String, home: String) -> String {
        let home = normalize(home)
        guard home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// True when `path` is `directory` or inside it. Both must be normalized.
    static func isInside(_ path: String, _ directory: String) -> Bool {
        if directory == "/" { return path.hasPrefix("/") }
        return path == directory || path.hasPrefix(directory + "/")
    }

    /// The last path component ("" for "/").
    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? ""
    }

    /// `path` as the kernel names the item: every symlink resolved, the case
    /// on disk, and without alias spellings of the same item that realpath
    /// keeps: the data volume's firmlinks ("/System/Volumes/Data/Users/…" is
    /// "/Users/…"), "/.vol/<device>/<inode>/…", "/.nofollow/…" and
    /// "/.resolve/<n>/…". For a path that does not exist, its deepest existing
    /// ancestor is resolved and the rest appended.
    static func canonical(_ path: String) -> String {
        let normalized = normalize(path)
        guard normalized.hasPrefix("/") else { return normalized }
        if let resolved = resolvedPath(normalized) { return resolved }
        var missing: [String] = []
        var current = normalized
        while current != "/" {
            missing.insert(lastComponent(current), at: 0)
            current = normalize(current + "/..")
            if let resolved = resolvedPath(current) {
                return normalize(resolved + "/" + missing.joined(separator: "/"))
            }
        }
        return normalized
    }

    /// The kernel's path of an existing item, else realpath's.
    private static func resolvedPath(_ path: String) -> String? {
        kernelPath(path) ?? realPath(path)
    }

    /// The path the kernel reports for the item at `path` (symlinks followed):
    /// the path of the item itself, whatever spelling reached it (F_GETPATH).
    /// Only regular files and folders are opened, for event notifications only
    /// (O_EVTONLY: nothing is read, nothing blocks), and never when they are
    /// dataless (iCloud Drive or cloud storage files that are not downloaded),
    /// which opening could download. Pipes, devices and sockets are never
    /// opened. For those, getattrlist asks the kernel without opening anything;
    /// it resolves the firmlink and /.vol spellings, not /.nofollow or /.resolve
    /// (which FileAccessPolicy refuses).
    private static func kernelPath(_ path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        if mayOpen(info), let opened = pathOfOpenedItem(path) {
            return opened
        }
        return attributePath(path)
    }

    /// A regular file or a folder whose content is on the Mac.
    private static func mayOpen(_ info: stat) -> Bool {
        let type = info.st_mode & S_IFMT
        return (type == S_IFREG || type == S_IFDIR) && info.st_flags & UInt32(SF_DATALESS) == 0
    }

    private static func pathOfOpenedItem(_ path: String) -> String? {
        let descriptor = Darwin.open(path, O_EVTONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        // Still such an item (not one swapped in since it was looked at).
        var info = stat()
        guard fstat(descriptor, &info) == 0, mayOpen(info) else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) + 1)
        guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return nil }
        let resolved = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return resolved.hasPrefix("/") ? resolved : nil
    }

    /// getattrlist's ATTR_CMN_FULLPATH (symlinks followed).
    private static func attributePath(_ path: String) -> String? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(bitPattern: ATTR_CMN_FULLPATH)
        // u_int32_t length, attrreference_t (offset, length), then the path.
        let headerSize = MemoryLayout<UInt32>.size + MemoryLayout<attrreference_t>.size
        var buffer = [UInt8](repeating: 0, count: headerSize + Int(MAXPATHLEN) + 1)
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &request, raw.baseAddress, raw.count, 0)
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> String? in
            let referenceOffset = MemoryLayout<UInt32>.size
            let dataOffset = Int(raw.load(fromByteOffset: referenceOffset, as: Int32.self))
            let length = Int(raw.load(fromByteOffset: referenceOffset + MemoryLayout<Int32>.size, as: UInt32.self))
            let start = referenceOffset + dataOffset
            guard length > 1, start >= headerSize, start + length <= raw.count else { return nil }
            let resolved = String(decoding: raw[start..<(start + length - 1)], as: UTF8.self)
            return resolved.hasPrefix("/") ? resolved : nil
        }
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
