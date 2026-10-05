import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Orbit

@Suite("FileKind")
struct FileKindTests {
    /// The content type tree Spotlight stores: the type and everything it conforms to.
    static func tree(_ identifier: String) -> [String] {
        guard let type = UTType(identifier) else { return [identifier] }
        var result = [type.identifier]
        var queue = Array(type.supertypes)
        while let next = queue.popLast() {
            if !result.contains(next.identifier) { result.append(next.identifier) }
        }
        return result
    }

    static func tree(forExtension pathExtension: String, directory: Bool = false) -> [String] {
        let type = UTType(filenameExtension: pathExtension, conformingTo: directory ? .directory : .data)
        return tree(type?.identifier ?? "public.data")
    }

    @Test(arguments: [
        ("pdf", FileKind.pdf), ("png", .image), ("heic", .image), ("jpg", .image),
        ("docx", .document), ("doc", .document), ("odt", .document), ("rtf", .document), ("pages", .document),
        ("key", .presentation), ("pptx", .presentation), ("odp", .presentation),
        ("numbers", .spreadsheet), ("xlsx", .spreadsheet), ("csv", .spreadsheet), ("ods", .spreadsheet),
        ("txt", .text), ("md", .text), ("log", .text),
        ("swift", .code), ("py", .code), ("sh", .code), ("json", .code), ("yaml", .code),
        ("mp3", .audio), ("m4a", .audio), ("mov", .video), ("mp4", .video),
        ("zip", .archive), ("dmg", .archive), ("tgz", .archive),
    ])
    func extensionsHaveTheirKind(pathExtension: String, kind: FileKind) {
        #expect(kind.matches(contentTypeTree: Self.tree(forExtension: pathExtension)), "\(pathExtension) → \(kind)")
    }

    @Test func kindsDoNotOverlapWhereTheyShouldNot() {
        #expect(!FileKind.text.matches(contentTypeTree: Self.tree(forExtension: "swift")), "code is not plain text")
        #expect(!FileKind.document.matches(contentTypeTree: Self.tree(forExtension: "pdf")), "PDF has its own kind")
        #expect(!FileKind.image.matches(contentTypeTree: Self.tree(forExtension: "pdf")))
        #expect(!FileKind.folder.matches(contentTypeTree: Self.tree(forExtension: "app", directory: true)))
        #expect(FileKind.folder.matches(contentTypeTree: Self.tree("public.folder")))
        #expect(FileKind.document.matches(contentTypeTree: Self.tree(forExtension: "pages", directory: true)))
        #expect(FileKind.presentation.matches(contentTypeTree: Self.tree(forExtension: "key", directory: true)))
    }

    @Test func everyKindIsInTheSchemaDescription() {
        for kind in FileKind.allCases {
            #expect(FileKind.schemaDescription.contains(kind.rawValue))
        }
    }

    @Test(arguments: [
        ("com.adobe.pdf", "PDF"),
        ("org.openxmlformats.wordprocessingml.document", "Word document"),
        ("com.apple.iwork.pages.sffpages", "Pages document"),
        ("com.apple.iwork.keynote.key", "Keynote presentation"),
        ("net.daringfireball.markdown", "Markdown"),
        ("public.folder", "folder"),
        ("public.png", "image"),
        ("public.swift-source", "source code"),
        ("public.plain-text", "plain text"),
        ("public.mp3", "audio"),
        ("com.apple.quicktime-movie", "video"),
        ("public.zip-archive", "archive"),
        ("com.apple.application-bundle", "application"),
        ("public.svg-image", "image"),
        ("public.data", "file"),
    ])
    func labelsForTheModel(identifier: String, label: String) {
        #expect(FileKind.label(contentType: identifier, contentTypeTree: Self.tree(identifier)) == label)
    }
}
