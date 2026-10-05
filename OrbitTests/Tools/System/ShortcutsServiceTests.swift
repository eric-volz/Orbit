import Darwin
import Foundation
import os
import Testing
@testable import Orbit

/// `LiveShortcuts` on a process runner that runs nothing: /usr/bin/shortcuts
/// never runs in a test: the command lines, the private input and output
/// files (and that they are always deleted), the time limits, errors and
/// how the output is read.
@Suite("Shortcuts service")
struct ShortcutsServiceTests {
    struct Setup {
        let service: LiveShortcuts
        let runner: MockProcessRunner
        let folder: TemporaryFolder

        var inputDirectory: URL { folder.url.appendingPathComponent("ShortcutInput", isDirectory: true) }
        var outputParent: URL { folder.url.appendingPathComponent("tmp", isDirectory: true) }

        func remove() { folder.remove() }
    }

    private func setup(_ responder: @escaping MockProcessRunner.Responder = { _ in MockProcessRunner.output("") }) throws -> Setup {
        let folder = try TemporaryFolder("orbit-shortcuts")
        let runner = MockProcessRunner(responder)
        try folder.makeFolder("tmp")
        let service = LiveShortcuts(runner: runner, inputDirectory: folder.url.appendingPathComponent("ShortcutInput", isDirectory: true),
                                    outputParent: folder.url.appendingPathComponent("tmp", isDirectory: true),
                                    environment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/orbit-test"])
        return Setup(service: service, runner: runner, folder: folder)
    }

    // MARK: Listing

    @Test func listsWithIdentifiers() async throws {
        let setup = try setup { _ in
            MockProcessRunner.output("Fokus: Arbeiten (0B6D3C8A-1F2E-4D5C-9A8B-7C6D5E4F3A2B)\nWetter (heute) (A1B2C3D4-E5F6-4A5B-8C7D-0123456789AB)\n\nOhne Kennung\n")
        }
        defer { setup.remove() }
        let shortcuts = try await setup.service.shortcuts(in: nil)
        #expect(shortcuts == [
            ShortcutInfo(name: "Fokus: Arbeiten", identifier: "0B6D3C8A-1F2E-4D5C-9A8B-7C6D5E4F3A2B"),
            ShortcutInfo(name: "Wetter (heute)", identifier: "A1B2C3D4-E5F6-4A5B-8C7D-0123456789AB"),
            ShortcutInfo(name: "Ohne Kennung", identifier: nil),
        ])
        #expect(setup.runner.calls == [.init(executable: "/usr/bin/shortcuts", arguments: ["list", "--show-identifiers"],
                                             workingDirectory: "/", timeout: .seconds(10))])
    }

    @Test func foldersAndAFolder() async throws {
        let setup = try setup { launch in
            launch.arguments.contains("--folders") ? MockProcessRunner.output("Fokus (11111111-2222-4333-8444-555555555555)\n-Seltsam\n")
                : MockProcessRunner.output("Fokus aus (66666666-7777-4888-9999-000000000000)\n")
        }
        defer { setup.remove() }
        let folders = try await setup.service.folders()
        #expect(folders == [ShortcutFolder(name: "Fokus", identifier: "11111111-2222-4333-8444-555555555555"),
                            ShortcutFolder(name: "-Seltsam", identifier: nil)])
        _ = try await setup.service.shortcuts(in: folders[0])
        _ = try await setup.service.shortcuts(in: folders[1])
        #expect(setup.runner.calls.map(\.arguments) == [
            ["list", "--folders", "--show-identifiers"],
            ["list", "--show-identifiers", "--folder-name", "11111111-2222-4333-8444-555555555555"],
            ["list", "--show-identifiers", "--folder-name=-Seltsam"],
        ], "the folder by its identifier; a name that starts with \"-\" stays the option's value")
    }

    @Test func commandLinesOfRuns() {
        let byID = ShortcutInfo(name: "Wetter", identifier: "A1B2C3D4-E5F6-4A5B-8C7D-0123456789AB")
        #expect(ShortcutsCommand.run(byID, inputPath: "/in.txt", outputPath: "/out/output")
            == ["run", "--input-path", "/in.txt", "--output-path", "/out/output", "A1B2C3D4-E5F6-4A5B-8C7D-0123456789AB"])
        #expect(ShortcutsCommand.run(ShortcutInfo(name: "Wetter", identifier: nil), inputPath: nil, outputPath: "/out/output")
            == ["run", "--output-path", "/out/output", "Wetter"])
        #expect(ShortcutsCommand.run(ShortcutInfo(name: "--help", identifier: nil), inputPath: nil, outputPath: "/o")
            == ["run", "--output-path", "/o", "--", "--help"], "a name that looks like an option comes after --")
    }

    // MARK: Running

    /// D4: the input goes through a file readable only by the user in Orbit's
    /// data folder, the output into a private folder; both are deleted afterwards.
    @Test func aRunGetsItsInputFromAPrivateFileAndLeavesNothingBehind() async throws {
        let seen = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
        let setup = try setup { launch in
            let arguments = launch.arguments
            let input = arguments[arguments.firstIndex(of: "--input-path")! + 1]
            let output = arguments[arguments.firstIndex(of: "--output-path")! + 1]
            var info = stat()
            stat(input, &info)
            var folderInfo = stat()
            stat((output as NSString).deletingLastPathComponent, &folderInfo)
            let values = ["input": try String(contentsOfFile: input, encoding: .utf8),
                          "inputMode": String(info.st_mode & 0o777, radix: 8),
                          "outputFolderMode": String(folderInfo.st_mode & 0o777, radix: 8)]
            seen.withLock { $0 = values }
            try "Übersetzt: Hello".write(toFile: output, atomically: false, encoding: .utf8)
            return MockProcessRunner.output("")
        }
        defer { setup.remove() }
        let output = try await setup.service.run(ShortcutInfo(name: "Übersetzen", identifier: "A1B2C3D4-E5F6-4A5B-8C7D-0123456789AB"),
                                                 input: "Hallo „Welt“")
        #expect(output == .text("Übersetzt: Hello", isComplete: true))
        let values = seen.withLock { $0 }
        #expect(values["input"] == "Hallo „Welt“")
        #expect(values["inputMode"] == "600" && values["outputFolderMode"] == "700")
        let call = try #require(setup.runner.calls.first)
        #expect(call.timeout == .seconds(120))
        #expect(call.arguments.last == "A1B2C3D4-E5F6-4A5B-8C7D-0123456789AB", "run by identifier")
        #expect(call.arguments[call.arguments.firstIndex(of: "--input-path")! + 1].hasPrefix(setup.inputDirectory.path + "/"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: setup.inputDirectory.path).isEmpty, "the input file is gone")
        #expect(try FileManager.default.contentsOfDirectory(atPath: setup.outputParent.path).isEmpty, "the output folder is gone")
        var info = stat()
        stat(setup.inputDirectory.path, &info)
        #expect(info.st_mode & 0o777 == 0o700)
    }

    @Test func withoutInputThereIsNoInputFile() async throws {
        let setup = try setup()
        defer { setup.remove() }
        #expect(try await setup.service.run(ShortcutInfo(name: "Licht aus", identifier: nil), input: nil) == .none)
        #expect(setup.runner.calls.first.map { !$0.arguments.contains("--input-path") } == true)
        #expect(!FileManager.default.fileExists(atPath: setup.inputDirectory.path), "nothing was written")
    }

    @Test func failuresBecomeErrorsAndLeaveNothingBehind() async throws {
        let cases: [(MockProcessRunner.Responder, ShortcutsError)] = [
            ({ _ in throw ChildProcess.RunFailure.timedOut }, .timedOut),
            ({ _ in throw ChildProcess.Failure.spawnFailed(errno: ENOENT) }, .notInstalled),
            ({ _ in throw ChildProcess.Failure.spawnFailed(errno: EACCES) }, .launchFailed),
            ({ _ in MockProcessRunner.output("", stderr: "Error: The operation couldn’t be completed.\n  (WFBackgroundShortcutRunnerErrorDomain error 1.)\n",
                                             exit: .exited(1)) },
             .failed(message: "Error: The operation couldn’t be completed. (WFBackgroundShortcutRunnerErrorDomain error 1.)")),
            ({ _ in ChildProcess.Output(exit: .exited(0), stdout: Data(), stderr: Data(), exceededOutputLimit: true) }, .outputTooLarge),
        ]
        for (responder, expected) in cases {
            let setup = try setup(responder)
            defer { setup.remove() }
            await #expect(throws: expected) {
                try await setup.service.run(ShortcutInfo(name: "X", identifier: nil), input: "Input")
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: setup.inputDirectory.path).isEmpty, "\(expected)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: setup.outputParent.path).isEmpty, "\(expected)")
        }
    }

    /// Cancelling the run (Escape) stops the command and still deletes the files.
    @Test func cancellingStopsTheRunAndCleansUp() async throws {
        let setup = try setup { _ in throw CancellationError() }
        defer { setup.remove() }
        await #expect(throws: CancellationError.self) {
            try await setup.service.run(ShortcutInfo(name: "X", identifier: nil), input: "Input")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: setup.inputDirectory.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: setup.outputParent.path).isEmpty)
    }

    @Test func leftoversOfAnEarlierRunAreRemoved() async throws {
        let setup = try setup()
        defer { setup.remove() }
        try FileManager.default.createDirectory(at: setup.inputDirectory, withIntermediateDirectories: true)
        let oldInput = setup.inputDirectory.appendingPathComponent("alt.txt")
        try "alt".write(to: oldInput, atomically: false, encoding: .utf8)
        let oldOutput = try setup.folder.makeFolder("tmp/orbit-shortcut-alt")
        let unrelated = try setup.folder.makeFolder("tmp/etwas-anderes")
        let earlier = Date().addingTimeInterval(-2 * 60 * 60)
        for url in [oldInput, oldOutput, unrelated] {
            try FileManager.default.setAttributes([.modificationDate: earlier], ofItemAtPath: url.path)
        }
        _ = try await setup.service.run(ShortcutInfo(name: "X", identifier: nil), input: nil)
        #expect(!FileManager.default.fileExists(atPath: oldInput.path))
        #expect(!FileManager.default.fileExists(atPath: oldOutput.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path), "only Orbit's own leftovers")
    }

    // MARK: Output

    @Test func outputsAreReadAsTextOrDescribed() throws {
        let folder = try TemporaryFolder("orbit-shortcut-output")
        defer { folder.remove() }
        #expect(ShortcutOutputReader.read(directory: folder.url, stdout: Data()) == .none)
        #expect(ShortcutOutputReader.read(directory: folder.url, stdout: Data("  Hallo\n".utf8)) == .text("Hallo", isComplete: true),
                "printed text counts when no file was written")

        try folder.write("output", "Zeile 1\nZeile 2")
        #expect(ShortcutOutputReader.read(directory: folder.url, stdout: Data()) == .text("Zeile 1\nZeile 2", isComplete: true))

        try folder.write("output", data: Data("{\\rtf1\\ansi Fett {\\b gedruckt}}".utf8))
        guard case .text(let rich, true) = ShortcutOutputReader.read(directory: folder.url, stdout: Data()) else {
            Issue.record("rich text is read as its text")
            return
        }
        #expect(rich.trimmingCharacters(in: .whitespacesAndNewlines) == "Fett gedruckt")

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D]) + Data(count: 1_000)
        try folder.write("output", data: png)
        #expect(ShortcutOutputReader.read(directory: folder.url, stdout: Data())
            == .files([.init(typeIdentifier: "public.png", size: Int64(png.count))]))

        try folder.write("Bericht.pdf", data: Data("%PDF-1.7".utf8))
        guard case .files(let files) = ShortcutOutputReader.read(directory: folder.url, stdout: Data()) else {
            Issue.record("two files are described")
            return
        }
        #expect(files.map(\.typeIdentifier) == ["com.adobe.pdf", "public.png"])
    }

    @Test func longTextIsReadOnlyUpToTheLimit() throws {
        let folder = try TemporaryFolder("orbit-shortcut-output")
        defer { folder.remove() }
        // A two-byte character across the limit: it is dropped, not misread.
        try folder.write("output", "a" + String(repeating: "ä", count: ShortcutOutputReader.textReadLimit))
        guard case .text(let text, let isComplete) = ShortcutOutputReader.read(directory: folder.url, stdout: Data()) else {
            Issue.record("a long text is still text")
            return
        }
        #expect(!isComplete)
        #expect(text.count == ShortcutOutputReader.textReadLimit / 2 && text.first == "a" && text.dropFirst().allSatisfy { $0 == "ä" })
        #expect(ShortcutOutputReader.decodedText(Data([0x61, 0, 0x62])) == nil, "NUL bytes are no text")
    }

    @Test func typesAreSniffed() {
        #expect(ShortcutOutputReader.sniffedType(Data([0xFF, 0xD8, 0xFF, 0xE0])) == .jpeg)
        #expect(ShortcutOutputReader.sniffedType(Data("GIF89a".utf8)) == .gif)
        #expect(ShortcutOutputReader.sniffedType(Data([0, 0, 0, 0x18]) + Data("ftypheic".utf8)) == .heic)
        #expect(ShortcutOutputReader.sniffedType(Data([0x50, 0x4B, 0x03, 0x04])) == .zip)
        #expect(ShortcutOutputReader.sniffedType(Data("hello".utf8)) == nil)
    }

    @Test func errorOutputIsOneCutLine() {
        let message = ShortcutsCommand.errorMessage(Data(("Fehler:\n\n  " + String(repeating: "x", count: 1_000)).utf8))
        #expect(message.hasPrefix("Fehler: xxx") && message.count == 500)
    }
}
