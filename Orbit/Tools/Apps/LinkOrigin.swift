import Foundation

/// The links the user typed or pasted in their message (pure). `open_url`
/// opens such a link without a card (`OpenURLTool.review(_:for:)`), and
/// opens it as the user wrote it, so the way the model wrote it carries
/// nothing.
///
/// A link counts as the user's only when it is the same link: the same
/// scheme (a bare "heise.de" fits an http and an https link, a bare
/// "lisa@example.com" a mailto link), host, port, path, query and fragment.
/// Only how it is written may differ: the case of scheme and host, a host in
/// punycode or not, a leading "www.", percent-encoding, a default port, an
/// empty path or a trailing slash. A link the model shortened, extended or
/// changed in any other way is not the user's. A link the user wrote without
/// a scheme opens with https (with http only into the local network),
/// whichever the model chose.
enum TypedLinks {
    /// Links beyond this many in one message are not looked at, also when
    /// they are glued together in one word.
    static let maxCandidates = 100

    /// A link in the user's text as written there, without the punctuation
    /// around it (a sentence's final period, brackets, quotes, Markdown).
    struct Candidate: Sendable, Hashable {
        var text: String
        var kind: LinkPolicy.Link.Kind
        /// Whether the user wrote the scheme ("https://", "mailto:").
        var hasScheme: Bool
    }

    /// The links in `text`, in order.
    static func candidates(in text: String) -> [Candidate] {
        candidates(inWords: text.split(whereSeparator: \.isWhitespace))
    }

    /// The link in `text` that `link` is (see the type's comment), as the
    /// user wrote it, with https when they wrote no scheme (http into the
    /// local network), or nil.
    static func userLink(matching link: LinkPolicy.Link, in text: String) -> String? {
        guard !text.isEmpty, let identity = Identity(link) else { return nil }
        for candidate in candidates(in: text, naming: names(of: link)) where candidate.kind == link.kind {
            let written: String
            if candidate.hasScheme {
                written = candidate.text
            } else if link.kind == .mail {
                written = "mailto:" + candidate.text
            } else {
                // Not the model's scheme: it could downgrade the user's "bank.de" to http. A router or a
                // service on the Mac rarely has a certificate.
                let isLocal = (try? LinkPolicy.check("https://" + candidate.text))?.isLocal == true
                written = (isLocal ? "http://" : "https://") + candidate.text
            }
            guard let typed = try? LinkPolicy.check(written), var typedIdentity = Identity(typed) else { continue }
            if !candidate.hasScheme {
                // The user wrote no scheme, so either of the model's fits.
                typedIdentity.scheme = identity.scheme
            }
            if typedIdentity == identity {
                return written
            }
        }
        return nil
    }

    // MARK: Finding links

    /// The links in the words of `text` that contain one of `names`. The text
    /// is searched for the names, so a long pasted text is not parsed word by
    /// word (`OpenURLTool.review` runs on the main actor).
    private static func candidates(in text: String, naming names: [String]) -> [Candidate] {
        var words: [Range<String.Index>] = []
        for name in names where !name.isEmpty {
            var rest = text.startIndex..<text.endIndex
            while words.count < maxCandidates, let found = text.range(of: name, options: nameSearch, range: rest) {
                var start = found.lowerBound
                while start > text.startIndex, !text[text.index(before: start)].isWhitespace {
                    start = text.index(before: start)
                }
                var end = found.upperBound
                while end < text.endIndex, !text[end].isWhitespace {
                    end = text.index(after: end)
                }
                if !words.contains(start..<end) { words.append(start..<end) }
                rest = end..<text.endIndex
            }
        }
        return candidates(inWords: words.sorted { $0.lowerBound < $1.lowerBound }.map { text[$0] })
    }

