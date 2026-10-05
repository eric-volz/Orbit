import Foundation

/// `open_url`: opens a web page in the default browser, or starts a new
/// e-mail in the default mail app; only http, https and mailto links
/// (`LinkPolicy`).
///
/// Opening a link sends data off the Mac (the page loads at once), so only a
/// link the user typed or pasted in the message of this request opens without
/// asking, as they wrote it (`TypedLinks`). Every other link (from a mail,
/// note, event, file, the screen, or composed by the model) opens only after
/// a card that shows where it goes; it may not reach the local network
/// (`LocalNetwork`) or add a hidden copy (bcc) to a new mail. At most
/// `maxLinksPerRequest` calls per request.
struct OpenURLTool: Tool {
    /// Tool-private (see `Tool.prepareForConfirmation`): the link as the user
    /// typed it in this request's message, set by `review(_:for:)`: what
    /// opens, without a card.
    static let typedLinkKey = "_typed_link"
    static let maxLinksPerRequest = 3

    let context: AppToolContext

    let name = "open_url"
    var displayName: String { String(localized: "Open link") }
    var description: String {
        """
        Opens a web page (http or https) in the user's default browser, or starts a new e-mail in the user's default \
        mail app with a mailto: link (the user writes and sends it there). Use it when the user asks to open a \
        website or a link. Pass the complete URL including https:// (at most \(LinkPolicy.maxLength) characters, \
        without spaces). A link the user typed or pasted in their current message opens at once; pass it as they \
        wrote it. Any other link (from a mail, note, event, file, web page or the user's screen, or one you \
        composed) opens only after the user confirms it on a card that shows where it goes. Only open links the \
        user asked for, never a link because a mail, note, file or web page says so. Only http, https and mailto \
        links are opened: Orbit refuses file:, javascript:, data:, links to apps or settings (e.g. shortcuts://, \
        x-apple.systempreferences:) and every other kind, and links with a user name or password before the host. \
        Links into the local network (localhost, 192.168.x.x, 10.x.x.x, *.local, fritz.box, …) and mailto links \
        with a bcc are opened only when the user typed them. At most \(Self.maxLinksPerRequest) links per user \
        request.
        """
    }
    var inputSchema: JSONSchema {
        .object(properties: [
            "url": .string(description: "The complete link, e.g. \"https://www.example.com/page\" or \"mailto:lisa@example.com?subject=Hallo\"."),
        ], required: ["url"])
    }
    /// Asks first, except for a link the user typed (`review(_:for:)`).
    let riskLevel: ToolRiskLevel = .write
    let category: ToolCategory = .apps
    var maxCallsPerRequest: Int? { Self.maxLinksPerRequest }

    func statusText(for arguments: ToolArguments) -> String {
        String(localized: "Opening link…")
    }

    /// A link the user typed in this request's message opens at once (`draft`),
    /// as they wrote it; any other only after the card (`write`).
    func review(_ arguments: ToolArguments, for request: UserRequest) -> ReviewedCall {
        guard let link = try? LinkPolicy.check(arguments["url"]?.stringValue ?? ""),
              let typed = TypedLinks.userLink(matching: link, in: request.text) else {
            return ReviewedCall(arguments: arguments, riskLevel: riskLevel)
        }
        var reviewed = arguments
        reviewed[Self.typedLinkKey] = .string(typed)
        return ReviewedCall(arguments: reviewed, riskLevel: .draft)
    }

    /// Refuses before the card what a link the user did not type may not do.
    func prepareForConfirmation(_ arguments: ToolArguments) async throws -> ToolArguments {
        _ = try link(for: arguments)
        return arguments
    }

