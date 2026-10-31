import Foundation

/// Plain-English searches ("pdfs from last week bigger than 10mb") become index filters. Explicit syntax
/// (`ext:`, `size:`, …) always wins; plain name searches ("invoice") are left alone.
package nonisolated enum NaturalQuery {
    package static func interpret(_ text: String) -> (query: IndexQuery, filter: SearchFilter)? {
        let syntax = IndexQuery.parse(text)
        guard syntax.extensions.isEmpty, syntax.kind == nil, syntax.minSize == nil, syntax.maxSize == nil,
              syntax.modifiedAfter == nil, syntax.modifiedBefore == nil, syntax.scopePath == nil,
              syntax.scopeNames.isEmpty, syntax.pathTerms.isEmpty, syntax.excludedTerms.isEmpty,
              syntax.regex == nil, !syntax.invalidRegex, !syntax.caseSensitive else { return nil }
        let filter = QueryInterpreter.parse(text).filter
        guard !filter.kinds.isEmpty || !filter.extensions.isEmpty || filter.minSize != nil || filter.maxSize != nil
                || filter.modifiedAfter != nil || filter.modifiedBefore != nil else { return nil }

        var query = IndexQuery()
        query.terms = (filter.nameContains + filter.keywords).map { Array($0.lowercased().utf8) }
        var extensions = Set(filter.extensions.map { $0.lowercased() })
        for kind in filter.kinds {
            switch kind {
            case .folder: query.kind = .folder
            case .application: query.kind = .app
            case .pdf: extensions.insert("pdf")
            case .book: extensions.formUnion(IndexSearch.extensions(for: .book))
            case .comic: extensions.formUnion(IndexSearch.extensions(for: .comic))
            case .image: extensions.formUnion(IndexSearch.extensions(for: .image))
            case .movie: extensions.formUnion(IndexSearch.extensions(for: .video))
            case .audio: extensions.formUnion(IndexSearch.extensions(for: .audio))
            case .archive: extensions.formUnion(IndexSearch.extensions(for: .archive))
            case .code: extensions.formUnion(IndexSearch.extensions(for: .code))
            case .document: extensions.formUnion(IndexSearch.extensions(for: .document))
            case .text: extensions.formUnion(["txt", "md", "markdown", "rtf", "log"])
            case .spreadsheet: extensions.formUnion(["xls", "xlsx", "numbers", "csv", "ods", "tsv"])
            case .presentation: extensions.formUnion(["key", "ppt", "pptx", "odp"])
            case .diskImage: extensions.formUnion(["dmg", "iso", "img", "sparseimage"])
            }
        }
        // A folder kind can't be combined with file extensions; extensions mean files.
        if !extensions.isEmpty, query.kind == .folder { query.kind = nil }
        query.extensions = extensions
        query.minSize = filter.minSize
        query.maxSize = filter.maxSize
        query.modifiedAfter = filter.modifiedAfter.map(indexStamp)
        query.modifiedBefore = filter.modifiedBefore.map(indexStamp)
        let mentioned = (filter.nameContains + filter.keywords).map { $0.lowercased() }
        query.includeHidden = mentioned.contains { $0.hasPrefix(".") }
        return (query, filter)
    }
}

extension IndexSearch {
    /// Where a search looks: a store, the folder in it to search (nil: all of it), and how many levels below the
    /// searched folder the store's root sits. Scores count depth, so the offset lines results from different stores up.
    package nonisolated struct Source: Sendable {
        package let store: IndexStore
        package let scopePath: String?
        package let depth: Int
        /// Keeps this source's results per query (the index's part of a folder search doesn't change while the folder
        /// is read, so it isn't searched again on every refresh).
        package var cache: ResultCache? = nil
    }

    /// Results by query, for a source that doesn't change while it's searched repeatedly.
    package nonisolated final class ResultCache: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [String: (hits: [IndexHit], total: Int)] = [:]

        package func value(_ key: String, _ make: () -> (hits: [IndexHit], total: Int)) -> (hits: [IndexHit], total: Int) {
            if let cached = lock.withLock({ results[key] }) { return cached }
            let made = make()
            lock.withLock {
                if results.count > 64 { results.removeAll() }
                results[key] = made
            }
            return made
        }
    }

    /// A search as typed: plain English when it reads as such (name matches first, then what the reading found), the
    /// search syntax otherwise. The index and folder searches (`FolderSearch`) both run it, over their own stores.
    package static func understand(_ text: String, scopePath: String?, in store: IndexStore,
                           limit: Int) async -> (hits: [IndexHit], total: Int, interpretation: SearchFilter?) {
        await understand(text, sources: [Source(store: store, scopePath: scopePath, depth: 0)], limit: limit)
    }

    /// `understand` over several stores at once, merged by score: a folder search reads the parts of a folder the
    /// index doesn't have and takes the rest from the index.
    @concurrent
    package static func understand(_ text: String, sources: [Source],
                           limit: Int) async -> (hits: [IndexHit], total: Int, interpretation: SearchFilter?) {
        func runAll(_ query: IndexQuery, limit: Int, tag: String) -> (hits: [IndexHit], total: Int) {
            var hits: [IndexHit] = []
            var total = 0
            for (index, source) in sources.enumerated() {
                var scoped = query
                if let root = source.scopePath {
                    if source.depth > 0, let asked = query.scopePath {
                        // An index folder inside a folder search, with `in:` naming a path: search where they overlap.
                        if asked == root || asked.hasPrefix(root + "/") {
                            scoped.scopePath = asked
                        } else if root.hasPrefix(asked == "/" ? "/" : asked + "/") {
                            scoped.scopePath = root
                        } else {
                            continue
                        }
                    } else {
                        scoped.scopePath = root
                    }
                }
                let search = { run(scoped, in: source.store, limit: limit) }
                let result = source.cache?.value("\(tag)|\(index)|\(limit)|\(text)", search) ?? search()
                total += result.total
                hits += source.depth == 0 ? result.hits : result.hits.map { $0.scored($0.score - 2 * source.depth) }
            }
            guard sources.count > 1 else { return (hits, total) }
            hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
            return (Array(hits.prefix(limit)), total)
        }
        guard let interpreted = NaturalQuery.interpret(text) else {
            let query = IndexQuery.parse(text)
            guard !query.isEmpty else { return ([], 0, nil) }
            let result = runAll(query, limit: limit, tag: "syntax")
            return (result.hits, result.total, nil)
        }
        // The words may also be a name ("Code", "Pictures", "notes.txt"): those matches come first, then what the
        // plain-English reading found.
        let plain = IndexQuery.parse(text)
        let named: (hits: [IndexHit], total: Int) = plain.isEmpty ? ([], 0) : runAll(plain, limit: 50, tag: "named")
        let result = runAll(interpreted.query, limit: limit, tag: "reading")
        let namedPaths = Set(named.hits.map(\.path))
        let rest = result.hits.filter { !namedPaths.contains($0.path) }
        return (named.hits + rest, named.hits.count + result.total - (result.hits.count - rest.count), interpreted.filter)
    }
}
