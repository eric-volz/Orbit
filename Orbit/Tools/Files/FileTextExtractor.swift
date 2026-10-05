import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Extracts plain text from a file for `read_file`. Synchronous and blocking:
/// call it off the main actor (tools run detached).
///
/// - Plain text, Markdown, source code, CSV, JSON, XML …: UTF-8, UTF-16/32 with
///   BOM, else Windows-1252, else Latin-1.
/// - RTF, RTFD, DOC, DOCX, ODT: NSAttributedString with an explicit document
///   type, never the HTML importer, which needs WebKit on the main thread.
/// - HTML: tags stripped by a small scanner, entities decoded.
/// - PDF: PDFKit, page by page until the limit.
/// - Pages, Numbers, Keynote: the legacy preview (QuickLook/Preview.pdf) in the
///   package or the ZIP file; documents without one cannot be read.
/// - Images, audio, video, archives, programs: refused as binary, unless the
///   content is clean UTF-8 text after all (TypeScript's .ts is typed as video).
/// - Anything else: read when it is valid UTF-8 without NUL bytes, else refused.
enum FileTextExtractor {
    static let maxPDFBytes: Int64 = 100_000_000
    static let maxOtherBytes: Int64 = 20_000_000
    /// Word (docx) and OpenDocument files are ZIP archives that the importer
    /// unpacks completely before any text could be cut: a small file can
    /// unpack to gigabytes. All their entries together may unpack to this much.
    static let maxUnpackedBytes: UInt64 = 50_000_000
    /// A text's characters are counted up to this many only; counting more
    /// costs a pass over all of it.
    static let maxCountedCharacters = 1_000_000

    struct Extraction: Sendable, Hashable {
        /// At most the requested number of characters.
        var text: String
        var isTruncated: Bool
        /// Characters in the whole text; nil when reading stopped early (PDF) or
        /// when there are more than `maxCountedCharacters`.
        var totalCharacters: Int?
        /// PDFs and iWork previews: pages in the document and pages read.
        var pageCount: Int?
        var pagesRead: Int?
        /// What was read, e.g. "PDF", "Word document", "plain text (UTF-8)".
        var format: String
    }

    enum Failure: Error, Sendable, Hashable {
        /// Not text; `kind` e.g. "an image", "a program".
        case binary(kind: String, isProgram: Bool)
        case tooLarge(bytes: Int64, limit: Int64)
        /// A Word or OpenDocument file whose contents unpack to more than `limit` bytes.
        case tooLargeUnpacked(bytes: Int64, limit: Int64)
        case encryptedPDF
        case noTextInPDF
        /// A Pages/Numbers/Keynote document without a preview PDF.
        case iWorkWithoutPreview(app: String)
        /// A format Orbit cannot extract, e.g. "Excel spreadsheets".
        case unsupported(format: String)
        case unreadable

        var modelMessage: String {
            switch self {
            case let .binary(kind, isProgram):
                isProgram
                    ? "This file is \(kind), not text, so Orbit cannot read it. It can be shown with reveal_in_finder."
                    : "This file is \(kind), not text, so Orbit cannot read it. It can be opened with open_file or shown with reveal_in_finder."
            case let .tooLarge(bytes, limit):
                "This file is too large to read (\(FileToolFormat.size(bytes)); the limit for this type is \(FileToolFormat.size(limit)))."
            case let .tooLargeUnpacked(bytes, limit):
                "This document is too large to read: unpacked, its contents are \(FileToolFormat.size(bytes)) (the limit is \(FileToolFormat.size(limit))). Suggest that the user opens it (open_file)."
            case .encryptedPDF:
                "This PDF is password-protected, so Orbit cannot read it. Suggest that the user opens it (open_file)."
            case .noTextInPDF:
                "This PDF contains no text layer (it is probably a scan), so Orbit cannot read it. Suggest that the user opens it (open_file)."
            case .iWorkWithoutPreview(let app):
                "Orbit cannot extract text from this \(app) document (only older \(app) files contain a readable preview). Suggest that the user opens it in \(app) (open_file)."
            case .unsupported(let format):
                "Orbit cannot extract text from \(format). Suggest that the user opens the file (open_file)."
            case .unreadable:
                "Orbit could not read this file; it may be damaged or in an unsupported format. Suggest that the user opens it (open_file)."
            }
        }
    }

