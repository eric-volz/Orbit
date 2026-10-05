import CoreServices
import Foundation

/// Watches app folders with FSEvents and calls `onChange` (on a background
/// queue) when an app or subfolder in them, or one folder deeper, appears,
/// disappears or changes, including a bundle's Contents folder (an edited
/// Info.plist). Changes further inside bundles are ignored. Folders that do not
/// exist yet are watched too: creating one counts as a change.
final class FolderWatcher: @unchecked Sendable {
    private let lock = NSLock()
    // Guarded by `lock`.
    private var stream: FSEventStreamRef?

    /// Nil when the stream could not be started.
    init?(paths: [String], latency: TimeInterval, onChange: @escaping @Sendable () -> Void) {
        // FSEvents reports resolved paths (/private/var/… for /var/…).
        let folders = paths.map(FilePath.canonical)
        let handler = CallbackBox { eventPaths, flags in
            if zip(eventPaths, flags).contains(where: { Self.isRelevant(path: $0, flags: $1, folders: folders) }) {
                onChange()
            }
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<CallbackBox>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            let eventPaths = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray) as? [String] ?? []
            box.handler(eventPaths, (0..<count).map { flags[$0] })
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, folders as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "io.github.eric-volz.Orbit.folder-watcher", qos: .utility))
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        stop()
    }

    /// Stops watching; no `onChange` call starts afterwards.
    func stop() {
        let stream = lock.withLock {
            defer { self.stream = nil }
            return self.stream
        }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// Whether an event matters: a change in a watched folder or a subfolder,
    /// in an app bundle at those levels or its Contents folder, the folder
    /// itself appearing or moving, or events the system dropped (then anything
    /// may have changed).
    static func isRelevant(path: String, flags: FSEventStreamEventFlags, folders: [String]) -> Bool {
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        if flags & rescan != 0 { return true }
        let path = FilePath.normalize(path)
        return folders.contains { folder in
            guard FilePath.isInside(path, folder) else { return false }
            let components = path.dropFirst(folder == "/" ? 1 : folder.count + 1).split(separator: "/")
            guard let bundle = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
                return components.count <= AppBundleScanner.maximumDepth
            }
            let inside = components.dropFirst(bundle + 1)
            return bundle < AppBundleScanner.maximumDepth && (inside.isEmpty || inside.elementsEqual(["Contents"]))
        }
    }
}

/// The stream's callback target; the stream retains it (see the context).
private final class CallbackBox: Sendable {
    let handler: @Sendable ([String], [FSEventStreamEventFlags]) -> Void

    init(_ handler: @escaping @Sendable ([String], [FSEventStreamEventFlags]) -> Void) {
        self.handler = handler
    }
}