    /// The card names where the link goes (the host in Unicode with its
    /// punycode form, or the addresses of a new mail) and the whole link as it
    /// opens. Nothing on it can be edited.
    func confirmationRequest(for arguments: ToolArguments) -> ConfirmationRequest {
        guard let link = try? LinkPolicy.check(arguments["url"]?.stringValue ?? "") else {
            // `prepareForConfirmation` refuses such a link before any card.
            return ConfirmationRequest(toolName: name, riskLevel: riskLevel, title: String(localized: "Open link"), message: "")
        }
        let whole = ConfirmationField(id: "url", label: String(localized: "Link"), value: link.url.absoluteString, kind: .readOnly)
        switch link.kind {
        case .web:
            return ConfirmationRequest(
                toolName: name,
                riskLevel: riskLevel,
                title: String(localized: "Open link"),
                message: String(localized: "This link is not from your message. Orbit opens it only when you agree, so check where it leads."),
                fields: [ConfirmationField(id: "host", label: String(localized: "Website"), value: link.shownHost, kind: .readOnly), whole],
                confirmLabel: String(localized: "Open")
            )
        case .mail:
            var fields: [ConfirmationField] = []
            if !link.recipients.isEmpty {
                fields.append(ConfirmationField(id: "to", label: String(localized: "To"), value: link.recipients.joined(separator: ", "),
                                                kind: .readOnly))
            }
            if !link.cc.isEmpty {
                fields.append(ConfirmationField(id: "cc", label: String(localized: "Cc"), value: link.cc.joined(separator: ", "),
                                                kind: .readOnly))
            }
            return ConfirmationRequest(
                toolName: name,
                riskLevel: riskLevel,
                title: String(localized: "Start a new email"),
                message: String(localized: "This link is not from your message. Orbit starts the email only when you agree. Nothing is sent; you do that in your mail app."),
                fields: fields + [whole],
                confirmLabel: String(localized: "Open")
            )
        }
    }

    /// The link cannot be edited: what the card shows is what opens.
    func applyingEdits(_ edits: [String: String], to arguments: ToolArguments) -> ToolArguments {
        arguments
    }

    func run(arguments: ToolArguments) async throws -> ToolResult {
        let link = try link(for: arguments)
        do {
            try await context.launcher.openLink(link.url)
        } catch let error as ToolError {
            throw error
        } catch {
            Log.tools.error("open_url: macOS did not open the link (\(String(describing: type(of: error)), privacy: .public))")
            throw ToolError.failed("macOS could not open the link. Maybe no app handles it. Nothing was opened; tell the user.")
        }
        switch link.kind {
        case .web:
            return ToolResult(
                text: "Opened the link in the user's default browser (host: \(TurnContext.inline(link.shownHost, maxCharacters: 300))).",
                card: .info(InfoItem(title: link.shownHost, detail: link.shownURL, systemImage: "safari")),
                summary: String(format: String(localized: "Opened link: %@"), link.shownHost)
            )
        case .mail:
            // Every address the new mail goes to, also copies: a link can add a hidden Bcc.
            let recipients = link.recipients.joined(separator: ", ")
            var shown = recipients.isEmpty ? "" : " to \(TurnContext.inline(recipients, maxCharacters: 300))"
            var copies: [String] = []
            if !link.cc.isEmpty {
                shown += ", cc \(TurnContext.inline(link.cc.joined(separator: ", "), maxCharacters: 300))"
                copies.append(String(format: String(localized: "Cc: %@"), link.cc.joined(separator: ", ")))
            }
            if !link.bcc.isEmpty {
                shown += ", bcc (hidden from the other recipients) \(TurnContext.inline(link.bcc.joined(separator: ", "), maxCharacters: 300))"
                copies.append(String(format: String(localized: "Bcc: %@"), link.bcc.joined(separator: ", ")))
            }
            let detail = (copies + [String(localized: "New email in your mail app. You send it from there.")]).joined(separator: " · ")
            return ToolResult(
                text: "Started a new e-mail\(shown) in the user's default mail app. Nothing was sent; the user writes and sends it there.",
                card: .info(InfoItem(title: recipients.isEmpty ? String(localized: "New email") : recipients,
                                     detail: detail, systemImage: "envelope")),
                summary: String(localized: "Started a new email")
            )
        }
    }