    /// Reads `url` (a file or a document package) and returns at most
    /// `maxCharacters` characters of text.
    static func extract(from url: URL, maxCharacters: Int) throws -> Extraction {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .isDirectoryKey, .fileSizeKey]
        let values = try? url.resourceValues(forKeys: keys)
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        if values?.isDirectory == true {
            return try extractFromPackage(url, type: type, maxCharacters: maxCharacters)
        }
        let size = Int64(values?.fileSize ?? 0)

        if let type, type.conforms(to: .pdf) {
            guard size <= maxPDFBytes else { throw Failure.tooLarge(bytes: size, limit: maxPDFBytes) }
            guard let document = PDFDocument(url: url) else { throw Failure.unreadable }
            return try pdfText(document, maxCharacters: maxCharacters, format: "PDF")
        }
        if let app = iWorkApp(type, pathExtension: url.pathExtension) {
            return try iWorkPreview(zipAt: url, app: app, maxCharacters: maxCharacters)
        }
        guard size <= maxOtherBytes else { throw Failure.tooLarge(bytes: size, limit: maxOtherBytes) }
        if let (documentType, format) = attributedDocumentType(type) {
            if documentType == .officeOpenXML || documentType == .openDocument {
                try checkUnpackedSize(ofArchiveAt: url)
            }
            return limited(try attributedText(url, documentType: documentType), maxCharacters: maxCharacters,
                           format: format)
        }
        if let format = unsupportedFormat(type) {
            throw Failure.unsupported(format: format)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw Failure.unreadable
        }
        if let type, type.conforms(to: .html) {
            guard let (html, _) = decodeText(data, allowLegacyEncodings: true) else {
                throw Failure.binary(kind: "binary data", isProgram: false)
            }
            return limited(plainText(fromHTML: html), maxCharacters: maxCharacters, format: "HTML (tags removed)")
        }
        if let type, type.conforms(to: .text) {
            guard let (text, encoding) = decodeText(data, allowLegacyEncodings: true) else {
                throw Failure.binary(kind: "binary data", isProgram: false)
            }
            return limited(text, maxCharacters: maxCharacters, format: "text (\(encoding))")
        }
        // Binary by type, or unknown: only clean text passes.
        if let (text, encoding) = decodeText(data, allowLegacyEncodings: false) {
            return limited(text, maxCharacters: maxCharacters, format: "text (\(encoding))")
        }
        let (kind, isProgram) = binaryKind(type)
        throw Failure.binary(kind: kind, isProgram: isProgram)
    }

    // MARK: Packages

    private static func extractFromPackage(_ url: URL, type: UTType?, maxCharacters: Int) throws -> Extraction {
        if let app = iWorkApp(type, pathExtension: url.pathExtension) {
            let preview = url.appendingPathComponent("QuickLook/Preview.pdf")
            guard FileManager.default.fileExists(atPath: preview.path) else { throw Failure.iWorkWithoutPreview(app: app) }
            let size = (try? preview.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            guard Int64(size) <= maxPDFBytes else { throw Failure.tooLarge(bytes: Int64(size), limit: maxPDFBytes) }
            guard let document = PDFDocument(url: preview) else { throw Failure.unreadable }
            return try pdfText(document, maxCharacters: maxCharacters, format: "\(app) document (preview)")
        }
        if let type, type.conforms(to: .rtfd) {
            // The text of an RTFD package is its TXT.rtf; attachments are not needed.
            let text = url.appendingPathComponent("TXT.rtf")
            let size = (try? text.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            guard Int64(size) <= maxOtherBytes else { throw Failure.tooLarge(bytes: Int64(size), limit: maxOtherBytes) }
            return limited(try attributedText(text, documentType: .rtf), maxCharacters: maxCharacters,
                           format: "RTF document")
        }
        let (kind, isProgram) = binaryKind(type)
        throw Failure.binary(kind: kind, isProgram: isProgram)
    }

    // MARK: Types

    /// "Pages", "Numbers" or "Keynote" for iWork documents.
    static func iWorkApp(_ type: UTType?, pathExtension: String) -> String? {
        let identifier = type?.identifier ?? ""
        if identifier.hasPrefix("com.apple.iwork.pages") || identifier == "com.apple.page.pages" { return "Pages" }
        if identifier.hasPrefix("com.apple.iwork.numbers") { return "Numbers" }
        if identifier.hasPrefix("com.apple.iwork.keynote") || identifier == "com.apple.keynote.key" { return "Keynote" }
        switch pathExtension.lowercased() {
        case "pages": return "Pages"
        case "numbers": return "Numbers"
        case "key": return "Keynote"
        default: return nil
        }
    }

    private static func attributedDocumentType(_ type: UTType?) -> (NSAttributedString.DocumentType, String)? {
        guard let type else { return nil }
        switch type.identifier {
        case "com.microsoft.word.doc": return (.docFormat, "Word document")
        case "org.openxmlformats.wordprocessingml.document",
             "org.openxmlformats.wordprocessingml.document.macroenabled": return (.officeOpenXML, "Word document")
        case "org.oasis-open.opendocument.text": return (.openDocument, "OpenDocument text")
        case "com.apple.flat-rtfd": return (.rtfd, "RTF document")
        default: break
        }
        if type.conforms(to: .rtf) { return (.rtf, "RTF document") }
        return nil
    }

    private static func unsupportedFormat(_ type: UTType?) -> String? {
        guard let type, !type.conforms(to: .text) else { return nil }
        if type.conforms(to: .spreadsheet) { return "spreadsheets such as Excel or OpenDocument files" }
        if type.conforms(to: .presentation) { return "presentations such as PowerPoint or OpenDocument files" }
        if type.identifier == "org.idpf.epub-container" { return "EPUB books" }
        return nil
    }

    private static func binaryKind(_ type: UTType?) -> (String, isProgram: Bool) {
        guard let type else { return ("binary data", false) }
        if type.conforms(to: .application) || type.conforms(to: .executable) || type.conforms(to: .bundle) {
            return ("a program or bundle", true)
        }
        if type.conforms(to: .image) { return ("an image", false) }
        if type.conforms(to: .audio) { return ("an audio file", false) }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return ("a video", false) }
        if type.conforms(to: .diskImage) { return ("a disk image", false) }
        if type.conforms(to: .archive) { return ("an archive", false) }
        if type.conforms(to: .font) { return ("a font", false) }
        return ("binary data", false)
    }

    // MARK: Text

    /// Decodes text: a BOM decides (UTF-8, UTF-16, UTF-32); without one, UTF-8
    /// if valid, else (with `allowLegacyEncodings`) Windows-1252, then
    /// Latin-1. Data with NUL bytes (and no BOM) is not text.
    static func decodeText(_ data: Data, allowLegacyEncodings: Bool) -> (text: String, encoding: String)? {
        let boms: [([UInt8], String.Encoding, String)] = [
            ([0xEF, 0xBB, 0xBF], .utf8, "UTF-8"),
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian, "UTF-32"),
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian, "UTF-32"),
            ([0xFF, 0xFE], .utf16LittleEndian, "UTF-16"),
            ([0xFE, 0xFF], .utf16BigEndian, "UTF-16"),
        ]
        for (bom, encoding, name) in boms where data.starts(with: bom) {
            return String(data: data.dropFirst(bom.count), encoding: encoding).map { ($0, name) }
        }
        if data.contains(0) { return nil }
        if let text = String(data: data, encoding: .utf8) { return (text, "UTF-8") }
        guard allowLegacyEncodings else { return nil }
        if let text = String(data: data, encoding: .windowsCP1252) { return (text, "Windows-1252") }
        return String(data: data, encoding: .isoLatin1).map { ($0, "Latin-1") }
    }

    /// Refuses a ZIP-based document (docx, odt) before the importer unpacks it:
    /// the importer allocates what the archive's directory declares for each
    /// entry and fails on anything larger, so the declared sizes of all entries
    /// (styles, footnotes and media are unpacked too) must stay within `limit`.
    /// An archive whose entries cannot all be accounted for (ZIP64, encrypted,
    /// a directory that does not add up) is refused as unreadable.
    static func checkUnpackedSize(ofArchiveAt url: URL, limit: UInt64 = maxUnpackedBytes) throws {
        guard let archive = ZipArchive(url: url), archive.isComplete else { throw Failure.unreadable }
        let total = archive.totalUncompressedSize
        guard total <= limit else {
            throw Failure.tooLargeUnpacked(bytes: Int64(clamping: total), limit: Int64(clamping: limit))
        }
    }

    private static func attributedText(_ url: URL, documentType: NSAttributedString.DocumentType) throws -> String {
        do {
            let string = try NSAttributedString(url: url, options: [.documentType: documentType],
                                                documentAttributes: nil)
            // Attachments appear as U+FFFC.
            return string.string.replacingOccurrences(of: "\u{FFFC}", with: "")
        } catch {
            throw Failure.unreadable
        }
    }

    private static func limited(_ text: String, maxCharacters: Int, format: String) -> Extraction {
        let (kept, isTruncated) = Truncation.cut(text, maxCharacters: maxCharacters)
        let total = isTruncated ? characterCount(text, limit: maxCountedCharacters) : kept.count
        return Extraction(text: kept, isTruncated: isTruncated, totalCharacters: total, format: format)
    }

    /// The characters in `text`, or nil when there are more than `limit`.
    static func characterCount(_ text: String, limit: Int) -> Int? {
        var count = 0
        for _ in text {
            count += 1
            if count > limit { return nil }
        }
        return count
    }

    // MARK: PDF

    /// Reads pages until `maxCharacters` are collected. Multi-page documents get
    /// "[Page n]" markers.
    static func pdfText(_ document: PDFDocument, maxCharacters: Int, format: String) throws -> Extraction {
        if document.isLocked, !document.unlock(withPassword: "") {
            throw Failure.encryptedPDF
        }
        let pageCount = document.pageCount
        var text = ""
        var characters = 0
        var pagesRead = 0
        var hasText = false
        for index in 0..<pageCount {
            try Task.checkCancellation()
            let pageText = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !pageText.isEmpty { hasText = true }
            let piece = pageCount > 1 ? "[Page \(index + 1)]\n\(pageText)" : pageText
            if !text.isEmpty {
                text += "\n\n"
                characters += 2
            }
            text += piece
            characters += piece.count
            pagesRead = index + 1
            if characters > maxCharacters { break }
        }
        guard hasText else { throw Failure.noTextInPDF }
        let (kept, isTruncated) = Truncation.cut(text, maxCharacters: maxCharacters)
        let readAll = pagesRead == pageCount
        return Extraction(text: kept, isTruncated: isTruncated || !readAll, totalCharacters: readAll ? characters : nil,
                          pageCount: pageCount, pagesRead: pagesRead, format: format)
    }

    // MARK: iWork

    private static func iWorkPreview(zipAt url: URL, app: String, maxCharacters: Int) throws -> Extraction {
        guard let archive = ZipArchive(url: url), let entry = archive.entry(named: "QuickLook/Preview.pdf") else {
            throw Failure.iWorkWithoutPreview(app: app)
        }
        let data: Data
        do {
            data = try archive.data(of: entry, maxSize: UInt64(maxPDFBytes))
        } catch ZipArchive.Failure.tooLarge {
            throw Failure.tooLarge(bytes: Int64(entry.uncompressedSize), limit: maxPDFBytes)
        } catch {
            throw Failure.unreadable
        }
        guard let document = PDFDocument(data: data) else { throw Failure.unreadable }
        return try pdfText(document, maxCharacters: maxCharacters, format: "\(app) document (preview)")
    }

    // MARK: HTML

    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "br", "dd", "div", "dl", "dt", "figcaption", "figure", "footer",
        "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section",
        "table", "title", "tr", "ul",
    ]
    private static let skippedTags: Set<String> = ["script", "style", "noscript", "template", "svg"]

    /// The visible text of an HTML document: comments, scripts and styles
    /// removed, block elements as line breaks, entities decoded, whitespace
    /// collapsed. A linear scan, no regular expressions to backtrack.
    static func plainText(fromHTML html: String) -> String {
        var output = ""
        var index = html.startIndex
        while index < html.endIndex {
            guard let open = html[index...].firstIndex(of: "<") else {
                output += html[index...]
                break
            }
            output += html[index..<open]
            if html[open...].hasPrefix("<!--") {
                index = html.range(of: "-->", range: open..<html.endIndex)?.upperBound ?? html.endIndex
                continue
            }
            // Like browsers: "<" starts a tag only before a letter, "/", "!" or "?"; otherwise it is text.
            let next = html.index(after: open)
            guard next < html.endIndex, html[next].isLetter || "/!?".contains(html[next]) else {
                output += "<"
                index = next
                continue
            }
            guard let close = html[open...].firstIndex(of: ">") else { break }
            let inner = html[html.index(after: open)..<close]
            let isClosing = inner.hasPrefix("/")
            let name = inner.drop(while: { $0 == "/" }).prefix(while: { $0.isLetter || $0.isNumber }).lowercased()
            index = html.index(after: close)
            if !isClosing, skippedTags.contains(name) {
                if let end = html.range(of: "</" + name, options: .caseInsensitive, range: index..<html.endIndex) {
                    index = html[end.upperBound...].firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex
                } else {
                    index = html.endIndex
                }
                continue
            }
            if blockTags.contains(name) {
                output += "\n"
            } else if name == "td" || name == "th" {
                output += " "
            }
        }
        return collapsingWhitespace(decodingEntities(output))
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "shy": "",
        "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "copy": "©", "reg": "®", "trade": "™", "deg": "°",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "…", "laquo": "«", "raquo": "»", "bdquo": "„", "ldquo": "“",
        "rdquo": "”", "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "middot": "·", "bull": "•", "sect": "§",
        "para": "¶", "times": "×", "divide": "÷", "eacute": "é", "egrave": "è", "ecirc": "ê", "aacute": "á",
        "agrave": "à", "acirc": "â", "ccedil": "ç", "iacute": "í", "oacute": "ó", "ograve": "ò", "ocirc": "ô",
        "uacute": "ú", "ugrave": "ù", "ntilde": "ñ", "Eacute": "É",
    ]

    static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        var index = text.startIndex
        while let ampersand = text[index...].firstIndex(of: "&") {
            output += text[index..<ampersand]
            let afterAmpersand = text.index(after: ampersand)
            let window = text[afterAmpersand...].prefix(12)
            if let semicolon = window.firstIndex(of: ";"), let decoded = entity(String(text[afterAmpersand..<semicolon])) {
                output += decoded
                index = text.index(after: semicolon)
            } else {
                output += "&"
                index = afterAmpersand
            }
        }
        output += text[index...]
        return output
    }

    private static func entity(_ name: String) -> String? {
        if let named = namedEntities[name] { return named }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
        return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        var lines: [String] = []
        var blankRun = 0
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let collapsed = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" })
                .joined(separator: " ")
            if collapsed.isEmpty {
                blankRun += 1
                if blankRun == 1, !lines.isEmpty { lines.append("") }
            } else {
                blankRun = 0
                lines.append(collapsed)
            }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
