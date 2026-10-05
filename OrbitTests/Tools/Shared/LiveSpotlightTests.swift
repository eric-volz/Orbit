import Foundation
import Testing
@testable import Orbit

/// Parent of the suites that query the live Spotlight index, always scoped to
/// the fixture folder, never anywhere else. Needs a Spotlight-indexed checkout
/// (the repository; a copy under /tmp is not indexed) and runs prepare-dates.sh
/// first. `.serialized`: a test adds files to the fixture folder that the others
/// must not see.
///
///     ORBIT_SPOTLIGHT_TESTS=1 Scripts/swiftpm.sh test --filter SpotlightIntegration
@Suite(.serialized, .enabled(if: SpotlightFixtures.isEnabled))
enum SpotlightIntegrationTests {}

extension SpotlightIntegrationTests {
    @Suite("LiveSpotlight (fixtures)")
    struct LiveSpotlightTests {
        let spotlight = LiveSpotlight()
        let fixtures = [SpotlightFixtures.url("")]
        /// The sample files without the generator scripts, whose text contains every sample word.
        let samples = ["Dokumente", "Rechnungen", "iWork", "Programme"].map(SpotlightFixtures.url)

        func names(_ query: SpotlightQuery) async throws -> [String] {
            try await SpotlightFixtures.names(query)
        }

        @Test func wordPrefixMatchingOnNamesAndContent() async throws {
            try await SpotlightFixtures.prepare()
            // Names: word prefixes, case- and diacritic-insensitive; not inside words.
            let rechn = try await names(SpotlightQuery(terms: ["rechn"], termMatch: .names, scopes: fixtures))
            #expect(rechn == ["Rechner.app", "Rechnung-Telekom-2026-06.pdf", "Rechnung-Telekom-2026-08.pdf", "Rechnungen"])
            let inside = try await names(SpotlightQuery(terms: ["elekom"], termMatch: .names, scopes: fixtures))
            #expect(inside == [])
            let folded = try await names(SpotlightQuery(terms: ["PRASENTATION"], termMatch: .names, scopes: fixtures))
            #expect(folded == ["Alt-Präsentation.key"])
            let both = try await names(SpotlightQuery(terms: ["telekom", "2026-06"], termMatch: .names, scopes: fixtures))
            #expect(both == ["Rechnung-Telekom-2026-06.pdf"])
            // Content: every format Spotlight imports, diacritics folded.
            for (term, file) in [("sofabezug", "Angebot.docx"), ("kundigungsfrist", "Brief.rtf"), ("KAUTION", "Vertrag.doc"),
                                 ("tagesordnung", "Protokoll.odt"), ("umzugskartons", "Notizen.md")] {
                let found = try await names(SpotlightQuery(terms: [term], scopes: samples))
                #expect(found == [file], "\(term)")
            }
            // A term must match the name or the content: "vodafone" (name) and "amount" (content).
            let mixed = try await names(SpotlightQuery(terms: ["vodafone", "amount"], scopes: samples))
            #expect(mixed == ["Vodafone-Invoice-2026-08.pdf"])
            // The scripts contain the sample texts, so a search over the whole folder finds them too.
            let everywhere = try await names(SpotlightQuery(terms: ["sofabezug"], scopes: fixtures))
            #expect(everywhere == ["Angebot.docx", "make-fixtures.sh"])
        }

        @Test func kindsDatesAndExclusions() async throws {
            try await SpotlightFixtures.prepare()
            // Spotlight types every flat .key file as Keynote, the fake private key too (the tools' policy drops it).
            let presentations = try await names(SpotlightQuery(contentTypes: FileKind.presentation.contentTypes, scopes: fixtures))
            #expect(presentations == ["Alt-Präsentation.key", "privat.key"])
            #expect(try await names(SpotlightQuery(contentTypes: FileKind.folder.contentTypes, scopes: [SpotlightFixtures.url("iWork")])) == [])
            let folders = try await names(SpotlightQuery(contentTypes: FileKind.folder.contentTypes, scopes: fixtures))
            #expect(folders.contains("Rechnungen") && folders.contains("Dokumente"))
            #expect(!folders.contains("Alt-Bericht.pages"), "packages are not folders")
            let pdfsLastMonth = try await names(SpotlightQuery(contentTypes: ["com.adobe.pdf"], modified: SpotlightFixtures.lastMonthBounds,
                                                              scopes: fixtures))
            #expect(pdfsLastMonth == ["Kontoauszug-2026-08.pdf", "Rechnung-Telekom-2026-08.pdf", "Vodafone-Invoice-2026-08.pdf"])
            let notPDFs = try await names(SpotlightQuery(excludedContentTypes: ["com.adobe.pdf"], modified: SpotlightFixtures.lastMonthBounds,
                                                         scopes: [SpotlightFixtures.url("Rechnungen")]))
            #expect(notPDFs == ["Invoice-Notes-2026-08.txt"])
        }

        @Test func readsAtMostMaxResultsInTheSortOrder() async throws {
            try await SpotlightFixtures.prepare()
            let results = try await spotlight.search(SpotlightQuery(scopes: [SpotlightFixtures.url("Dokumente")],
                                                                    sort: .modifiedNewestFirst, maxResults: 3),
                                                     timeout: .seconds(10))
            #expect(results.items.count == 3)
            #expect(results.totalCount >= 10)
            #expect(results.isComplete)
            let dates = results.items.compactMap(\.modified)
            #expect(dates == dates.sorted(by: >))
            #expect(results.items.first?.fileSystemName == "Notizen.md", "modified two days ago: the newest fixture")
            let item = try #require(results.items.first)
            #expect(item.path == FileFixtures.path("Dokumente/Notizen.md"))
            #expect(item.contentType == "net.daringfireball.markdown")
            #expect(item.contentTypeTree.contains("public.plain-text"))
            #expect(item.size == 74)
            #expect(item.kindDescription?.isEmpty == false)
        }