    /// The links in `words`, in order: the first `maxCandidates`. Each word
    /// is parsed once (a lazy map would parse it again on every access), and
    /// only as far as links are still looked at.
    private static func candidates(inWords words: [Substring]) -> [Candidate] {
        var found: [Candidate] = []
        for word in words where found.count < maxCandidates {
            found += candidates(inWord: word, limit: maxCandidates - found.count)
        }
        return found
    }

    /// The links in the first `limit` parts of one word: a link may follow
    /// other text without a space ("URL:https://…", "[Doku](https://…)"), and
    /// two may touch.
    private static func candidates(inWord word: Substring, limit: Int) -> [Candidate] {
        let scalars = Array(word.unicodeScalars)
        var starts = schemeStarts(in: scalars)
        if starts.first != 0 { starts.insert(0, at: 0) }
        return starts.indices.prefix(limit).compactMap { position in
            candidate(from: scalars[starts[position]..<(position + 1 < starts.count ? starts[position + 1] : scalars.count)])
        }
    }

    private static let nameSearch: String.CompareOptions = [.caseInsensitive, .widthInsensitive]

    /// What a message names when it holds `link`: its host (in punycode and
    /// decoded, also where Foundation does not decode it, without "www."),
    /// or a mail's first address ("mailto:" for a mail link without one).
    private static func names(of link: LinkPolicy.Link) -> [String] {
        guard let components = URLComponents(url: link.url, resolvingAgainstBaseURL: false) else { return [] }
        switch link.kind {
        case .web:
            let host = components.host ?? ""
            return Set([host, components.encodedHost ?? "", Identity.host(host)].filter { !$0.isEmpty }).map { name in
                name.lowercased().hasPrefix("www.") ? String(name.dropFirst(4)) : name
            }
        case .mail:
            let address = components.path.split(separator: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
            return [address.isEmpty ? "mailto:" : address]
        }
    }

    private static let schemes = ["https://", "http://", "mailto:"].map { Array($0.unicodeScalars) }
    /// Before a link: brackets, quotes, Markdown.
    private static let leading = Set("([{<\"'„“”‚‘’«»‹›*_`（「『【〈《".unicodeScalars)
    /// After a link: a sentence's punctuation, quotes, Markdown.
    private static let trailing = Set(".,;:!?…\"'“”‘’«»‹›*`。、，！？：；）」』】〉》".unicodeScalars)
    /// Closing brackets after a link belong to it only when it opens them too
    /// ("…/wiki/Python_(Programmiersprache)").
    private static let closers: [Unicode.Scalar: Unicode.Scalar] = [")": "(", "]": "[", "}": "{", ">": "<"]
    private static let brackets = Set(closers.keys).union(closers.values)

    /// Where "http://", "https://" or "mailto:" starts in `scalars` (in any case).
    private static func schemeStarts(in scalars: [Unicode.Scalar]) -> [Int] {
        scalars.indices.filter { index in
            schemes.contains { scheme in
                index + scheme.count <= scalars.count
                    && zip(scheme, scalars[index...]).allSatisfy { expected, scalar in asciiLowercase(scalar) == expected }
            }
        }
    }

    private static func asciiLowercase(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32) ?? scalar : scalar
    }

