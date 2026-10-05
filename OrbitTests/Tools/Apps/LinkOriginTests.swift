import Foundation
import Testing
@testable import Orbit

/// SEC-1: which links count as typed by the user: found in their message as
/// they wrote it, and the same link only when nothing but its spelling differs.
@Suite("Links the user typed")
struct TypedLinksTests {
    private func found(_ text: String) -> [String] {
        TypedLinks.candidates(in: text).map(\.text)
    }

    /// The link the model passes, matched against what the user wrote: what opens, or nil.
    private func typed(_ modelLink: String, in text: String) throws -> String? {
        TypedLinks.userLink(matching: try LinkPolicy.check(modelLink), in: text)
    }

    // MARK: Finding links in a message

    @Test func findsLinksWithoutThePunctuationAroundThem() {
        #expect(found("Öffne https://example.com/page.") == ["https://example.com/page"])
        #expect(found("Siehe (https://example.com/a), dann „https://example.org/b“!") == ["https://example.com/a", "https://example.org/b"])
        #expect(found("<https://example.com/x>; 'https://example.com/y'?") == ["https://example.com/x", "https://example.com/y"])
        #expect(found("[Die Doku](https://example.com/doc) und **https://example.com/fett**") == ["https://example.com/doc", "https://example.com/fett"])
        #expect(found("URL:https://example.com/a,https://example.com/b") == ["https://example.com/a", "https://example.com/b"],
                "links that touch other text or each other")
        #expect(found("Öffne «https://example.com/z»…") == ["https://example.com/z"])
    }

    @Test func keepsBracketsTheLinkOpensItself() {
        #expect(found("https://de.wikipedia.org/wiki/Python_(Programmiersprache)") == ["https://de.wikipedia.org/wiki/Python_(Programmiersprache)"])
        #expect(found("(siehe https://de.wikipedia.org/wiki/Python_(Programmiersprache)).")
            == ["https://de.wikipedia.org/wiki/Python_(Programmiersprache)"])
    }

    @Test func findsLinksWrittenWithoutAScheme() {
        let candidates = TypedLinks.candidates(in: "Öffne heise.de/news, www.Example.COM und bücher.de. Schreib lisa@example.com.")
        #expect(candidates == [
            TypedLinks.Candidate(text: "heise.de/news", kind: .web, hasScheme: false),
            TypedLinks.Candidate(text: "www.Example.COM", kind: .web, hasScheme: false),
            TypedLinks.Candidate(text: "bücher.de", kind: .web, hasScheme: false),
            TypedLinks.Candidate(text: "lisa@example.com", kind: .mail, hasScheme: false),
        ])
        #expect(found("Router: 192.168.178.1, Dienst: localhost:3000/api") == ["192.168.178.1", "localhost:3000/api"])
        #expect(found("mastodon.social/@orbit") == ["mastodon.social/@orbit"])
    }

    @Test func wordsThatAreNoLinksAreNotFound() {
        #expect(found("z.B. um 16:30 Uhr, ca. 1.5 km, v2.0.1, usw. \u{2013} Rechnung@ oder @orbit, a@b") == [])
        #expect(found("file:///Users/orbit-test/geheim.txt shortcuts://run-shortcut?name=x javascript:alert(1)") == [],
                "only links Orbit opens")
        #expect(found("https://google.com@evil.example/login") == [], "a link Orbit refuses is no candidate")
    }

    /// A long pasted text (`review` runs on the main actor): the search stops after `maxCandidates`
    /// links, and only words that name the link's host are parsed.
    @Test(.timeLimit(.minutes(1))) func longMessages() throws {
        let links = String(repeating: "Wort https://example.com/a?b=1, ", count: 5_000)
        #expect(TypedLinks.candidates(in: links).count == TypedLinks.maxCandidates)
        let log = String(repeating: "12:00:01 GET /api/v1.2/items 10.0.0.1 datei.txt ok; ", count: 20_000) + "https://example.com/neu"
        #expect(try typed("https://example.com/neu", in: log) == "https://example.com/neu")
        #expect(try typed("https://other.example/", in: log) == nil)
    }

    /// SEC1-V1: a crafted paste (a link followed by a long run of closing brackets) is trimmed in one pass.
    /// Counting the brackets again for each one froze the main actor for minutes.
    @Test(.timeLimit(.minutes(1))) func longRunsOfClosingBrackets() throws {
        let text = "Siehe https://example.com/(a" + String(repeating: ")", count: 100_000)
        #expect(try typed("https://example.com/(a)", in: text) == "https://example.com/(a)", "a bracket the link opens stays")
    }

    /// Links glued together in one word count towards the limit too: only the first `maxCandidates` are looked at,
    /// and the word is parsed once; thousands of them in a pasted text must not stall the main actor.
    @Test(.timeLimit(.minutes(1))) func gluedLinksCountTowardsTheLimit() throws {
        let glued = (1...5_000).map { "https://example.com/\($0)" }.joined()
        #expect(found(glued).count == TypedLinks.maxCandidates)
        #expect(try typed("https://example.com/100", in: glued) == "https://example.com/100")
        #expect(try typed("https://example.com/101", in: glued) == nil, "beyond the limit: the card")
        let twoWords = (1...60).map { "https://example.com/\($0)" }.joined() + " " + (61...120).map { "https://example.com/\($0)" }.joined()
        #expect(try typed("https://example.com/100", in: twoWords) == "https://example.com/100")
        #expect(try typed("https://example.com/101", in: twoWords) == nil, "the limit holds for the whole message")
    }

    // MARK: The same link

    @Test func onlyTheSpellingMayDiffer() throws {
        let message = "Öffne bitte https://www.Example.com/Pfad/K%c3%b6ln?q=1#oben."
        for variant in ["https://www.example.com/Pfad/K%C3%B6ln?q=1#oben", "HTTPS://EXAMPLE.COM:443/Pfad/Köln?q=1#oben",
                        "https://example.com/Pfad/K%C3%B6ln/?q=1#oben", "https://www.example.com/%50fad/K%C3%B6ln?q=1#oben"] {
            #expect(try typed(variant, in: message) == "https://www.Example.com/Pfad/K%c3%b6ln?q=1#oben", "\(variant)")
        }
        #expect(try typed("https://xn--bcher-kva.de/neu", in: "Öffne https://bücher.de/neu") == "https://bücher.de/neu")
        #expect(try typed("https://bücher.de/neu", in: "Öffne https://XN--BCHER-KVA.de/neu") == "https://XN--BCHER-KVA.de/neu")
        #expect(try typed("https://example.com/", in: "https://example.com") == "https://example.com")
    }

    /// A link the model shortened, extended or changed carries what the model chose: it is not the user's.
    @Test func aChangedLinkIsNotTheUsers() throws {
        let message = "Öffne https://example.com/search?q=wetter#heute"
        for changed in ["https://example.com/search?q=wetter&d=Zahnarzt%2008:30#heute", "https://example.com/search?q=Wetter#heute",
                        "https://example.com/search?q=wetter", "https://example.com/search#heute", "https://example.com/",
                        "https://example.com/search/more?q=wetter#heute", "http://example.com/search?q=wetter#heute",
                        "https://example.com:8443/search?q=wetter#heute", "https://evil.example/search?q=wetter#heute",
                        "https://example.com.evil.example/search?q=wetter#heute", "https://example.com/search?q=wetter#morgen",
                        "https://example.com/Search?q=wetter#heute"] {
            #expect(try typed(changed, in: message) == nil, "\(changed)")
        }
    }

    /// SEC1-V4: a link the user wrote without a scheme fits the model's http and https link, and opens with
    /// https whichever the model chose (http would send it unencrypted), with http only into the local network.
    @Test func aLinkWithoutSchemeFitsHttpAndHttps() throws {
        #expect(try typed("https://heise.de/news", in: "Öffne heise.de/news") == "https://heise.de/news")
        #expect(try typed("http://heise.de/news/", in: "Öffne heise.de/news") == "https://heise.de/news", "not the model's http")
        #expect(try typed("https://www.apple.com", in: "Öffne apple.com.") == "https://apple.com", "opens as the user wrote it")
        #expect(try typed("http://localhost:3000/api", in: "Teste localhost:3000/api") == "http://localhost:3000/api")
        #expect(try typed("https://localhost:3000/api", in: "Teste localhost:3000/api") == "http://localhost:3000/api")
        #expect(try typed("https://fritz.box/", in: "Öffne fritz.box") == "http://fritz.box")
        #expect(try typed("http://192.168.178.1/", in: "Was ist 192.168.178.1?") == "http://192.168.178.1")
        #expect(try typed("https://heise.de/news?x=1", in: "Öffne heise.de/news") == nil)
        #expect(try typed("http://heise.de:443/news", in: "Öffne heise.de/news") == nil, "another port")
        #expect(try typed("https://heise.de/news", in: "Öffne http://heise.de/news") == nil, "the scheme the user wrote")
        #expect(try typed("mailto:heise.de", in: "Öffne heise.de") == nil)
        #expect(try typed("https://example.com", in: "Schreib lisa@example.com") == nil)
    }

    @Test func mailLinks() throws {
        #expect(try typed("mailto:Lisa@Example.com", in: "Schreib lisa@example.com eine Mail") == "mailto:lisa@example.com")
        #expect(try typed("mailto:lisa@example.com?subject=Hallo", in: "Schreib lisa@example.com") == nil,
                "a subject or text the model chose")
        let pasted = "Öffne mailto:lisa@example.com?bcc=chef@example.com&subject=Bericht"
        #expect(try typed("mailto:lisa@example.com?bcc=chef@example.com&subject=Bericht", in: pasted)
            == "mailto:lisa@example.com?bcc=chef@example.com&subject=Bericht")
        #expect(try typed("mailto:lisa@example.com?bcc=evil@example.com&subject=Bericht", in: pasted) == nil)
    }

    @Test func nothingTypedMatchesNothing() throws {
        #expect(try typed("https://example.com", in: "") == nil)
        #expect(try typed("https://example.com", in: "Öffne die Seite aus der Mail") == nil)
    }
}

