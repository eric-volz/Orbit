import Foundation
import os

/// Unified logging. Rule: never log user content (mail, notes, file contents,
/// prompts, model output, API keys). Log events, counts, durations and error
/// kinds; mark anything user-derived `privacy: .private`.
enum Log {
    static let app = Logger(subsystem: AppPaths.bundleIdentifier, category: "app")
    static let panel = Logger(subsystem: AppPaths.bundleIdentifier, category: "panel")
    static let llm = Logger(subsystem: AppPaths.bundleIdentifier, category: "llm")
    static let agent = Logger(subsystem: AppPaths.bundleIdentifier, category: "agent")
    static let tools = Logger(subsystem: AppPaths.bundleIdentifier, category: "tools")
    static let search = Logger(subsystem: AppPaths.bundleIdentifier, category: "search")
    static let storage = Logger(subsystem: AppPaths.bundleIdentifier, category: "storage")
    static let permissions = Logger(subsystem: AppPaths.bundleIdentifier, category: "permissions")
}