    private static func candidate(from piece: ArraySlice<Unicode.Scalar>) -> Candidate? {
        var scalars = piece
        while let first = scalars.first, leading.contains(first) {
            scalars.removeFirst()
        }
        // Counted once: a pasted text can end in a long run of closing brackets.
        var counts: [Unicode.Scalar: Int] = [:]
        for scalar in scalars where brackets.contains(scalar) {
            counts[scalar, default: 0] += 1
        }
        while let last = scalars.last {
            if trailing.contains(last) {
                scalars.removeLast()
            } else if let opener = closers[last], counts[opener, default: 0] < counts[last, default: 0] {
                counts[last, default: 0] -= 1
                scalars.removeLast()
            } else {
                break
            }
        }
        // Every link has one of these; most words have none.
        guard scalars.contains(where: { $0 == "." || $0 == ":" || $0 == "@" }) else { return nil }
        let text = String(String.UnicodeScalarView(scalars))
        if LinkPolicy.scheme(of: text) != nil {
            // Only links Orbit opens (http, https, mailto).
            return (try? LinkPolicy.check(text)).map { Candidate(text: text, kind: $0.kind, hasScheme: true) }
        }
        // Without a scheme: an e-mail address ("lisa@example.com"), or a host with what follows it
        // ("heise.de/news", "localhost:3000", "192.168.178.1").
        let atSign = text.firstIndex(of: "@")
        if let atSign, atSign < (text.firstIndex(of: "/") ?? text.endIndex) {
            let domain = text[text.index(after: atSign)...]
            guard atSign != text.startIndex, isDomain(domain), (try? LinkPolicy.check("mailto:" + text)) != nil else { return nil }
            return Candidate(text: text, kind: .mail, hasScheme: false)
        }
        guard let link = try? LinkPolicy.check("https://" + text),
              let host = URLComponents(url: link.url, resolvingAgainstBaseURL: false)?.host,
              host.lowercased() == "localhost" || host.hasPrefix("[") || isIPv4(host) || isDomain(host[...])
        else { return nil }
        return Candidate(text: text, kind: .web, hasScheme: false)
    }

    /// "example.com", "bücher.de", "例え.テスト": dotted, ending in a name of two or more letters.
    private static func isDomain(_ text: Substring) -> Bool {
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.dropLast().allSatisfy({ !$0.isEmpty }), let last = labels.last else { return false }
        return last.count >= 2 && (last.allSatisfy(\.isLetter) || last.lowercased().hasPrefix("xn--"))
    }

    /// "192.168.178.1": four decimal numbers.
    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    // MARK: Comparing links

    /// What two links share when they are the same link (see the type's comment).
    struct Identity: Hashable {
        var scheme: String
        /// Lowercase, international names decoded, without a leading "www.".
        var host: String
        /// nil for the scheme's default port.
        var port: Int?
        var path: String
        var query: String?
        var fragment: String?

        private static let defaultPorts = ["http": 80, "https": 443]

        init?(_ link: LinkPolicy.Link) {
            guard let components = URLComponents(url: link.url, resolvingAgainstBaseURL: false),
                  let scheme = components.scheme?.lowercased() else { return nil }
            self.scheme = scheme
            query = Self.normalized(components.percentEncodedQuery)
            fragment = Self.normalized(components.percentEncodedFragment)
            switch link.kind {
            case .web:
                host = Self.host(components.host ?? "")
                port = components.port == Self.defaultPorts[scheme] ? nil : components.port
                var path = Self.normalized(components.percentEncodedPath) ?? "/"
                if path.count > 1, path.hasSuffix("/") { path.removeLast() }
                self.path = path
            case .mail:
                host = ""
                port = nil
                path = Self.normalized(components.percentEncodedPath)?.lowercased() ?? ""
            }
        }

        static func host(_ host: String) -> String {
            var labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false).map { label -> String in
                guard label.hasPrefix("xn--"), let decoded = Punycode.decode(String(label.dropFirst(4))) else { return String(label) }
                return decoded.lowercased()
            }
            if labels.count > 2, labels.first == "www" { labels.removeFirst() }
            return labels.joined(separator: ".")
        }

        /// RFC 3986 6.2.2: percent-encodings in upper case, those of unreserved
        /// characters decoded, other characters as they are (beyond ASCII
        /// percent-encoded as UTF-8); nil when empty.
        static func normalized(_ text: String?) -> String? {
            guard let text, !text.isEmpty else { return nil }
            let bytes = Array(text.utf8)
            var result = ""
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "%"), index + 2 < bytes.count,
                   let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                    let value = high << 4 | low
                    result += isUnreserved(value) ? String(UnicodeScalar(value)) : encoded(value)
                    index += 3
                } else {
                    result += byte < 0x80 ? String(UnicodeScalar(byte)) : encoded(byte)
                    index += 1
                }
            }
            return result
        }

        private static func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
            case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
            case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
            default: nil
            }
        }

        private static func isUnreserved(_ byte: UInt8) -> Bool {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"),
                 UInt8(ascii: "~"):
                true
            default:
                false
            }
        }

        private static func encoded(_ byte: UInt8) -> String {
            let digits = Array("0123456789ABCDEF")
            return "%" + String(digits[Int(byte >> 4)]) + String(digits[Int(byte & 0x0F)])
        }
    }
}