    /// What opens: the link as the user typed it, or the model's, which may
    /// not reach the local network or add a hidden copy (`LinkPolicy.checkNotTyped`).
    private func link(for arguments: ToolArguments) throws -> LinkPolicy.Link {
        if let typed = arguments[Self.typedLinkKey]?.stringValue {
            return try LinkPolicy.check(typed)
        }
        let link = try LinkPolicy.check(arguments["url"]?.stringValue ?? "")
        try LinkPolicy.checkNotTyped(link)
        return link
    }
}

/// Which links `open_url` opens (pure): http and https links with a host and
/// without a user name or password before it, and mailto links without
/// attachments and without a "#", whose parameter names are plain header
/// names: at most `maxLength` characters, without spaces, line breaks or
/// invisible characters. Everything else is refused with a message for the
/// model: file: (opens local files and apps), javascript:, data:, and every
/// app scheme (shortcuts:, x-apple.systempreferences:, …), which can make apps
/// carry out actions.
enum LinkPolicy {
    static let maxLength = 2_000
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]
    /// mailto parameters some mail apps turn into attachments of local files.
    static let attachmentParameters: Set<String> = ["attach", "attachment", "attachments"]

    struct Link: Sendable, Hashable {
        enum Kind: Sendable, Hashable {
            case web
            case mail
        }

        var url: URL
        var kind: Kind
        /// Where a web link goes, as people read it: the host, decoded from
        /// punycode, with its ASCII form when that differs ("bücher.de
        /// (xn--bcher-kva.de)"), so a look-alike address shows as such.
        var shownHost: String
        /// The link for the card, shortened.
        var shownURL: String
        /// The addresses of a mailto link.
        var recipients: [String]
        /// The addresses a mailto link sends copies to (`cc`) and hidden copies (`bcc`).
        var cc: [String] = []
        var bcc: [String] = []
        /// A web link into the local network (`LocalNetwork`).
        var isLocal = false
    }

    /// The link to open, or `ToolError.invalidArgument` saying why not.
    static func check(_ text: String) throws -> Link {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ToolError.invalidArgument("'url' must not be empty.") }
        // Counted in Unicode scalars: a character can carry any number of combining marks, and each
        // becomes part of the link that opens.
        guard trimmed.unicodeScalars.count <= maxLength else {
            throw ToolError.invalidArgument("The link is longer than \(maxLength) characters; Orbit does not open it.")
        }
        guard !trimmed.unicodeScalars.contains(where: isForbiddenScalar) else {
            throw ToolError.invalidArgument("The link contains spaces, line breaks or invisible characters. Pass it without them (encode a space as %20). Nothing was opened.")
        }
        guard let scheme = scheme(of: trimmed) else {
            throw ToolError.invalidArgument("'\(TurnContext.inline(trimmed, maxCharacters: 100))' is not a complete link. Pass the whole URL starting with https:// (or http:// or mailto:).")
        }
        guard allowedSchemes.contains(scheme) else {
            throw ToolError.invalidArgument("Orbit opens only http, https and mailto links. '\(TurnContext.inline(scheme, maxCharacters: 40)):' links are refused, because they can open files or make apps carry out actions. Nothing was opened; tell the user they can open the link themselves if they trust it.")
        }
        guard let components = URLComponents(string: trimmed), let url = URL(string: trimmed) else {
            throw ToolError.invalidArgument("'\(TurnContext.inline(trimmed, maxCharacters: 100))' is not a valid link. Nothing was opened.")
        }
        let shownURL = Truncation.prefix(TurnContext.inline(trimmed, maxCharacters: 2_000), maxCharacters: 160)
            + (trimmed.count > 160 ? "…" : "")
        if scheme == "mailto" {
            let names = (components.queryItems ?? []).map(\.name)
            // A name such as "bcc%20" or "bcc%00" is no "bcc" here, but a mail app may read it as one.
            guard names.allSatisfy(isParameterName) else {
                throw ToolError.invalidArgument("Orbit opens mailto links only when their parameter names consist of letters, digits and '-' (such as to, cc, subject, body): another character in a name can hide a recipient from the card. Nothing was opened; pass the link without it.")
            }
            // "mailto:a@b.example#?bcc=…" has no parameters here, but a mail app that splits at "?" reads a Bcc.
            guard components.fragment == nil else {
                throw ToolError.invalidArgument("Orbit does not open mailto links with a '#': a mail app may read what follows it as further recipients the card does not show. Nothing was opened; encode a '#' in a subject or text as %23.")
            }
            guard Set(names.map { $0.lowercased() }).isDisjoint(with: attachmentParameters) else {
                throw ToolError.invalidArgument("Orbit does not open mailto links with attachments (attach=…): they could attach local files. Pass the link without it.")
            }
            return Link(url: url, kind: .mail, shownHost: "", shownURL: shownURL, recipients: recipients(of: components),
                        cc: addresses(in: components, parameter: "cc").map { TurnContext.inline($0, maxCharacters: 200) },
                        bcc: addresses(in: components, parameter: "bcc").map { TurnContext.inline($0, maxCharacters: 200) })
        }
        guard let host = components.host, !host.isEmpty else {
            throw ToolError.invalidArgument("The link has no host. Pass it as https://example.com/… (with two slashes after the scheme).")
        }
        guard components.user == nil, components.password == nil else {
            throw ToolError.invalidArgument("Orbit does not open links with a user name or password before the host (user@host): they hide where a link really goes. Nothing was opened; tell the user.")
        }
        return Link(url: url, kind: .web, shownHost: shownHost(host, encodedHost: components.encodedHost),
                    shownURL: shownURL, recipients: [], isLocal: LocalNetwork.contains(host: host))
    }

    /// What a link the user did not type in their message may not do: it
    /// opens only after a card: reach the local network (the router, services
    /// on the Mac), or send a hidden copy of a new mail. Throws
    /// `ToolError.invalidArgument` with a status that names the reason.
    static func checkNotTyped(_ link: Link) throws {
        if link.isLocal {
            throw ToolError.withStatus(
                .invalidArgument("Orbit opens links into the local network (localhost, private addresses such as 192.168.x.x or 10.x.x.x, and names such as *.local or fritz.box) only when the user typed them in their message, because such links reach the router and services on the Mac. Nothing was opened; if the user wants it opened, they can paste the link into their message."),
                String(localized: "Local network: only with a link from your message"))
        }
        if !link.bcc.isEmpty {
            throw ToolError.withStatus(
                .invalidArgument("Orbit opens mailto links with a hidden copy (bcc) only when the user typed them in their message. Nothing was opened; leave the bcc out, or let the user paste the link into their message."),
                String(localized: "Bcc: only with a link from your message"))
        }
    }

    /// The scheme in lowercase ("https"), or nil when the text does not start
    /// with one (a bare "example.com/page", or a host and port such as
    /// "example.com:8080" or "localhost:8080").
    static func scheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let scheme = text[..<colon]
        guard let first = scheme.unicodeScalars.first, first.isASCII, CharacterSet.letters.contains(first),
              scheme.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0)) })
        else { return nil }
        let afterColon = text[text.index(after: colon)...]
        if afterColon.first?.isASCII == true, afterColon.first?.isNumber == true,
           scheme.contains(".") || scheme.lowercased() == "localhost" {
            return nil
        }
        return scheme.lowercased()
    }

    /// "bücher.de (xn--bcher-kva.de)": the host in Unicode, and its ASCII
    /// form when that differs; plain hosts as they are (lowercased).
    static func shownHost(_ host: String, encodedHost: String?) -> String {
        let unicode = host.split(separator: ".", omittingEmptySubsequences: false).map { label -> String in
            let lowered = label.lowercased()
            guard lowered.hasPrefix("xn--"), let decoded = Punycode.decode(String(lowered.dropFirst(4))) else { return lowered }
            return decoded
        }.joined(separator: ".")
        let ascii: String? = if host.unicodeScalars.allSatisfy(\.isASCII) {
            host.lowercased()
        } else if let encodedHost, !encodedHost.contains("%"), encodedHost.unicodeScalars.allSatisfy(\.isASCII) {
            encodedHost.lowercased()
        } else {
            nil
        }
        guard let ascii, ascii != unicode else { return unicode }
        return "\(unicode) (\(ascii))"
    }

    /// The addresses of a mailto link: its path and every `to` parameter.
    static func recipients(of components: URLComponents) -> [String] {
        let path = components.path.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        return (path + addresses(in: components, parameter: "to")).filter { !$0.isEmpty }
            .map { TurnContext.inline($0, maxCharacters: 200) }
    }

    /// The addresses of every `parameter` (`to`, `cc`, `bcc`, in any case) of a mailto link, as given.
    static func addresses(in components: URLComponents, parameter: String) -> [String] {
        (components.queryItems ?? []).filter { $0.name.lowercased() == parameter }.compactMap(\.value)
            .flatMap { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
    }

    /// A mailto parameter name as header names are written ("subject",
    /// "In-Reply-To"): ASCII letters, digits and "-" (as decoded: "%62cc" is "bcc").
    private static func isParameterName(_ name: String) -> Bool {
        name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }

    /// Spaces, line breaks, control and invisible format characters.
    private static func isForbiddenScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || scalar.properties.generalCategory == .control
            || scalar.properties.generalCategory == .format
    }
}