        @Test func lastUsedDatesAreRead() async throws {
            try await SpotlightFixtures.prepare()
            let results = try await spotlight.search(SpotlightQuery(lastUsed: .init(from: Date().addingTimeInterval(-3 * 86_400)),
                                                                    scopes: fixtures, sort: .lastUsedNewestFirst), timeout: .seconds(10))
            let angebot = try #require(results.items.first)
            #expect(angebot.fileSystemName == "Angebot.docx")
            let lastUsed = try #require(angebot.lastUsed)
            #expect(abs(lastUsed.timeIntervalSinceNow + 86_400) < 3_600, "yesterday")
        }

        @Test func progressiveSnapshotsEndWithACompleteOne() async throws {
            try await SpotlightFixtures.prepare()
            var snapshots: [SpotlightResults] = []
            for try await snapshot in spotlight.snapshots(of: SpotlightQuery(terms: ["rechnung"], termMatch: .names, scopes: fixtures),
                                                          timeout: .seconds(10)) {
                snapshots.append(snapshot)
            }
            let last = try #require(snapshots.last)
            #expect(last.isComplete)
            #expect(last.items.map(\.fileSystemName).sorted() == ["Rechnung-Telekom-2026-06.pdf", "Rechnung-Telekom-2026-08.pdf", "Rechnungen"])
            #expect(snapshots.dropLast().allSatisfy { !$0.isComplete && !$0.items.isEmpty })
        }

        @Test func aShortTimeoutReturnsWhatWasThereAndStops() async throws {
            try await SpotlightFixtures.prepare()
            // Display-name queries take ~180 ms to finish gathering.
            let start = ContinuousClock.now
            let results = try await spotlight.search(SpotlightQuery(terms: ["zzqq"], termMatch: .names, nameFields: .displayName,
                                                                    scopes: fixtures), timeout: .milliseconds(20))
            #expect(!results.isComplete)
            #expect(ContinuousClock.now - start < .milliseconds(150))
        }

        @Test func cancellingStopsTheQuery() async throws {
            try await SpotlightFixtures.prepare()
            let task = Task {
                try await LiveSpotlight().search(SpotlightQuery(terms: ["zzqq"], termMatch: .names, nameFields: .displayName,
                                                                scopes: [SpotlightFixtures.url("")]), timeout: .seconds(10))
            }
            try await Task.sleep(for: .milliseconds(30))
            task.cancel()
            let start = ContinuousClock.now
            await #expect(throws: CancellationError.self) { _ = try await task.value }
            #expect(ContinuousClock.now - start < .milliseconds(150))
            // Leaving a progressive iteration early stops it, too.
            for try await _ in spotlight.snapshots(of: SpotlightQuery(scopes: fixtures), timeout: .seconds(10)) {
                break
            }
        }

        @Test func termsMatchLiterallyAndNewFilesAreFound() async throws {
            try await SpotlightFixtures.prepare()
            // Generated files go to a unique, non-hidden subfolder that is removed afterwards.
            let name = "Generated-\(UUID().uuidString)"
            let folder = SpotlightFixtures.url(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            try Data("Quokkafrage\n".utf8).write(to: folder.appendingPathComponent("Stern*Datei.txt"))
            try Data("Quokkafrage\n".utf8).write(to: folder.appendingPathComponent("Sternwarte.txt"))
            try Data("Quokkafrage\n".utf8).write(to: folder.appendingPathComponent("Anführung\"szeichen.txt"))
            let importer = Process()
            importer.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport")
            importer.arguments = [folder.path]
            try importer.run()
            importer.waitUntilExit()

            let scope = [folder]
            let indexed = await SpotlightFixtures.waitUntil(timeout: .seconds(60)) {
                try await SpotlightFixtures.names(SpotlightQuery(terms: ["quokkafrage"], scopes: scope)).count == 3
            }
            #expect(indexed)
            #expect(try await names(SpotlightQuery(terms: ["stern*"], termMatch: .names, scopes: scope)) == ["Stern*Datei.txt"])
            #expect(try await names(SpotlightQuery(terms: ["stern"], termMatch: .names, scopes: scope)) == ["Stern*Datei.txt", "Sternwarte.txt"])
            #expect(try await names(SpotlightQuery(terms: ["*"], termMatch: .names, scopes: scope)) == ["Stern*Datei.txt"],
                    "a literal star, not a wildcard")
            #expect(try await names(SpotlightQuery(terms: ["anführung\""], termMatch: .names, scopes: scope)) == ["Anführung\"szeichen.txt"])
            #expect(try await names(SpotlightQuery(terms: [#"x" || kMDItemFSName == "*"#], termMatch: .names, scopes: scope)) == [])

            // Leave nothing behind for the other tests, also not in the index.
            try FileManager.default.removeItem(at: folder)
            let gone = await SpotlightFixtures.waitUntil(timeout: .seconds(60)) {
                try await SpotlightFixtures.names(SpotlightQuery(terms: ["quokkafrage"], scopes: fixtures)).isEmpty
            }
            #expect(gone)
        }
    }
}
