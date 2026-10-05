import Foundation
import os
@testable import Orbit

/// macOS's permissions for tests: statuses and the answers to requests come
/// from the test; every reading, request and opening of System Settings is
/// recorded. Readings and requests can be held to test answers that arrive
/// late. Never touches the system.
final class MockPermissionAccess: PermissionAccessing, Sendable {
    private struct State: Sendable {
        var statuses: [PermissionKind: PermissionStatus]
        var otherwise: PermissionStatus
        /// The status after a request (default: unchanged).
        var answers: [PermissionKind: PermissionStatus] = [:]
        var reads: [PermissionKind] = []
        var readsOnMainThread = 0
        var requests: [PermissionKind] = []
        var openedSettings: [PermissionKind] = []
        var holdsReadings = false
        var holdsRequests = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ statuses: [PermissionKind: PermissionStatus] = [:], otherwise: PermissionStatus = .granted) {
        state = OSAllocatedUnfairLock(initialState: State(statuses: statuses, otherwise: otherwise))
    }

    var reads: [PermissionKind] { state.withLock { $0.reads } }
    var readsOnMainThread: Int { state.withLock { $0.readsOnMainThread } }
    var requests: [PermissionKind] { state.withLock { $0.requests } }
    var openedSettings: [PermissionKind] { state.withLock { $0.openedSettings } }

    func set(_ status: PermissionStatus, for permission: PermissionKind) {
        state.withLock { $0.statuses[permission] = status }
    }

    /// A request for `permission` ends with `status` (like the user's answer).
    func answer(_ permission: PermissionKind, with status: PermissionStatus) {
        state.withLock { $0.answers[permission] = status }
    }

    /// Readings take their value, then wait until `releaseReadings()`.
    func holdReadings() {
        state.withLock { $0.holdsReadings = true }
    }

    func releaseReadings() {
        state.withLock { $0.holdsReadings = false }
    }

    /// Requests wait (as if macOS's prompt were open) until `releaseRequests()`.
    func holdRequests() {
        state.withLock { $0.holdsRequests = true }
    }

    func releaseRequests() {
        state.withLock { $0.holdsRequests = false }
    }

    func status(of permission: PermissionKind) -> PermissionStatus {
        let value = state.withLock { state in
            state.reads.append(permission)
            if Thread.isMainThread { state.readsOnMainThread += 1 }
            return state.statuses[permission] ?? state.otherwise
        }
        while state.withLock({ $0.holdsReadings }) {
            usleep(1_000)
        }
        return value
    }

    func request(_ permission: PermissionKind) async -> PermissionStatus {
        state.withLock { $0.requests.append(permission) }
        while state.withLock({ $0.holdsRequests }) {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return state.withLock { state in
            if let answer = state.answers[permission] {
                state.statuses[permission] = answer
            }
            return state.statuses[permission] ?? state.otherwise
        }
    }

    func openSystemSettings(for permission: PermissionKind) async {
        state.withLock { $0.openedSettings.append(permission) }
    }
}

/// Tool infos as the app registers them, for permission lists.
enum PermissionTestTools {
    static func info(_ name: String, _ permissions: [PermissionKind], category: ToolCategory = .mail) -> ToolInfo {
        ToolInfo(name: name, description: "", category: category, riskLevel: .read, requiredPermissions: permissions)
    }

    /// The app's tools (files, mail, notes, contacts) on fakes.
    static var app: [ToolInfo] {
        ToolRegistry(tools: AppEnvironment.makeTools(services: .fake())).infos
    }
}
