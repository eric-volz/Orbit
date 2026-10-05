import Foundation

/// Builds the NSPredicate for a `SpotlightQuery`. Pure; every value goes in as
/// an argument (`NSPredicate(format:argumentArray:)`), never into the format.
///
/// Operators, verified with `mdfind -onlyin` and NSMetadataQuery on fixtures
/// (macOS 27, 2026-09):
/// - `%K BEGINSWITH[cdw] %@` becomes Spotlight's `attr == "term*"cdw`: a word
///   prefix match, case- and diacritic-insensitive (and ß = ss), where words
///   also split at "-", "_", ".", digits and lower→upper case changes. For
///   kMDItemDisplayName/kMDItemFSName: "invoice" and "summary" match
///   "invoiceSummary.md", "telekom", "2026" and "2026-08" match
///   "Rechnung-Telekom-2026-08.pdf", "uber" matches "Café Übersicht.txt"; "art"
///   does not match "StartParty.txt" and "invoice" not "noninvoice.txt". For
///   kMDItemTextContent the same (content is always matched by words).
/// - NSMetadataQuery escapes the value: `*`, `?`, `"` and `\` in a term match
///   literally, so a term cannot widen or break out of the query.
/// - Without `w`, names match only as a whole ("invoice*" = name starts with
///   "invoice"). `CONTAINS[cd]` matches substrings ("noninvoice") and is slow on
///   content (~1 s against ~5 ms). A term with a space matches a phrase in names
///   but nothing in content, so terms are single words.
/// - `%K == %@` on kMDItemContentTypeTree matches when any element equals the
///   type; `NOT (…)` excludes correctly for that multi-valued attribute.
enum SpotlightPredicate {
    static let displayName = NSMetadataItemDisplayNameKey
    static let fileSystemName = NSMetadataItemFSNameKey
    static let textContent = "kMDItemTextContent"
    static let contentTypeTree = NSMetadataItemContentTypeTreeKey
    static let modified = NSMetadataItemContentModificationDateKey
    static let lastUsed = NSMetadataItemLastUsedDateKey

    static func build(_ query: SpotlightQuery) -> NSPredicate {
        var conditions: [NSPredicate] = query.terms.map { term in
            either(alternatives(for: term, in: query))
        }
        if !query.contentTypes.isEmpty {
            conditions.append(either(query.contentTypes.map { contentType($0) }))
        }
        if !query.excludedContentTypes.isEmpty {
            conditions.append(NSCompoundPredicate(notPredicateWithSubpredicate:
                either(query.excludedContentTypes.map { contentType($0) })))
        }
        conditions += dateConditions(modified, query.modified)
        conditions += dateConditions(lastUsed, query.lastUsed)
        if conditions.isEmpty {
            // Everything in the scopes.
            return contentType("public.item")
        }
        return conditions.count == 1 ? conditions[0] : NSCompoundPredicate(andPredicateWithSubpredicates: conditions)
    }

    private static func alternatives(for term: String, in query: SpotlightQuery) -> [NSPredicate] {
        var attributes: [String] = []
        if query.nameFields.contains(.displayName) { attributes.append(displayName) }
        if query.nameFields.contains(.fileSystemName) { attributes.append(fileSystemName) }
        if attributes.isEmpty { attributes.append(fileSystemName) }
        if query.termMatch == .namesOrContent { attributes.append(textContent) }
        return attributes.map { wordPrefix(term, in: $0) }
    }

    private static func wordPrefix(_ term: String, in attribute: String) -> NSPredicate {
        NSPredicate(format: "%K BEGINSWITH[cdw] %@", argumentArray: [attribute, term])
    }

    private static func contentType(_ identifier: String) -> NSPredicate {
        NSPredicate(format: "%K == %@", argumentArray: [contentTypeTree, identifier])
    }

    private static func dateConditions(_ attribute: String, _ bounds: SpotlightQuery.DateBounds) -> [NSPredicate] {
        var conditions: [NSPredicate] = []
        if let from = bounds.from {
            conditions.append(NSPredicate(format: "%K >= %@", argumentArray: [attribute, from as NSDate]))
        }
        if let through = bounds.through {
            conditions.append(NSPredicate(format: "%K <= %@", argumentArray: [attribute, through as NSDate]))
        }
        return conditions
    }

    private static func either(_ predicates: [NSPredicate]) -> NSPredicate {
        predicates.count == 1 ? predicates[0] : NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
    }

    /// Sort descriptors for the query's order.
    static func sortDescriptors(for order: SpotlightQuery.SortOrder) -> [NSSortDescriptor] {
        switch order {
        case .modifiedNewestFirst: [NSSortDescriptor(key: modified, ascending: false)]
        case .lastUsedNewestFirst: [NSSortDescriptor(key: lastUsed, ascending: false)]
        }
    }
}