/// SEC-1: hosts in the local network (the Mac itself, the router, devices at home), also in the
/// spellings browsers accept.
@Suite("Local network hosts")
struct LocalNetworkTests {
    private func isLocal(_ url: String) throws -> Bool {
        try LinkPolicy.check(url).isLocal
    }

    @Test(arguments: [
        "http://localhost:8080/admin?x=1", "http://LOCALHOST/", "http://localhost./", "http://dev.localhost/",
        "http://127.0.0.1/", "http://127.255.0.9/", "http://0.0.0.0:8080/", "http://0/",
        "http://2130706433/", "http://0x7f.1/", "http://0177.0.0.1/", "http://127.1/", "http://0x7f000001/", "http://127.0.0.%31/",
        "http://10.0.0.1/", "http://172.16.5.4/", "http://172.31.255.255/", "http://192.168.178.1/cgi-bin/x", "http://100.64.1.2/",
        "http://169.254.169.254/latest/meta-data/", "http://224.0.0.1/", "http://255.255.255.255/", "http://198.18.0.1/",
        "http://[::1]:631/", "http://[0:0:0:0:0:0:0:1]/", "http://[::]/", "http://[fe80::1%25en0]/", "http://[fe80::1]/",
        "http://[fd00::1]/", "http://[fc12::1]/", "http://[fec0::1]/", "http://[ff02::1]/", "http://[::ffff:127.0.0.1]/",
        "http://[::ffff:192.168.1.1]/", "http://[64:ff9b::7f00:1]/",
        "http://router/", "http://nas.local/", "http://drucker.home.arpa/", "http://wiki.internal/", "http://server.lan/",
        "http://box.home/", "http://intranet.corp/", "http://fritz.box/", "http://FRITZ.BOX/", "http://speedport.ip/",
        "http://easy.box/", "http://1.2.3.4.5/", "http://example.0x1/",
        // SEC1-V2: the devices behind a router's name, and any number of trailing dots.
        "http://nas.fritz.box/admin", "http://www.fritz.box/", "http://drucker.speedport.ip/", "http://fritz.box../",
        "http://localhost../", "http://127.0.0.1../", "http://192.168.178.1.../", "http://foo.local../", "http://router../",
        "http://[::ffff:0:7f00:1]/", "http://[::ffff:0:192.168.0.1]/", "http://[64:ff9b:1::1]/",
    ])
    func localHosts(url: String) throws {
        #expect(try isLocal(url))
    }

    @Test(arguments: [
        "https://example.com/", "https://www.tagesschau.de/", "http://8.8.8.8/", "http://1.1.1.1/", "http://172.32.0.1/",
        "http://192.169.0.1/", "http://100.128.0.1/", "http://11.0.0.1/", "http://[2001:db8::1]/", "http://[2a00:1450::1]/",
        "http://[::ffff:8.8.8.8]/", "https://bücher.de/", "https://localhost.example.com/", "https://my.fritz.box.example.com/",
        "https://local.example/", "https://example.cafe/", "https://127.0.0.1.nip.io/", "https://notfritz.box/",
        "https://example.com../", "http://8.8.8.8../", "http://[::ffff:0:8.8.8.8]/", "http://[64:ff9b::8.8.8.8]/",
    ])
    func publicHosts(url: String) throws {
        #expect(try !isLocal(url))
    }

    @Test func mailLinksAreNoHosts() throws {
        #expect(try !isLocal("mailto:admin@localhost"))
    }
}
