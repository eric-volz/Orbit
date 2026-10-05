import Foundation

enum AppPaths {
    static let defaultBundleIdentifier = "io.github.eric-volz.Orbit"

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? defaultBundleIdentifier
    }

    /// ~/Library/Application Support/Orbit: chat history and local indexes.
    /// DEBUG builds honor ORBIT_DATA_DIR so tests never touch real data.
    static var applicationSupport: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["ORBIT_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Orbit", isDirectory: true)
    }

    static var databaseURL: URL {
        applicationSupport.appendingPathComponent("Orbit.sqlite")
    }

    /// Creates the Application Support directory if needed.
    static func ensureApplicationSupportExists() throws {
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
    }
}
