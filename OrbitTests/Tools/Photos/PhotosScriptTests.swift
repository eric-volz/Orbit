import Foundation
import Testing
@testable import Orbit

/// photos-show.applescript and the service that runs it: static checks (it
/// only looks up a media item and shows it), its JSON handler run without
/// Photos, and the answers the service understands (mock runner). The script
/// is compiled with the others in `AppleScriptFilesTests`; Photos ships a
/// scripting dictionary, so compiling never launches it. No Apple Event is
/// ever sent to Photos here.
@Suite("Photos script", .serialized)
struct PhotosScriptTests {
    static let repository = AppleScriptFilesTests.repository

    @Test func theScriptOnlyLooksUpAnItemAndShowsIt() throws {
        let code = try MailScriptTests.code("photos-show")
        #expect(PhotosService.showScript.app == .photos && ScriptedApp.photos.name == "Photos")
        #expect(ScriptedApp.photos.permission == .automationPhotos)
        #expect(AppleScriptFilesTests.targets(in: code) == ["Photos"])
        #expect(code.contains("set theItem to media item id itemID"), "the id is an argument, never part of the source")
        #expect(code.contains("spotlight theItem"))
        #expect(code.contains("activate"))
        for word in ["delete", "duplicate", "make", "add", "import", "export", "set favorite", "keywords", "name of",
                     "description", "location", "filename", "slideshow", "search", "selection", "quit"] {
            #expect(!MailScriptTests.matches("\\b\(word)\\b", in: code), "photos-show must not use '\(word)'")
        }
        #expect(PhotosService.showScript.timeout == .seconds(30), "time for the first prompt, within the tool deadline")
        #expect(AppleScript.bundled.contains(PhotosService.showScript))
    }

    @Test func theJSONHandlerWorksWithoutPhotos() async throws {
        let handlers = try AppleScriptFilesTests.handlers(["toJSON"], from: try AppleScriptFilesTests.source("photos-show"))
        let output = try await AppleScriptFilesTests.runHandlers(handlers, body: """
                set shown to my toJSON(current application's NSDictionary's dictionaryWithObject:true forKey:"shown")
                set missing to my toJSON(current application's NSDictionary's dictionaryWithObject:"notFound" forKey:"error")
                return shown & linefeed & missing
            """)
        let lines = output.components(separatedBy: "\n")
        try #require(lines.count == 2)
        #expect(try JSONDecoder().decode(PhotosService.ShowAnswer.self, from: Data(lines[0].utf8)) == .init(shown: true))
        #expect(try JSONDecoder().decode(PhotosService.ShowAnswer.self, from: Data(lines[1].utf8)) == .init(error: "notFound"))
    }

    // MARK: The service

    @Test func showingPassesTheIdentifierAsAnArgument() async throws {
        let runner = MockAppleScriptRunner(output: #"{"shown":true}"#)
        try await PhotosService(runner: runner).show(id: "B84E8479-475C-4727-A4A4-B77AA9980897/L0/001")
        #expect(runner.runs == [.init(script: "photos-show", arguments: ["B84E8479-475C-4727-A4A4-B77AA9980897/L0/001"])])
    }

    @Test func theScriptsAnswersBecomeErrors() async throws {
        let missing = PhotosService(runner: MockAppleScriptRunner(output: #"{"error":"notFound"}"#))
        await #expect(throws: PhotosFailure.itemNotFound) { try await missing.show(id: "P1/L0/001") }
        let garbled = PhotosService(runner: MockAppleScriptRunner(output: "shown"))
        await #expect(throws: AppleScriptError.invalidOutput) { try await garbled.show(id: "P1/L0/001") }
        let unclear = PhotosService(runner: MockAppleScriptRunner(output: #"{"shown":false}"#))
        await #expect(throws: AppleScriptError.invalidOutput) { try await unclear.show(id: "P1/L0/001") }
        let denied = PhotosService(runner: MockAppleScriptRunner { _, _ in throw AppleScriptError.notAuthorized(.photos) })
        await #expect(throws: AppleScriptError.notAuthorized(.photos)) { try await denied.show(id: "P1/L0/001") }
    }

    @Test func onlyIdentifiersAsPhotoKitGivesThemReachTheScript() async throws {
        let runner = MockAppleScriptRunner(output: #"{"shown":true}"#)
        let service = PhotosService(runner: runner)
        for bad in ["", "a\"; do shell script \"x", "P1/L0/001\n", "Foto ü", String(repeating: "a", count: 201)] {
            await #expect(throws: PhotosFailure.invalidIdentifier) { try await service.show(id: bad) }
        }
        #expect(runner.runs.isEmpty)
        #expect(PhotoID.isValid("ORBIT-FAKE-0001/L0/001") && PhotoID.isValid("a_b.c-d/L0/001"))
    }

    /// osascript's -1743 for Photos tells the user which permission is missing.
    @Test func aRefusedAppleEventNamesAutomationPhotos() {
        let error = OsascriptFailure.error(number: -1743, message: "Not authorized", app: .photos)
        #expect(error == .notAuthorized(.photos))
        #expect(error.toolError(for: PhotosService.showScript) == .permissionDenied(.automationPhotos))
        #expect(AgentLoop.permissionNotice(for: .automationPhotos) == "Orbit is not allowed to control Photos.")
    }
}