/// Hosts in the local network (pure): the Mac itself, the router and other
/// devices at home or at work. `open_url` opens a link there only when the
/// user typed it (`LinkPolicy.checkNotTyped`).
///
/// Local: loopback, private, link-local, shared (carrier-grade NAT, VPNs),
/// multicast and reserved IP addresses (also as browsers read IPv4
/// addresses ("2130706433", "0x7f.1", "0177.0.0.1" and "127.1" are all
/// 127.0.0.1) and inside IPv6 ("::ffff:192.168.0.1")), names without a dot
/// ("router", "localhost"), private-use names (*.local, *.localhost,
/// *.home.arpa, *.internal, *.lan, …) and the names German providers' routers
/// answer to, with the devices behind them (fritz.box, nas.fritz.box,
/// speedport.ip, easy.box), with any number of trailing dots. A public name
/// can still point into the local network; such a link gets the card like
/// any other.
enum LocalNetwork {
    /// Names ending in one of these are not public (RFC 6761, 6762, 8375 and
    /// names commonly used inside networks that are no public domains).
    static let privateSuffixes = ["localhost", "local", "localdomain", "home.arpa", "internal", "intranet", "lan",
                                  "home", "corp", "private"]
    /// The addresses of common routers' settings pages; the router also
    /// answers for the devices in the network under its name ("nas.fritz.box").
    static let routerNames: Set<String> = ["fritz.box", "speedport.ip", "easy.box"]

    /// IPv4 networks (address, prefix length) that are not on the public internet.
    private static let localIPv4: [(network: UInt32, prefix: Int)] = [
        (0x0000_0000, 8),   // 0.0.0.0/8 "this network": 0.0.0.0 reaches the Mac itself
        (0x0A00_0000, 8),   // 10.0.0.0/8 private
        (0x6440_0000, 10),  // 100.64.0.0/10 shared (carrier-grade NAT, VPNs)
        (0x7F00_0000, 8),   // 127.0.0.0/8 loopback
        (0xA9FE_0000, 16),  // 169.254.0.0/16 link-local
        (0xAC10_0000, 12),  // 172.16.0.0/12 private
        (0xC000_0000, 24),  // 192.0.0.0/24 protocol assignments
        (0xC0A8_0000, 16),  // 192.168.0.0/16 private
        (0xC612_0000, 15),  // 198.18.0.0/15 benchmarking
        (0xE000_0000, 4),   // 224.0.0.0/4 multicast
        (0xF000_0000, 4),   // 240.0.0.0/4 reserved, broadcast
    ]

    /// Whether `host` (as URLComponents gives it: decoded, an IPv6 address in
    /// brackets) is in the local network. A host that browsers read as an
    /// IPv4 address but is none ("1.2.3.4.5") counts as local: it is no public site.
    static func contains(host: String) -> Bool {
        var host = host.lowercased()
        if host.hasPrefix("[") {
            return containsIPv6(String(host.dropFirst().prefix { $0 != "]" }))
        }
        if host.contains(":") {
            return containsIPv6(host)
        }
        // "fritz.box." and "fritz.box.." name the same host as "fritz.box" for a resolver that drops the dots.
        while host.hasSuffix(".") {
            host.removeLast()
        }
        if endsInNumber(host) {
            return ipv4Address(host).map(containsIPv4) ?? true
        }
        guard host.contains(".") else { return true }
        let isUnder = { (name: String) in host == name || host.hasSuffix("." + name) }
        return routerNames.contains(where: isUnder) || privateSuffixes.contains(where: isUnder)
    }

