import Foundation

/// The kinds `search_files` and `recent_files` filter by, mapped to content
/// types. An item has a kind when its content type tree (kMDItemContentTypeTree)
/// contains one of `contentTypes` and none of `excludedContentTypes`.
enum FileKind: String, CaseIterable, Sendable, Hashable {
    case pdf
    case image
    case document
    case presentation
    case spreadsheet
    case folder
    case text
    case code
    case audio
    case video
    case archive

    var contentTypes: [String] {
        switch self {
        case .pdf:
            ["com.adobe.pdf"]
        case .image:
            ["public.image"]
        case .document:
            Self.wordProcessingTypes
        case .presentation:
            ["public.presentation", "com.apple.iwork.keynote.key", "com.apple.iwork.keynote.sffkey",
             "com.apple.keynote.key", "com.microsoft.powerpoint.ppt",
             "org.openxmlformats.presentationml.presentation", "org.oasis-open.opendocument.presentation"]
        case .spreadsheet:
            ["public.spreadsheet", "com.apple.iwork.numbers.numbers", "com.apple.iwork.numbers.sffnumbers",
             "com.microsoft.excel.xls", "org.openxmlformats.spreadsheetml.sheet",
             "org.oasis-open.opendocument.spreadsheet", "public.comma-separated-values-text",
             "public.tab-separated-values-text"]
        case .folder:
            ["public.folder"]
        case .text:
            ["public.plain-text"]
        case .code:
            ["public.source-code", "public.script", "public.json", "public.yaml"]
        case .audio:
            ["public.audio"]
        case .video:
            ["public.movie"]
        case .archive:
            ["public.archive"]
        }
    }

    /// Plain text without source code (both conform to public.plain-text).
    var excludedContentTypes: [String] {
        self == .text ? ["public.source-code"] : []
    }

    /// For the tool schema: what each kind covers.
    static let schemaDescription = """
        File kind: pdf; image; document (word processing: Pages, Word, OpenDocument text, RTF, not PDF); \
        presentation (Keynote, PowerPoint); spreadsheet (Numbers, Excel, CSV); folder; text (plain text and \
        Markdown); code (source code, scripts, JSON); audio; video; archive (zip, disk images, …).
        """

    static let wordProcessingTypes = [
        "com.apple.iwork.pages.pages", "com.apple.iwork.pages.sffpages", "com.apple.page.pages",
        "com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document",
        "org.openxmlformats.wordprocessingml.document.macroenabled", "com.microsoft.word.wordml",
        "org.oasis-open.opendocument.text", "public.rtf", "com.apple.rtfd", "com.apple.flat-rtfd",
    ]

    /// Whether an item with this content type tree has the kind.
    func matches(contentTypeTree tree: [String]) -> Bool {
        tree.contains { contentTypes.contains($0) } && !tree.contains { excludedContentTypes.contains($0) }
    }

    // MARK: Labels for the model

    /// Specific formats by exact content type.
    private static let formatLabels: [String: String] = [
        "com.adobe.pdf": "PDF",
        "com.microsoft.word.doc": "Word document",
        "org.openxmlformats.wordprocessingml.document": "Word document",
        "org.openxmlformats.wordprocessingml.document.macroenabled": "Word document",
        "com.apple.iwork.pages.pages": "Pages document",
        "com.apple.iwork.pages.sffpages": "Pages document",
        "com.apple.page.pages": "Pages document",
        "org.oasis-open.opendocument.text": "OpenDocument text",
        "public.rtf": "RTF document",
        "com.apple.rtfd": "RTF document",
        "com.apple.flat-rtfd": "RTF document",
        "com.microsoft.excel.xls": "Excel spreadsheet",
        "org.openxmlformats.spreadsheetml.sheet": "Excel spreadsheet",
        "com.apple.iwork.numbers.numbers": "Numbers spreadsheet",
        "com.apple.iwork.numbers.sffnumbers": "Numbers spreadsheet",
        "org.oasis-open.opendocument.spreadsheet": "OpenDocument spreadsheet",
        "public.comma-separated-values-text": "CSV",
        "public.tab-separated-values-text": "TSV",
        "com.microsoft.powerpoint.ppt": "PowerPoint presentation",
        "org.openxmlformats.presentationml.presentation": "PowerPoint presentation",
        "com.apple.iwork.keynote.key": "Keynote presentation",
        "com.apple.iwork.keynote.sffkey": "Keynote presentation",
        "com.apple.keynote.key": "Keynote presentation",
        "org.oasis-open.opendocument.presentation": "OpenDocument presentation",
        "net.daringfireball.markdown": "Markdown",
        "public.html": "HTML",
        "public.json": "JSON",
        "public.xml": "XML",
        "public.folder": "folder",
    ]

    /// A short English label for the model, e.g. "PDF", "Word document",
    /// "folder", "image", "plain text"; "file" when nothing fits.
    static func label(contentType: String?, contentTypeTree tree: [String]) -> String {
        if let contentType, let label = formatLabels[contentType] { return label }
        if tree.contains("public.folder") { return "folder" }
        if tree.contains("com.apple.application") { return "application" }
        if tree.contains("com.apple.package") { return "package" }
        let ordered: [(FileKind, String)] = [
            (.presentation, "presentation"), (.spreadsheet, "spreadsheet"), (.document, "document"),
            (.image, "image"), (.audio, "audio"), (.video, "video"), (.archive, "archive"),
            (.code, "source code"), (.text, "plain text"),
        ]
        return ordered.first { $0.0.matches(contentTypeTree: tree) }?.1 ?? "file"
    }
}
