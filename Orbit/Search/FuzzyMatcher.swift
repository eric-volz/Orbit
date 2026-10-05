import Foundation

/// Matches what the user typed against names (apps, files, contacts). Pure.
///
/// Both sides are folded (case, diacritics and width: "ß" = "ss", "Ü" = "u")
/// and split into words at spaces and punctuation, at lower→upper case changes
/// ("FaceTime") and between letters and digits ("Office365"). Separators are
/// ignored when comparing, so "face time" is "FaceTime". Tiers, best first:
/// 1. exact: the whole name ("safari" → Safari)
/// 2. prefix: the start of the name ("saf" → Safari, "sys" → Systemeinstellungen)
/// 3. word prefix: the text splits into prefixes of words in their order: a
///    later word ("code" → Visual Studio Code), initials ("vsc"), or both
///    ("vscode", "visual co"); several typed words also match in any order
/// 4. substring: anywhere inside, from 2 characters ("code" → Xcode)
/// 5. subsequence: the characters in order, from 3 characters ("xcd" → Xcode)
///
/// Within a tier closer matches score higher: more of the name covered, earlier
/// and fewer skipped words, tighter subsequences. Equal matches are left to the
/// caller, which orders them by name for a stable result (`SearchOrder`).
enum FuzzyMatcher {
    enum Tier: Int, Sendable, Hashable, Comparable, CaseIterable {
        case subsequence = 1, substring, wordPrefix, prefix, exact

        /// Ranking weight: one apart, exact two above prefix, so a boost below
        /// 1 lifts a match past at most one tier and never past an exact match.
        var weight: Int {
            self == .exact ? 6 : rawValue
        }

