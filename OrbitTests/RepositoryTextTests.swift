import Foundation
import Testing

/// Orbit's texts do without en and em dashes: the interface in both
/// languages, the sources and their comments, the tests, the scripts, the
/// workflows, the README and the documentation. Data that needs the characters writes them
/// as escapes (`"\u{2013}"`), so no file holds them literally.
@Suite("Repository text")
struct RepositoryTextTests {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let folders = ["Orbit", "OrbitTests", "DevTools", "Scripts", "Config", "docs", ".github"]
    static let rootFiles = ["Package.swift", "README.md", "CONTRIBUTING.md", "SECURITY.md", "CHANGELOG.md", "LICENSE", "mkdocs.yml"]
    static let dashes = CharacterSet(charactersIn: "\u{2013}\u{2014}")

    @Test func noFileContainsAnEnOrEmDash() throws {
        var checked = 0
        var found: [String] = []
        for file in try Self.textFiles() {
            // Files that are not UTF-8 (some mail fixtures) hold no such text.
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            checked += 1
            for (index, line) in text.components(separatedBy: "\n").enumerated() where Self.hasDash(line) {
                found.append("\(Self.relativePath(file)):\(index + 1)")
            }
        }
        #expect(found.isEmpty, "en or em dash in \(found.prefix(20).joined(separator: ", "))")
        #expect(checked > 300, "the scan found too few files: \(checked)")
    }

    @Test func theScanSeesBothDashes() {
        #expect(Self.hasDash("a \u{2013} b") && Self.hasDash("a\u{2014}b"))
        #expect(!Self.hasDash("a - b, a-b, --flag, →"))
    }

    static func hasDash(_ line: String) -> Bool {
        line.rangeOfCharacter(from: dashes) != nil
    }

    static func textFiles() throws -> [URL] {
        var files = rootFiles.map { repository.appendingPathComponent($0) }
        for folder in folders {
            let root = repository.appendingPathComponent(folder)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
                continue
            }
            for case let url as URL in enumerator {
                if [".build", "build"].contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      !["png", "icns", "jpg", "jpeg", "heic", "pdf", "zip", "scpt", "sqlite"].contains(url.pathExtension.lowercased())
                else { continue }
                files.append(url)
            }
        }
        return files
    }

    static func relativePath(_ url: URL) -> String {
        String(url.path.dropFirst(repository.path.count + 1))
    }
}