    static func containsIPv4(_ address: UInt32) -> Bool {
        localIPv4.contains { address >> (32 - $0.prefix) == $0.network >> (32 - $0.prefix) }
    }

    /// Loopback (::1), unspecified (::), link-local (fe80::/10), site-local
    /// (fec0::/10), unique local (fc00::/7), multicast (ff00::/8) and local-use
    /// translation (64:ff9b:1::/48) addresses, and IPv4 addresses inside IPv6
    /// by their IPv4 address. A zone ("fe80::1%en0") names an interface of the
    /// Mac: local.
    static func containsIPv6(_ text: String) -> Bool {
        guard !text.contains("%") else { return true }
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return true }
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        let embedded = bytes[12...].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return containsIPv4(embedded)  // ::ffff:a.b.c.d
        }
        if bytes[0..<8].allSatisfy({ $0 == 0 }), bytes[8..<12] == [0xFF, 0xFF, 0x00, 0x00] {
            return containsIPv4(embedded)  // ::ffff:0:a.b.c.d (IPv4-translated)
        }
        if bytes[0..<12].allSatisfy({ $0 == 0 }) {
            return true  // ::, ::1 and the deprecated ::a.b.c.d
        }
        if bytes[0..<4] == [0x00, 0x64, 0xFF, 0x9B], bytes[4..<12].allSatisfy({ $0 == 0 }) {
            return containsIPv4(embedded)  // 64:ff9b::a.b.c.d (NAT64)
        }
        if bytes[0..<6] == [0x00, 0x64, 0xFF, 0x9B, 0x00, 0x01] {
            return true  // 64:ff9b:1::/48, translation inside a network
        }
        return bytes[0] == 0xFF || bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0x80 == 0x80)
    }

    // MARK: IPv4 as browsers read it (the URL Standard's host parser)

    /// Whether the host's last label is a number: browsers then read the
    /// whole host as an IPv4 address.
    private static func endsInNumber(_ host: String) -> Bool {
        var parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.last?.isEmpty == true {
            guard parts.count > 1 else { return false }
            parts.removeLast()
        }
        guard let last = parts.last, !last.isEmpty else { return false }
        return last.allSatisfy { $0.isASCII && $0.isNumber } || ipv4Number(last) != nil
    }

    /// The address, or nil when the host is no valid IPv4 address.
    private static func ipv4Address(_ host: String) -> UInt32? {
        var parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 1, parts.last?.isEmpty == true { parts.removeLast() }
        guard parts.count <= 4 else { return nil }
        var numbers: [UInt64] = []
        for part in parts {
            guard let number = ipv4Number(part) else { return nil }
            numbers.append(number)
        }
        guard let last = numbers.last, !numbers.dropLast().contains(where: { $0 > 255 }),
              last < UInt64(1) << (8 * (5 - numbers.count)) else { return nil }
        var address = last
        for (index, number) in numbers.dropLast().enumerated() {
            address += number << (8 * (3 - index))
        }
        return UInt32(address)
    }

    /// One part: decimal, hexadecimal ("0x7f") or octal ("0177").
    private static func ipv4Number(_ part: Substring) -> UInt64? {
        guard !part.isEmpty else { return nil }
        var digits = part
        var radix = 10
        if digits.count >= 2, digits.hasPrefix("0x") || digits.hasPrefix("0X") {
            digits = digits.dropFirst(2)
            radix = 16
        } else if digits.count >= 2, digits.hasPrefix("0") {
            digits = digits.dropFirst()
            radix = 8
        }
        guard !digits.isEmpty else { return 0 }
        guard digits.allSatisfy({ $0.isASCII && ($0.hexDigitValue ?? 99) < radix }) else { return nil }
        return UInt64(digits, radix: radix)
    }
}