        static func < (lhs: Tier, rhs: Tier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct Match: Sendable, Hashable, Comparable {
        var tier: Tier
        /// Closeness within the tier, 0 ..< 1.
        var score: Double

        /// Tier weight plus score, for ranking.
        var rank: Double {
            Double(tier.weight) + score
        }

        static func < (lhs: Match, rhs: Match) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    /// A name prepared for matching: its folded letters and digits without
    /// separators, and where each word starts. Prepare names once and reuse them.
    struct Name: Sendable, Hashable {
        let scalars: [Unicode.Scalar]
        /// Indices into `scalars` where a word starts (ascending, the first is 0).
        let wordStarts: [Int]

        init(_ text: String) {
            (scalars, wordStarts) = FuzzyMatcher.prepare(text)
        }

        var isEmpty: Bool { scalars.isEmpty }

        /// The end (exclusive) of word `index`.
        func wordEnd(_ index: Int) -> Int {
            index + 1 < wordStarts.count ? wordStarts[index + 1] : scalars.count
        }
    }

    /// What the user typed, prepared for matching many names.
    struct Query: Sendable, Hashable {
        let name: Name
        /// The typed words (split at spaces and punctuation), folded.
        let terms: [[Unicode.Scalar]]

        init(_ text: String) {
            name = Name(text)
            terms = text.split { !($0.isLetter || $0.isNumber) }
                .map { Name(String($0)).scalars }
                .filter { !$0.isEmpty }
        }

        var isEmpty: Bool { name.isEmpty }

        /// Letters and digits typed.
        var length: Int { name.scalars.count }
    }

    /// Substring matches need this many characters, subsequences one more.
    static let minimumSubstringLength = 2
    static let minimumSubsequenceLength = 3

    static func match(_ query: Query, in name: Name) -> Match? {
        let typed = query.name.scalars
        let text = name.scalars
        // Every tier needs the first typed character somewhere: most names fail here.
        guard !typed.isEmpty, typed.count <= text.count, text.contains(typed[0]) else { return nil }
        let coverage = Double(typed.count) / Double(text.count)
        if typed == text {
            return Match(tier: .exact, score: 0.5)
        }
        if text.starts(with: typed) {
            return Match(tier: .prefix, score: 0.99 * coverage)
        }
        if let cost = wordPrefixCost(typed, in: name) {
            return Match(tier: .wordPrefix, score: 0.6 / Double(1 + cost) + 0.39 * coverage)
        }
        if query.terms.count > 1, termsMatchWordsInAnyOrder(query.terms, in: name) {
            return Match(tier: .wordPrefix, score: 0.1 * coverage)
        }
        if typed.count >= minimumSubstringLength, let position = firstPosition(of: typed, in: text) {
            return Match(tier: .substring, score: 0.6 / Double(1 + position) + 0.39 * coverage)
        }
        if typed.count >= minimumSubsequenceLength, let span = shortestSubsequenceSpan(typed, in: text) {
            return Match(tier: .subsequence, score: 0.99 * Double(typed.count) / Double(span))
        }
        return nil
    }

    /// The best match of `query` against any of `names`.
    static func bestMatch(_ query: Query, in names: [Name]) -> Match? {
        var best: Match?
        for name in names {
            if let match = match(query, in: name), best.map({ match > $0 }) ?? true {
                best = match
            }
        }
        return best
    }

    /// Convenience for single comparisons (tests, a handful of names).
    static func match(_ text: String, in name: String) -> Match? {
        match(Query(text), in: Name(name))
    }

    // MARK: Preparation

    private enum CharacterKind {
        case separator, lower, upper, digit
    }

    private static func prepare(_ text: String) -> (scalars: [Unicode.Scalar], wordStarts: [Int]) {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(text.utf8.count)
        var wordStarts: [Int] = []
        var previous = CharacterKind.separator
        for character in text {
            let kind: CharacterKind
            if character.isNumber {
                kind = .digit
            } else if character.isLetter {
                kind = character.isUppercase ? .upper : .lower
            } else {
                previous = .separator
                continue
            }
            let folded = fold(character)
            guard !folded.isEmpty else { continue }
            let startsWord = previous == .separator
                || (previous == .lower && kind == .upper)
                || ((previous == .digit) != (kind == .digit))
            if startsWord {
                wordStarts.append(scalars.count)
            }
            scalars.append(contentsOf: folded)
            previous = kind
        }
        return (scalars, wordStarts)
    }

    /// Lowercased without diacritics; ASCII takes a fast path.
    private static func fold(_ character: Character) -> [Unicode.Scalar] {
        if let ascii = character.asciiValue {
            let lowered = (65...90).contains(ascii) ? ascii + 32 : ascii
            return [Unicode.Scalar(lowered)]
        }
        return String(character)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars
            .filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }
    }

    // MARK: Tiers

    /// How far `typed` is from splitting into prefixes of words in their order:
    /// the index of the first word used plus the words skipped in between
    /// (0 = initials from the first word on), or nil when it does not split.
    private static func wordPrefixCost(_ typed: [Unicode.Scalar], in name: Name) -> Int? {
        let text = name.scalars
        let wordCount = name.wordStarts.count
        guard wordCount > 0, name.wordStarts.contains(where: { text[$0] == typed[0] }) else { return nil }
        // memo[position * (wordCount + 1) + word]: -2 unknown, -1 impossible, else the cost.
        var memo = [Int](repeating: -2, count: (typed.count + 1) * (wordCount + 1))

        func cost(from position: Int, word firstWord: Int) -> Int? {
            if position == typed.count { return 0 }
            let key = position * (wordCount + 1) + firstWord
            if memo[key] != -2 { return memo[key] == -1 ? nil : memo[key] }
            var best: Int?
            var word = firstWord
            while word < wordCount {
                let skipped = word - firstWord
                if let best, best <= skipped { break }
                let start = name.wordStarts[word]
                let end = name.wordEnd(word)
                var common = 0
                while position + common < typed.count, start + common < end, typed[position + common] == text[start + common] {
                    common += 1
                }
                var length = common
                while length > 0 {
                    if let rest = cost(from: position + length, word: word + 1), best.map({ skipped + rest < $0 }) ?? true {
                        best = skipped + rest
                    }
                    length -= 1
                }
                word += 1
            }
            memo[key] = best ?? -1
            return best
        }

        return cost(from: 0, word: 0)
    }

    /// Every typed word is the prefix of a different word of the name.
    private static func termsMatchWordsInAnyOrder(_ terms: [[Unicode.Scalar]], in name: Name) -> Bool {
        var used = [Bool](repeating: false, count: name.wordStarts.count)
        // Longest first, so a short term does not take the word a longer one needs.
        for term in terms.sorted(by: { $0.count > $1.count }) {
            var found = false
            for word in name.wordStarts.indices where !used[word] {
                let start = name.wordStarts[word]
                let end = name.wordEnd(word)
                if end - start >= term.count, name.scalars[start..<(start + term.count)].elementsEqual(term) {
                    used[word] = true
                    found = true
                    break
                }
            }
            if !found { return false }
        }
        return true
    }

    private static func firstPosition(of typed: [Unicode.Scalar], in text: [Unicode.Scalar]) -> Int? {
        guard typed.count <= text.count else { return nil }
        for start in 0...(text.count - typed.count) where text[start] == typed[0] {
            var index = 1
            while index < typed.count, text[start + index] == typed[index] { index += 1 }
            if index == typed.count { return start }
        }
        return nil
    }

    /// The length of the shortest stretch of `text` that contains `typed` in order.
    private static func shortestSubsequenceSpan(_ typed: [Unicode.Scalar], in text: [Unicode.Scalar]) -> Int? {
        var best: Int?
        for start in text.indices where text[start] == typed[0] {
            var index = 1
            var position = start + 1
            while index < typed.count, position < text.count {
                if text[position] == typed[index] { index += 1 }
                position += 1
            }
            guard index == typed.count else { break }  // no later start can match either
            let span = position - start
            if best.map({ span < $0 }) ?? true { best = span }
        }
        return best
    }
}

/// The order of ranked results: higher rank first, then by name as Finder
/// sorts it, then by identifier, stable for equal matches.
enum SearchOrder {
    static func precedes(rank lhsRank: Double, name lhsName: String, id lhsID: String,
                         rank rhsRank: Double, name rhsName: String, id rhsID: String) -> Bool {
        if lhsRank != rhsRank { return lhsRank > rhsRank }
        switch lhsName.localizedStandardCompare(rhsName) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhsID < rhsID
        }
    }
}