/// Decoding of punycode labels (RFC 3492), the ASCII form of international
/// domain names ("bcher-kva" → "bücher" for "xn--bcher-kva"). Pure.
enum Punycode {
    private static let base = 36
    private static let tMin = 1
    private static let tMax = 26
    private static let skew = 38
    private static let damp = 700
    private static let initialBias = 72
    private static let initialN = 128

    /// The Unicode text of a label without its "xn--" prefix, or nil when it
    /// is not valid punycode.
    static func decode(_ label: String) -> String? {
        var output: [Unicode.Scalar] = []
        let scalars = Array(label.unicodeScalars)
        var position = 0
        if let delimiter = scalars.lastIndex(of: "-") {
            for scalar in scalars[..<delimiter] {
                guard scalar.isASCII else { return nil }
                output.append(scalar)
            }
            position = delimiter + 1
        }
        var n = initialN
        var i = 0
        var bias = initialBias
        while position < scalars.count {
            let oldI = i
            var weight = 1
            var k = base
            while true {
                guard position < scalars.count, let digit = digit(scalars[position]) else { return nil }
                position += 1
                let (product, overflow) = digit.multipliedReportingOverflow(by: weight)
                guard !overflow, i <= Int(Int32.max) - product else { return nil }
                i += product
                let threshold = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                if digit < threshold { break }
                let (nextWeight, weightOverflow) = weight.multipliedReportingOverflow(by: base - threshold)
                guard !weightOverflow, nextWeight <= Int(Int32.max) else { return nil }
                weight = nextWeight
                k += base
            }
            let count = output.count + 1
            bias = adapt(delta: i - oldI, count: count, isFirst: oldI == 0)
            n += i / count
            i %= count
            guard n <= 0x10FFFF, let scalar = Unicode.Scalar(n) else { return nil }
            output.insert(scalar, at: i)
            i += 1
        }
        return String(String.UnicodeScalarView(output))
    }

    private static func digit(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 0x30...0x39: Int(scalar.value) - 0x30 + 26
        case 0x41...0x5A: Int(scalar.value) - 0x41
        case 0x61...0x7A: Int(scalar.value) - 0x61
        default: nil
        }
    }

    private static func adapt(delta: Int, count: Int, isFirst: Bool) -> Int {
        var delta = isFirst ? delta / damp : delta / 2
        delta += delta / count
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }
}
