import Foundation

/// `value` as Int64, clamped to its range (a typed "size:9e30" or "1e20 days" must not trap); nil for NaN.
nonisolated package func saturatingInt64(_ value: Double) -> Int64? {
    guard !value.isNaN else { return nil }
    if value >= 9.2e18 { return .max }
    if value <= -9.2e18 { return .min }
    return Int64(value)
}

/// A count of days, weeks… from a query, kept to a sane range (date arithmetic overflows on absurd values).
nonisolated package func boundedCount(_ value: Double) -> Int {
    guard value.isFinite else { return 0 }
    return Int(max(-1_000_000, min(1_000_000, value)))
}

/// Seconds since 1970 as the index's 32-bit timestamp, clamped.
nonisolated package func indexStamp(_ date: Date) -> UInt32 {
    UInt32(clamping: saturatingInt64(date.timeIntervalSince1970) ?? 0)
}

/// A parsed search: plain words match names (all must appear), plus Everything-style filters:
/// `ext:pdf;png`, `*.pdf`, `kind:image|video|audio|doc|code|archive|app|folder|file`, `size:>100mb`, `size:1mb..1gb`,
/// `modified:today|yesterday|<7d|>30d|2026`, `in:~/Documents` or `in:github` (any enclosing folder name),
/// `!word` to exclude, `"exact phrase"`, and `a/b` to match a folder named like `a` above a name like `b`.
nonisolated package struct IndexQuery: Sendable {
    package enum Kind: String, Sendable {
        case folder, file, image, video, audio, document, book, comic, code, archive, app
    }

    package var terms: [[UInt8]] = []
    package var excludedTerms: [[UInt8]] = []
    /// `a/b` terms: ancestors must match the leading parts, the name the last.
    package var pathTerms: [[[UInt8]]] = []
    package var extensions: Set<String> = []
    package var kind: Kind?
    package var minSize: Int64?
    package var maxSize: Int64?
    package var modifiedAfter: UInt32?
    package var modifiedBefore: UInt32?
    package var scopePath: String?
    package var scopeNames: [[UInt8]] = []
    package var includeNoise = false
    package var includeHidden = false
    /// `regex:pattern`: names must match it (ignoring case unless `case:` is on). An invalid pattern matches nothing.
    package var regex: NameRegex?
    package var invalidRegex = false
    /// `case:` (the scope bar's Match Case): name words and the pattern compare letters exactly, case and accents.
    package var caseSensitive = false

    package init() {}

    /// Anything beyond plain name words (extensions, kind, size, dates, exclusions, folder parts, a pattern).
    package var hasFilters: Bool {
        !extensions.isEmpty || kind != nil || minSize != nil || maxSize != nil || modifiedAfter != nil
            || modifiedBefore != nil || !excludedTerms.isEmpty || !scopeNames.isEmpty || !pathTerms.isEmpty
            || regex != nil || invalidRegex || caseSensitive
    }

    package var isEmpty: Bool {
        terms.isEmpty && pathTerms.isEmpty && extensions.isEmpty && kind == nil && minSize == nil && maxSize == nil
            && modifiedAfter == nil && modifiedBefore == nil && scopeNames.isEmpty && regex == nil && !invalidRegex
    }

    package static let caseWords: Set<String> = ["case:", "case:yes", "case:on", "case:match", "case:sensitive"]
    /// Spelled out, the default: they're understood and set nothing.
    package static let noCaseWords: Set<String> = ["case:off", "case:no", "case:ignore"]

    /// Whether `text` asks for exact case (`case:`).
    package static func isCaseSensitive(_ text: String) -> Bool {
        tokenize(text).contains { caseWords.contains($0.lowercased()) }
    }

    /// `text` with `case:` added or taken out (the scope bar's Match Case), everything else as typed.
    package static func settingCase(_ on: Bool, in text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).filter {
            !caseWords.contains($0.lowercased()) && !noCaseWords.contains($0.lowercased())
        }
        return (words.map(String.init) + (on ? ["case:"] : [])).joined(separator: " ")
    }

    /// How names and terms are compared: composed Unicode, without case or accents ("Café", "cafe" and a decomposed
    /// "Cafe\u{301}" from Foundation all match).
    package static func foldText(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    package static func parse(_ text: String, now: Date = .now) -> IndexQuery {
        var query = IndexQuery()
        let tokens = tokenize(text)
        query.caseSensitive = tokens.contains { caseWords.contains($0.lowercased()) }
        var pattern: String?
        for token in tokens { read(token, into: &query, pattern: &pattern, now: now) }
        finish(&query, pattern: pattern)
        return query
    }

    /// One word of a query: a case word, a regex, a filter, a scope, or a term.
    private static func read(_ token: String, into query: inout IndexQuery, pattern: inout String?, now: Date) {
        let lower = token.lowercased()
        if caseWords.contains(lower) || noCaseWords.contains(lower) { return }
        if lower.hasPrefix("regex:") || lower.hasPrefix("re:") {
            let value = String(token.drop(while: { $0 != ":" }).dropFirst())
            if !value.isEmpty { pattern = value }
        } else if readFilter(lower, into: &query, now: now) {
            return
        } else if let value = value(of: token, keys: ["in:", "In:", "IN:"]) {
            // (Folder names below are matched without case either way.)
            if value.hasPrefix("/") || value.hasPrefix("~") {
                query.scopePath = (value as NSString).expandingTildeInPath
            } else {
                let scope = foldText(value)
                if !scope.isEmpty { query.scopeNames.append(Array(scope.utf8)) }
            }
        } else {
            readTerm(token, into: &query)
        }
    }

    /// `ext:`, `*.ext`, `kind:`, `size:` or `modified:`: whether `lower` was one.
    private static func readFilter(_ lower: String, into query: inout IndexQuery, now: Date) -> Bool {
        if let value = value(of: lower, keys: ["ext:", "extension:"]) {
            query.extensions.formUnion(value.split(whereSeparator: { ";,|".contains($0) }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        } else if lower.hasPrefix("*."), lower.count > 2, !lower.dropFirst(2).contains("*") {
            // "*.tar.gz": the last extension, plus the whole suffix as part of the name.
            let suffix = String(lower.dropFirst(2))
            query.extensions.insert(String(suffix.split(separator: ".").last ?? Substring(suffix)))
            if suffix.contains(".") { query.terms.append(Array(suffix.utf8)) }
        } else if let value = value(of: lower, keys: ["kind:", "type:", "is:"]) {
            // "kind:pdf" names an extension; "kind:spreadsheet" a group of them.
            if let kind = kind(value) {
                query.kind = kind
            } else if let group = extensionGroups[value] {
                query.extensions.formUnion(group)
            } else {
                query.extensions.insert(value)
            }
        } else if let value = value(of: lower, keys: ["size:"]) {
            (query.minSize, query.maxSize) = sizeRange(value)
        } else if let value = value(of: lower, keys: ["modified:", "mod:", "date:", "dm:"]) {
            (query.modifiedAfter, query.modifiedBefore) = dateRange(value, now: now)
        } else {
            return false
        }
        return true
    }

    /// A word to leave out ("-draft"), a path ("projects/app"), or a word the name contains.
    private static func readTerm(_ token: String, into query: inout IndexQuery) {
        let lower = token.lowercased()
        // With case on, words keep their letters (composed the same way names are compared).
        let folded = query.caseSensitive ? token.precomposedStringWithCanonicalMapping : foldText(token)
        if (lower.hasPrefix("!") || lower.hasPrefix("-")) && lower.count > 1 {
            let term = folded.dropFirst()
            if !term.isEmpty { query.excludedTerms.append(Array(term.utf8)) }
        } else if lower == "!" || lower == "-" {
            return   // Half-typed exclusion: not a term yet.
        } else if lower.contains("/") {
            // Folder parts are matched without case either way; the name (the last part) follows `case:`.
            var parts = foldText(token).split(separator: "/").map { Array($0.utf8) }
            if query.caseSensitive, parts.count > 1, let name = folded.split(separator: "/").last {
                parts[parts.count - 1] = Array(name.utf8)
            }
            if parts.count == 1 { query.terms.append(parts[0]) } else if parts.count > 1 { query.pathTerms.append(parts) }
        } else if !folded.isEmpty {
            query.terms.append(Array(folded.utf8))
        }
    }

    /// The regex, once every word is read (`case:` may come after it), and whether hidden items and build or cache
    /// folders are wanted: names that start with a dot, or `in:target` (or another such folder) to look inside them.
    private static func finish(_ query: inout IndexQuery, pattern: String?) {
        if let pattern {
            if let regex = NameRegex(pattern, caseSensitive: query.caseSensitive) { query.regex = regex } else { query.invalidRegex = true }
        }
        let mentioned = (query.terms + query.pathTerms.flatMap { $0 } + query.scopeNames).map { String(decoding: $0, as: UTF8.self).lowercased() }
        let scopes = query.scopeNames.map { String(decoding: $0, as: UTF8.self) }
        query.includeHidden = mentioned.contains { $0.hasPrefix(".") } || scopes.contains { noiseWords.contains($0) }
        query.includeNoise = mentioned.contains { noiseWords.contains($0) || $0.hasPrefix(".") }
            || scopes.contains { buildFolderWords.contains($0) }
    }

    private static let extensionGroups: [String: Set<String>] = [
        "spreadsheet": ["xls", "xlsx", "numbers", "csv", "ods", "tsv"], "spreadsheets": ["xls", "xlsx", "numbers", "csv", "ods", "tsv"],
        "presentation": ["key", "ppt", "pptx", "odp"], "presentations": ["key", "ppt", "pptx", "odp"], "slides": ["key", "ppt", "pptx", "odp"],
        "diskimage": ["dmg", "iso", "img", "sparseimage"], "pdfs": ["pdf"],
    ]

    private static let noiseWords: Set<String> = ["library", "node_modules", "caches", "deriveddata", "pods", ".git"]
    private static let buildFolderWords: Set<String> = ["target", "dist", "build", "bin", "obj", "out", "coverage"]

    package static func tokenize(_ text: String) -> [String] {
        SearchTerms.split(text).map(\.value)
    }

    private static func value(of token: String, keys: [String]) -> String? {
        for key in keys where token.hasPrefix(key) && token.count > key.count {
            return String(token.dropFirst(key.count))
        }
        return nil
    }

    private static func kind(_ value: String) -> Kind? {
        switch value {
        case "folder", "folders", "dir", "directory": .folder
        case "file", "files": .file
        case "image", "images", "photo", "photos", "picture", "pic": .image
        case "video", "videos", "movie", "movies": .video
        case "audio", "music", "sound", "song": .audio
        case "doc", "docs", "document", "documents", "text": .document
        case "book", "books", "ebook", "ebooks": .book
        case "comic", "comics": .comic
        case "code", "source", "src": .code
        case "archive", "archives", "zip", "compressed": .archive
        case "app", "apps", "application", "applications": .app
        default: nil
        }
    }

    package static func bytes(_ text: String) -> Int64? {
        let units: [(String, Double)] = [
            ("tib", 1_099_511_627_776), ("gib", 1_073_741_824), ("mib", 1_048_576), ("kib", 1024),
            ("tb", 1e12), ("gb", 1e9), ("mb", 1e6), ("kb", 1e3), ("t", 1e12), ("g", 1e9), ("m", 1e6), ("k", 1e3), ("b", 1),
        ]
        for (suffix, multiplier) in units where text.hasSuffix(suffix) {
            guard let number = Double(text.dropLast(suffix.count)), number.isFinite, number >= 0 else { return nil }
            return saturatingInt64(number * multiplier)
        }
        guard let number = Double(text), number.isFinite, number >= 0 else { return nil }
        return saturatingInt64(number)
    }

    private static func sizeRange(_ value: String) -> (Int64?, Int64?) {
        if let range = value.range(of: "..") {
            return (bytes(String(value[..<range.lowerBound])), bytes(String(value[range.upperBound...])))
        }
        if value.hasPrefix(">=") { return (bytes(String(value.dropFirst(2))), nil) }
        if value.hasPrefix("<=") { return (nil, bytes(String(value.dropFirst(2)))) }
        if value.hasPrefix(">") { return (bytes(String(value.dropFirst())).map { $0 == .max ? .max : $0 + 1 }, nil) }
        if value.hasPrefix("<") { return (nil, bytes(String(value.dropFirst())).map { $0 == .min ? .min : $0 - 1 }) }
        switch value {
        case "empty": return (0, 0)
        case "tiny": return (0, 10_000)
        case "small": return (10_001, 1_000_000)
        case "medium": return (1_000_001, 100_000_000)
        case "large": return (100_000_001, 1_000_000_000)
        case "huge": return (1_000_000_001, nil)
        default:
            let exact = bytes(value)
            return (exact, exact)
        }
    }

    private static func dateRange(_ value: String, now: Date) -> (UInt32?, UInt32?) {
        func instant(_ value: String) -> UInt32? {
            ISO8601DateFormatter().date(from: value.uppercased()).map(indexStamp)
        }
        if let range = value.range(of: "..") {
            let after = String(value[..<range.lowerBound]), before = String(value[range.upperBound...])
            return (instant(after) ?? day(after).map(indexStamp), instant(before) ?? day(before).map(indexStamp))
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func stamp(_ date: Date) -> UInt32 { indexStamp(date) }
        // Calendar days, not 86,400 s: a day around a daylight-saving change is 23 or 25 hours.
        func dayAfter(_ date: Date) -> Date { calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400) }
        switch value {
        case "today": return (stamp(today), nil)
        case "yesterday":
            return (stamp(calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)), stamp(today))
        case "thisweek", "week": return (stamp(now.addingTimeInterval(-7 * 86_400)), nil)
        case "thismonth", "month": return (stamp(now.addingTimeInterval(-30 * 86_400)), nil)
        default: break
        }
        if let operatorEnd = value.firstIndex(where: { !"<>=".contains($0) }), operatorEnd != value.startIndex {
            let op = value[..<operatorEnd]
            let amount = String(value[operatorEnd...])
            if let seconds = duration(amount) {
                let boundary = stamp(now.addingTimeInterval(-seconds))
                // `<7d` means "less than 7 days old"; `>30d` means "older than 30 days".
                return op.hasPrefix("<") ? (boundary, nil) : (nil, boundary)
            }
            if let stamp = instant(amount) { return op.hasPrefix("<") ? (nil, stamp) : (stamp, nil) }
            if let date = day(amount) {
                return op.hasPrefix("<") ? (nil, stamp(date)) : (stamp(date), nil)
            }
        }
        if value.count == 4, let year = Int(value),
           let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
           let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) {
            return (stamp(start), stamp(end))
        }
        if let date = day(value) { return (stamp(date), stamp(dayAfter(date))) }
        return (nil, nil)
    }

    private static func duration(_ text: String) -> Double? {
        let units: [(Character, Double)] = [("h", 3600), ("d", 86_400), ("w", 7 * 86_400), ("m", 30 * 86_400), ("y", 365 * 86_400)]
        guard let last = text.last, let unit = units.first(where: { $0.0 == last }),
              let number = Double(text.dropLast()), number.isFinite, number >= 0 else { return nil }
        let seconds = number * unit.1
        return seconds.isFinite ? seconds : nil
    }

    private static func day(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}

/// One search result, read out of the index under its lock.
nonisolated package struct IndexHit: Sendable {
    package let path: String
    package let isDirectory: Bool
    package let isPackage: Bool
    package let size: Int64
    package let files: UInt32
    package let mtime: UInt32
    package let score: Int

    /// The same hit with another score (results merged from several stores).
    package func scored(_ score: Int) -> IndexHit {
        IndexHit(path: path, isDirectory: isDirectory, isPackage: isPackage, size: size, files: files, mtime: mtime, score: score)
    }
}

/// Per-chunk results collected from `concurrentPerform` workers.
nonisolated private final class Partials: @unchecked Sendable {
    private var chunks: [[(id: Int32, score: Int32)]]
    private let lock = NSLock()

    init(count: Int) { chunks = Array(repeating: [], count: count) }

    func set(_ index: Int, _ value: [(id: Int32, score: Int32)]) {
        lock.lock()
        chunks[index] = value
        lock.unlock()
    }

    var all: [(id: Int32, score: Int32)] { chunks.flatMap { $0 } }
}

nonisolated package enum IndexSearch {
    private static let extensionsByKind: [IndexQuery.Kind: Set<String>] = [
        .image: ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "raw", "cr2", "cr3", "nef", "arw", "dng", "psd", "ico", "icns", "avif"],
        .video: ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "mpg", "mpeg", "3gp"],
        .audio: ["mp3", "m4a", "wav", "aiff", "aif", "flac", "ogg", "aac", "opus", "wma", "caf"],
        .document: ["pdf", "doc", "docx", "pages", "txt", "rtf", "md", "markdown", "key", "ppt", "pptx", "xls", "xlsx", "numbers", "csv", "odt", "ods", "epub", "mobi", "azw", "azw3", "djvu", "djv", "fb2", "tex"],
        .book: ["epub", "mobi", "azw", "azw3", "djvu", "djv", "fb2"],
        .comic: ["cbz", "cbr", "cb7", "cbt"],
        .code: ["swift", "rs", "ts", "tsx", "js", "jsx", "mjs", "py", "go", "c", "h", "cpp", "hpp", "cc", "m", "mm", "cs", "java", "kt", "rb", "php", "sh", "zsh", "json", "yaml", "yml", "toml", "html", "css", "scss", "xml", "sql", "gd", "lua", "dart", "vue", "svelte"],
        .archive: ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg", "iso", "zst", "cbz", "cbr", "cb7", "cbt"],
    ]

    package static func extensions(for kind: IndexQuery.Kind) -> Set<String> {
        extensionsByKind[kind] ?? []
    }

    /// Runs `query` over the whole store in parallel and returns the best `limit` hits plus the total match count.
    ///
    /// Only matching holds the store's read lock. Ranking happens outside it, because a folder search's scanner waits
    /// on that lock and "e" can match a million entries; the lock is taken again just to build the `limit` hits. Ids stay
    /// valid in between: a store only grows (compaction makes a new one).
    package static func run(_ query: IndexQuery, in store: IndexStore, limit: Int) -> (hits: [IndexHit], total: Int) {
        let matched = matches(query, in: store)
        let best = top(matched, limit)
        let hits = store.read { store in
            best.map { item -> IndexHit in
                let id = Int(item.id)
                return IndexHit(path: store.path(of: item.id), isDirectory: store.flags[id] & IndexStore.Flag.directory != 0,
                                isPackage: store.flags[id] & IndexStore.Flag.package != 0, size: store.size[id],
                                files: store.fileCount[id], mtime: store.mtime[id], score: Int(item.score))
            }
        }
        return (hits, matched.count)
    }

    /// The best `limit` of `all`, by score then id (ties in id order stay put while a folder search's store grows, so
    /// live results don't reshuffle). Beyond a few thousand it doesn't sort everything: it counts scores to find the one
    /// that cuts at `limit` and sorts only what's above it.
    package static func top(_ all: [(id: Int32, score: Int32)], _ limit: Int) -> [(id: Int32, score: Int32)] {
        let ordered: ((id: Int32, score: Int32), (id: Int32, score: Int32)) -> Bool = {
            $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id
        }
        guard limit > 0 else { return [] }
        guard all.count / 4 > limit else { return Array(all.sorted(by: ordered).prefix(limit)) }
        var low = Int32.max, high = Int32.min
        for item in all {
            low = min(low, item.score)
            high = max(high, item.score)
        }
        let span = Int(high) - Int(low) + 1
        guard span <= 1 << 16 else { return Array(all.sorted(by: ordered).prefix(limit)) }
        var counts = [Int](repeating: 0, count: span)
        for item in all { counts[Int(item.score - low)] += 1 }
        // Walk down from the best score until at least `limit` are at or above it.
        var cut = span - 1
        var above = 0
        while cut > 0 && above + counts[cut] < limit {
            above += counts[cut]
            cut -= 1
        }
        let threshold = low + Int32(cut)
        return Array(all.filter { $0.score >= threshold }.sorted(by: ordered).prefix(limit))
    }

    /// Every entry matching `query`, with its score (under the read lock).
    private static func matches(_ query: IndexQuery, in store: IndexStore) -> [(id: Int32, score: Int32)] {
        store.read { store in
            let count = store.count
            guard count > 0, !query.isEmpty else { return [] }
            let scopeID: Int32? = query.scopePath.flatMap { store.lookup($0) }
            if query.scopePath != nil && scopeID == nil { return [] }
            // Searching inside a cache or build folder (in:, or the scope bar while browsing it) includes its contents.
            var scoped = query
            if let scopeID, store.flags[Int(scopeID)] & IndexStore.Flag.noise != 0 { scoped.includeNoise = true }
            // Same for hidden folders (~/Library is hidden, and so is everything in it).
            if let scopeID, store.flags[Int(scopeID)] & IndexStore.Flag.hidden != 0 { scoped.includeHidden = true }
            let query = scoped
            let extensions = query.kind.flatMap { extensionsByKind[$0] }.map { query.extensions.isEmpty ? $0 : $0.intersection(query.extensions) }
                ?? query.extensions
            let wantedExtensions = extensions.compactMap { ext in Array(ext.utf8).withUnsafeBufferPointer { packExtension($0) } }
            // Only extensions longer than any real one were asked for: nothing can match (not everything).
            if !extensions.isEmpty && wantedExtensions.isEmpty { return [] }
            let now = Int(Date().timeIntervalSince1970)

            let chunks = max(1, min(64, count / 50_000))
            let partials = Partials(count: chunks)
            store.withColumns { columns in
                // `a/b` and `in:name` need folder parts matched by ancestors: work out, in one pass from the roots down,
                // how many leading parts each folder's path has matched (instead of walking every candidate's
                // ancestors, which made such searches ~100× slower).
                let chains = query.pathTerms.map { Array($0.dropLast()) } + query.scopeNames.map { [$0] }
                func collect<Progress: FixedWidthInteger & Sendable>(_: Progress.Type) {
                    let progress: [[Progress]] = chains.map { ancestorProgress($0, columns, count) }
                    DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                        let lower = count * chunk / chunks
                        let upper = count * (chunk + 1) / chunks
                        var found: [(id: Int32, score: Int32)] = []
                        for id in lower..<upper {
                            if let score = match(id, query, columns, scopeID, wantedExtensions, now, progress) {
                                found.append((Int32(id), Int32(score)))
                            }
                        }
                        partials.set(chunk, found)
                    }
                }
                // Keep ordinary searches compact; deep paths can match more than 255 ancestors.
                if chains.contains(where: { $0.count > Int(UInt8.max) }) { collect(UInt32.self) }
                else { collect(UInt8.self) }
            }
            return partials.all
        }
    }

    /// Files changed recently, newest first, skipping folders, hidden items and noise such as caches.
    package static func recent(in store: IndexStore, since: UInt32, limit: Int) -> [IndexHit] {
        store.read { store in
            var found: [(id: Int32, mtime: UInt32)] = []
            let skip = IndexStore.Flag.directory | IndexStore.Flag.noise | IndexStore.Flag.hidden | IndexStore.Flag.deleted
            // App internals carry the noise flag, so the skip mask already leaves them out.
            for id in 0..<store.count where store.flags[id] & skip == 0 && store.mtime[id] >= since {
                found.append((Int32(id), store.mtime[id]))
            }
            found.sort { $0.mtime > $1.mtime }
            return found.prefix(limit).map { item in
                let id = Int(item.id)
                return IndexHit(path: store.path(of: item.id), isDirectory: false, isPackage: false, size: store.size[id],
                                files: 1, mtime: store.mtime[id], score: 0)
            }
        }
    }

    // Called under the read lock from many threads at once.
    private static func match<Progress: FixedWidthInteger>(_ i: Int, _ query: IndexQuery, _ c: IndexStore.Columns, _ scopeID: Int32?,
                              _ extensions: [UInt64], _ now: Int, _ progress: [[Progress]]) -> Int? {
        let flags = c.flags[i]
        guard passesFilters(i, flags, query, c) else { return nil }
        let isDirectory = flags & IndexStore.Flag.directory != 0
        let isPackage = flags & IndexStore.Flag.package != 0
        let name = c.name(i)
        guard var score = nameScore(i, flags, name, query, c, extensions, progress), let depth = depth(of: i, c, in: scopeID)
        else { return nil }
        // Prefer shallow paths, recent changes, apps and folders a little.
        score -= depth * 2 + name.count / 6
        let age = now - Int(c.mtime[i])
        if age < 86_400 { score += 12 } else if age < 7 * 86_400 { score += 8 } else if age < 30 * 86_400 { score += 4 }
        if isPackage { score += 10 } else if isDirectory { score += 4 }
        return score + 1000
    }

    /// Whether the item is one the query looks at, by what it is, its size and its date.
    @inline(__always)
    private static func passesFilters(_ i: Int, _ flags: UInt8, _ query: IndexQuery, _ c: IndexStore.Columns) -> Bool {
        if flags & IndexStore.Flag.deleted != 0 || c.parent[i] < 0 { return false }
        if !query.includeNoise && flags & IndexStore.Flag.noise != 0 { return false }
        if !query.includeHidden && flags & IndexStore.Flag.hidden != 0 { return false }
        let isDirectory = flags & IndexStore.Flag.directory != 0
        let isPackage = flags & IndexStore.Flag.package != 0
        switch query.kind {
        case .folder: if !isDirectory || isPackage { return false }
        case .file: if isDirectory && !isPackage { return false }
        case .app: if !isPackage { return false }
        case .book, .comic: if isDirectory { return false }
        default: break
        }
        if let minSize = query.minSize, c.size[i] < minSize { return false }
        if let maxSize = query.maxSize, c.size[i] > maxSize { return false }
        if let after = query.modifiedAfter, c.mtime[i] < after { return false }
        if let before = query.modifiedBefore, c.mtime[i] >= before { return false }
        return true
    }

    /// How well the item's name (and the folders above it, through `progress`) matches the query's words, or nil when
    /// it doesn't.
    @inline(__always)
    private static func nameScore<Progress: FixedWidthInteger>(_ i: Int, _ flags: UInt8, _ name: UnsafeBufferPointer<UInt8>,
                                                               _ query: IndexQuery, _ c: IndexStore.Columns,
                                                               _ extensions: [UInt64], _ progress: [[Progress]]) -> Int? {
        let isDirectory = flags & IndexStore.Flag.directory != 0
        let isPackage = flags & IndexStore.Flag.package != 0
        // Names with non-ASCII bytes are compared Unicode-aware (folded once, or just composed with case on); ASCII
        // names take the byte search alone.
        let unicode = flags & IndexStore.Flag.unicodeName != 0
        let foldedName: [UInt8]? = unicode && !query.caseSensitive ? folded(name) : nil
        let composedName: [UInt8]? = unicode && query.caseSensitive ? composed(name) : nil
        @inline(__always) func locate(_ term: [UInt8]) -> Int? {
            if query.caseSensitive {
                if let composedName { return composedName.withUnsafeBufferPointer { findExact(term, in: $0) } }
                return findExact(term, in: name)
            }
            if let foldedName { return foldedName.withUnsafeBufferPointer { find(term, in: $0) } }
            return find(term, in: name)
        }
        if query.kind == .app {
            guard hasSuffix(name, appSuffix) else { return nil }
        } else if !extensions.isEmpty {
            guard !isDirectory || isPackage, let dot = name.lastIndex(of: UInt8(ascii: ".")) else { return nil }
            guard let ext = packExtension(UnsafeBufferPointer(rebasing: name[(dot + 1)...])), extensions.contains(ext) else { return nil }
        }
        var score = 0
        for (index, term) in query.terms.enumerated() {
            guard let position = locate(term) else { return nil }
            score += index == 0 ? positionScore(min(position, name.count - 1), term.count, name) : 10
        }
        for term in query.excludedTerms where locate(term) != nil { return nil }
        if query.invalidRegex { return nil }
        if let regex = query.regex, !regex.matches(String(decoding: name, as: UTF8.self)) { return nil }
        let parent = Int(c.parent[i])
        for (index, parts) in query.pathTerms.enumerated() {
            guard let last = parts.last, let position = locate(last) else { return nil }
            guard parts.count == 1 || Int(progress[index][parent]) >= parts.count - 1 else { return nil }
            score += positionScore(min(position, name.count - 1), last.count, name) + 20
        }
        for index in query.scopeNames.indices where progress[query.pathTerms.count + index][parent] < 1 { return nil }
        return score
    }

    /// How deep the item is, or nil when it isn't inside `scopeID`: one walk to the root does both.
    @inline(__always)
    private static func depth(of i: Int, _ c: IndexStore.Columns, in scopeID: Int32?) -> Int? {
        var depth = 0
        var inScope = scopeID == nil
        var ancestor = c.parent[i]
        while ancestor >= 0 {
            if ancestor == scopeID { inScope = true }
            depth += 1
            ancestor = c.parent[Int(ancestor)]
        }
        return inScope ? depth : nil
    }

    private static let appSuffix = Array(".app".utf8)

    /// Lowercased extension packed into one integer (extensions longer than 8 bytes never match).
    @inline(__always)
    private static func packExtension(_ ext: UnsafeBufferPointer<UInt8>) -> UInt64? {
        guard !ext.isEmpty, ext.count <= 8 else { return nil }
        var packed: UInt64 = 0
        for byte in ext { packed = packed << 8 | UInt64(fold(byte)) }
        return packed
    }

    private static func positionScore(_ position: Int, _ termLength: Int, _ name: UnsafeBufferPointer<UInt8>) -> Int {
        if position == 0 && termLength == name.count { return 120 }
        if position <= 0 { return 70 }
        let previous = name[position - 1]
        if previous == UInt8(ascii: " ") || previous == UInt8(ascii: "-") || previous == UInt8(ascii: "_") || previous == UInt8(ascii: ".") {
            return 45
        }
        return 20
    }

    /// For each entry, how many of `parts` (in order) are found in the names along its path, root first, itself
    /// included. Parents have smaller ids than their children, so one forward pass computes it; only folders can be
    /// ancestors, so files just inherit.
    private static func ancestorProgress<Progress: FixedWidthInteger>(_ parts: [[UInt8]], _ c: IndexStore.Columns, _ count: Int) -> [Progress] {
        var progress = [Progress](repeating: 0, count: count)
        guard !parts.isEmpty else { return progress }
        for i in 0..<count {
            let p = Int(c.parent[i])
            var value = p >= 0 ? progress[p] : 0
            if c.flags[i] & IndexStore.Flag.directory != 0, Int(value) < parts.count {
                let name = c.name(i)
                let part = parts[Int(value)]
                let found = c.flags[i] & IndexStore.Flag.unicodeName != 0
                    ? folded(name)?.withUnsafeBufferPointer({ find(part, in: $0) }) != nil
                    : find(part, in: name) != nil
                if found { value += 1 }
            }
            progress[i] = value
        }
        return progress
    }

    /// `name` in composed form, for exact (case-sensitive) comparison.
    private static func composed(_ name: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        Array(String(decoding: name, as: UTF8.self).precomposedStringWithCanonicalMapping.utf8)
    }

    /// Exact substring search.
    private static func findExact(_ term: [UInt8], in name: UnsafeBufferPointer<UInt8>) -> Int? {
        let n = name.count, m = term.count
        guard m > 0, m <= n else { return nil }
        var i = 0
        while i <= n - m {
            if name[i] == term[0] {
                var j = 1
                while j < m && name[i + j] == term[j] { j += 1 }
                if j == m { return i }
            }
            i += 1
        }
        return nil
    }

    /// `name` folded with `foldText`, or nil when it's plain ASCII (the byte search already covers it).
    private static func folded(_ name: UnsafeBufferPointer<UInt8>) -> [UInt8]? {
        guard name.contains(where: { $0 >= 0x80 }) else { return nil }
        return Array(IndexQuery.foldText(String(decoding: name, as: UTF8.self)).utf8)
    }

    @inline(__always)
    private static func fold(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte | 0x20 : byte
    }

    /// Case-insensitive (ASCII) substring search; `term` is already lowercase.
    private static func find(_ term: [UInt8], in name: UnsafeBufferPointer<UInt8>) -> Int? {
        let n = name.count, m = term.count
        guard m > 0, m <= n else { return nil }
        let first = term[0]
        var i = 0
        while i <= n - m {
            if fold(name[i]) == first {
                var j = 1
                while j < m && fold(name[i + j]) == term[j] { j += 1 }
                if j == m { return i }
            }
            i += 1
        }
        return nil
    }

    private static func equalsFolded(_ a: UnsafeBufferPointer<UInt8>, _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        for k in 0..<a.count where fold(a[k]) != b[k] { return false }
        return true
    }

    private static func hasSuffix(_ name: UnsafeBufferPointer<UInt8>, _ suffix: [UInt8]) -> Bool {
        guard name.count >= suffix.count else { return false }
        return equalsFolded(UnsafeBufferPointer(rebasing: name[(name.count - suffix.count)...]), suffix)
    }
}

