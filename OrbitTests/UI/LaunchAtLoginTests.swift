import Foundation
import os
import ServiceManagement
import Testing
@testable import Orbit

/// D6: Settings → General → "Open at login" in every state,
/// incl. "requires approval" with "Open Login Items…". A fake stands in
/// for `SMAppService`: nothing is registered on this Mac.
@Suite("Launch at login")
@MainActor
struct LaunchAtLoginTests {
    @Test(arguments: [
        (SMAppService.Status.enabled, LaunchAtLoginModel.State.enabled),
        (.requiresApproval, .requiresApproval),
        (.notRegistered, .disabled),
        (.notFound, .disabled),
    ])
    func readsTheStateWithoutChangingAnything(status: SMAppService.Status, state: LaunchAtLoginModel.State) async {
        let item = FakeLoginItem(status: status)
        let model = LaunchAtLoginModel(service: item)
        await model.refresh()
        #expect(model.state == state)
        #expect(model.isOn == (state != .disabled))
        #expect(item.calls == ["status"])
    }

    /// macOS may want the user's approval first: the switch stays on, the note
    /// says where, "Open Login Items…" goes there, and once it was
    /// allowed, Orbit shows it when it becomes active again.
    @Test func approvalInSystemSettingsIsExplainedWithAButton() async {
        let item = FakeLoginItem(status: .notRegistered, statusAfterRegister: .requiresApproval)
        let model = LaunchAtLoginModel(service: item)
        await model.refresh()
        #expect(model.statusMessage == nil)
        #expect(!model.offersLoginItemsSettings)

        await model.setEnabled(true)
        #expect(model.state == .requiresApproval)
        #expect(model.isOn)
        #expect(model.statusMessage == "Allow Orbit in System Settings > General > Login Items.")
        #expect(model.offersLoginItemsSettings)
        #expect(model.errorMessage == nil)
        #expect(!model.isUpdating)
        model.openLoginItemsSettings()
        #expect(item.calls == ["status", "register", "status", "openSystemSettings"])

        item.setStatus(.enabled)
        await model.refresh()
        #expect(model.state == .enabled)
        #expect(model.statusMessage == nil)
        #expect(!model.offersLoginItemsSettings)
    }

    @Test func switchingOnAndOff() async {
        let item = FakeLoginItem(status: .notRegistered)
        let model = LaunchAtLoginModel(service: item)
        await model.setEnabled(true)
        #expect(model.state == .enabled)
        await model.setEnabled(false)
        #expect(model.state == .disabled)
        #expect(item.calls == ["register", "status", "unregister", "status"])
    }

    @Test func aFailureIsExplainedUntilTheStateChanges() async {
        let item = FakeLoginItem(status: .notRegistered, failure: kSMErrorInvalidSignature)
        let model = LaunchAtLoginModel(service: item)
        await model.setEnabled(true)
        #expect(model.errorMessage == "Orbit is not validly signed, so it cannot open at login.")
        #expect(model.state == .disabled)
        #expect(!model.isUpdating)
        #expect(item.calls == ["register", "status"], "the state is read again")

        // Nothing changed: the explanation stays. Allowed meanwhile (e.g. in System Settings): it goes.
        await model.refresh()
        #expect(model.errorMessage != nil)
        item.setStatus(.enabled)
        await model.refresh()
        #expect(model.state == .enabled)
        #expect(model.errorMessage == nil)
    }

    /// The keyboard stays on the switch, so VoiceOver hears what appeared next
    /// to it: that macOS wants approval, or why it did not work (the switch
    /// flips back then). A switch that simply worked says nothing more.
    @Test func voiceOverHearsWhatAppearsNextToTheSwitch() async {
        let announcer = RecordingAnnouncer()
        let approval = LaunchAtLoginModel(service: FakeLoginItem(status: .notRegistered, statusAfterRegister: .requiresApproval),
                                          announcer: announcer)
        await approval.setEnabled(true)
        #expect(announcer.announcements == ["Allow Orbit in System Settings > General > Login Items."])
        #expect(announcer.priorities == [.high])

        let failing = LaunchAtLoginModel(service: FakeLoginItem(status: .notRegistered, failure: kSMErrorJobNotFound),
                                         announcer: announcer)
        await failing.setEnabled(true)
        #expect(!failing.isOn)
        #expect(announcer.announcements.last == "Opening at login is not available for this copy of Orbit. Move Orbit to the Applications folder and open it from there.")
        #expect(announcer.priorities.last == .high)

        let working = LaunchAtLoginModel(service: FakeLoginItem(status: .notRegistered), announcer: announcer)
        await working.setEnabled(true)
        await working.setEnabled(false)
        await working.refresh()
        #expect(announcer.announcements.count == 2)
    }

    @Test func everyFailureHasAnExplanation() {
        func message(_ code: Int, enabling: Bool = true) -> String {
            LaunchAtLoginModel.message(for: NSError(domain: "SMAppServiceErrorDomain", code: code), enabling: enabling)
        }
        #expect(message(kSMErrorInvalidSignature) == "Orbit is not validly signed, so it cannot open at login.")
        #expect(message(kSMErrorJobNotFound) == "Opening at login is not available for this copy of Orbit. Move Orbit to the Applications folder and open it from there.")
        #expect(message(kSMErrorServiceUnavailable) == message(kSMErrorJobNotFound))
        #expect(message(kSMErrorLaunchDeniedByUser) == "Opening at login was denied in System Settings.")
        #expect(message(kSMErrorInternalFailure) == "Orbit could not be added to the login items.")
        #expect(message(kSMErrorInternalFailure, enabling: false) == "Orbit could not be removed from the login items.")
    }
}

/// Orbit's login item as tests see it: a status, and what registering,
/// unregistering and "open System Settings" would do, recorded only.
final class FakeLoginItem: LoginItemControlling {
    private struct State: Sendable {
        var status: SMAppService.Status
        var statusAfterRegister: SMAppService.Status
        /// The `kSMError…` code register and unregister fail with.
        var failure: Int?
        var calls: [String] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(status: SMAppService.Status, statusAfterRegister: SMAppService.Status = .enabled, failure: Int? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(status: status, statusAfterRegister: statusAfterRegister,
                                                          failure: failure))
    }

    var calls: [String] { state.withLock { $0.calls } }

    func setStatus(_ status: SMAppService.Status) {
        state.withLock { $0.status = status }
    }

    func status() -> SMAppService.Status {
        state.withLock { state in
            state.calls.append("status")
            return state.status
        }
    }

    func register() throws {
        try state.withLock { state in
            state.calls.append("register")
            if let failure = state.failure { throw NSError(domain: "SMAppServiceErrorDomain", code: failure) }
            state.status = state.statusAfterRegister
        }
    }

    func unregister() throws {
        try state.withLock { state in
            state.calls.append("unregister")
            if let failure = state.failure { throw NSError(domain: "SMAppServiceErrorDomain", code: failure) }
            state.status = .notRegistered
        }
    }

    func openSystemSettings() {
        state.withLock { $0.calls.append("openSystemSettings") }
    }
}