/// A `regex:` pattern, compiled once and shared by the threads searching. Some patterns take exponentially long on
/// some names: a name gets a moment, then counts as not matching (and is counted, so the summary can say so); a
/// search's total time on the pattern is limited too.
nonisolated package final class NameRegex: @unchecked Sendable {
    package let pattern: String
    private let expression: NSRegularExpression
    private let deadline: Date
    private static let perName: TimeInterval = 0.02

    /// Names a pattern gave up on, since launch (the search summary compares before and after).
    private static let lock = NSLock()
    nonisolated(unsafe) private static var givenUp = 0
    package static var namesGivenUp: Int { lock.withLock { givenUp } }

    package init?(_ pattern: String, caseSensitive: Bool, budget: TimeInterval = 4) {
        // Composed like the names it's matched against ("é" typed or pasted either way).
        let composed = pattern.precomposedStringWithCanonicalMapping
        guard composed.count <= 500,
              let expression = try? NSRegularExpression(pattern: composed, options: caseSensitive ? [] : [.caseInsensitive])
        else { return nil }
        self.pattern = composed
        self.expression = expression
        deadline = Date().addingTimeInterval(budget)
    }

    package func matches(_ name: String) -> Bool {
        let start = Date()
        guard start <= deadline else {
            Self.lock.withLock { Self.givenUp += 1 }
            return false
        }
        var found = false
        var gaveUp = false
        let text = name.precomposedStringWithCanonicalMapping
        expression.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: (text as NSString).length)) { match, _, stop in
            if match != nil {
                found = true
                stop.pointee = true
            } else if Date().timeIntervalSince(start) > Self.perName {
                gaveUp = true
                stop.pointee = true
            }
        }
        if gaveUp { Self.lock.withLock { Self.givenUp += 1 } }
        return found
    }
}
