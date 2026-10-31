import Foundation

/// A search only Spotlight can answer: things Strata's index doesn't record, like Finder tags and what's inside files'
/// metadata. `tag:Red`, `tag:"Client X"`, `camera:iphone`, `width:>1920`, `height:<1000`, `duration:>10m`, `pages:>20`,
/// `author:Ana`, `artist:"Miles Davis"`; with them, `kind:` (image, video, audio, pdf), other words (by name) and `ext:`
/// narrow it down, as in a normal search. A few plain-English forms read the same way ("photos taken with iPhone",
/// "videos longer than 10 minutes").
nonisolated package struct SpotlightQuery: Equatable, Sendable {
    package var tags: [String] = []
    package var words: [String] = []
    package var extensions: [String] = []
    package var conditions: [Condition] = []
    package var unsupportedSourceFilters = false

    package static func acceptsSourceNames(_ text: String) -> Bool {
        let metadata: Set<String> = ["source", "from", "tag", "kind", "type", "is", "ext", "extension", "size", "modified", "mod", "date", "dm",
                                     "camera", "device", "author", "by", "artist", "width", "height", "pages", "duration", "length"]
        let terms = SearchTerms.split(text)
        guard terms.allSatisfy(\.isComplete) else { return false }
        let names = terms.filter { !metadata.contains($0.key ?? "") }.map(\.raw).joined(separator: " ")
        let query = IndexQuery.parse(names)
        return query.regex == nil && !query.invalidRegex && !query.caseSensitive && query.pathTerms.isEmpty
            && query.scopePath == nil && query.scopeNames.isEmpty && query.excludedTerms.isEmpty
    }

    /// One metadata test: text found in any of `attributes`, or a number compared with `value`.
    package struct Condition: Equatable, Sendable {
        package enum Test: Equatable, Sendable {
            case contains(String)
            case anyContains(String)
            case anyEquals(String)
            case suffixes([String])
            case integer(Comparison, Int64)
            case date(Comparison, Date)
            case equals(String)
            case compare(Comparison, Double)
        }

        package enum Comparison: String, Sendable {
            case greater = ">", greaterOrEqual = ">=", less = "<", lessOrEqual = "<=", equal = "=="
        }

        package let attributes: [String]
        package let test: Test
        /// "camera “iPhone”", "longer than 10 min", for the results summary.
        package let label: String
        /// `kind:` only narrows a metadata search; on its own it's the index's job.
        package var isKind = false
        package var isNarrowing = false
    }

    /// Nil when nothing in `text` needs Spotlight.
    package static func parse(_ text: String) -> SpotlightQuery? {
        var query = SpotlightQuery()
        let input = naturalForm(text) ?? text
        for token in SearchTerms.split(input).map(\.value) {
            let lower = token.lowercased()
            // The index's own options mean nothing to Spotlight (it ignores case anyway).
            if lower.hasPrefix("case:") || lower.hasPrefix("regex:") || lower.hasPrefix("re:") { continue }
            if lower.hasPrefix("tag:") {
                let value = String(token.dropFirst(4))
                if !value.isEmpty { query.tags.append(value) }
            } else if lower.hasPrefix("ext:") || lower.hasPrefix("extension:") {
                query.extensions += token.drop(while: { $0 != ":" }).dropFirst().split(whereSeparator: { ",;|".contains($0) }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
                    .filter { !$0.isEmpty }
            } else if ["size", "modified", "mod", "date", "dm"].contains(token.firstIndex(of: ":").map { token[..<$0].lowercased() } ?? "") {
                let index = IndexQuery.parse(token)
                func append(_ attribute: String, _ test: Condition.Test) {
                    var condition = Condition(attributes: [attribute], test: test, label: token)
                    condition.isNarrowing = true
                    query.conditions.append(condition)
                }
                if let min = index.minSize { append("kMDItemFSSize", .integer(.greaterOrEqual, min)) }
                if let max = index.maxSize { append("kMDItemFSSize", .integer(.lessOrEqual, max)) }
                if let after = index.modifiedAfter { append("kMDItemFSContentChangeDate", .date(.greaterOrEqual, Date(timeIntervalSince1970: Double(after)))) }
                if let before = index.modifiedBefore { append("kMDItemFSContentChangeDate", .date(.less, Date(timeIntervalSince1970: Double(before)))) }
            } else if let condition = condition(token) {
                query.conditions.append(condition)
            } else {
                query.words.append(token)
            }
        }
        // An artist is music's: without a kind, fonts and templates (which have "authors") would match too.
        if query.conditions.contains(where: { $0.attributes.contains("kMDItemComposer") }), !query.conditions.contains(where: \.isKind) {
            var audio = Condition(attributes: ["kMDItemContentTypeTree"], test: .anyEquals("public.audio"),
                                  label: String(localized: "audio", comment: "Search summary: kind of files"))
            audio.isKind = true
            query.conditions.insert(audio, at: 0)
        }
        if query.conditions.contains(where: { $0.attributes.contains("kMDItemWhereFroms") }) {
            query.unsupportedSourceFilters = !acceptsSourceNames(input)
        }
        return query.tags.isEmpty && !query.conditions.contains(where: { !$0.isKind && !$0.isNarrowing }) ? nil : query
    }

    /// `key:value` for the metadata keys, or nil.
    private static func condition(_ token: String) -> Condition? {
        guard let colon = token.firstIndex(of: ":") else { return nil }
        let key = token[..<colon].lowercased()
        let value = String(token[token.index(after: colon)...])
        guard !value.isEmpty else { return nil }
        switch key {
        case "source", "from":
            return Condition(attributes: ["kMDItemWhereFroms"], test: .anyContains(value),
                             label: String(localized: "downloaded from “\(value)”", comment: "Search summary: the file’s saved download source"))
        case "camera", "device":
            return Condition(attributes: ["kMDItemAcquisitionModel", "kMDItemAcquisitionMake"], test: .contains(value),
                             label: String(localized: "camera “\(value)”", comment: "Search summary: taken with a camera, like “camera “iPhone””"))
        case "author", "by":
            // Authors only: kMDItemCreator is the app that made the file.
            return Condition(attributes: ["kMDItemAuthors"], test: .anyContains(value),
                             label: String(localized: "by “\(value)”", comment: "Search summary: written by an author"))
        case "artist":
            return Condition(attributes: ["kMDItemAuthors", "kMDItemComposer"], test: .contains(value),
                             label: String(localized: "artist “\(value)”", comment: "Search summary: music by an artist"))
        case "width", "height", "pages":
            guard let (comparison, number) = comparison(value, units: [:]),
                  let count = saturatingInt64(number).map(Int.init(clamping:)) else { return nil }
            let attribute = key == "width" ? "kMDItemPixelWidth" : key == "height" ? "kMDItemPixelHeight" : "kMDItemNumberOfPages"
            return Condition(attributes: [attribute], test: .compare(comparison, number),
                             label: describe(comparison, count, key))
        case "duration", "length":
            return durationCondition(value)
        case "kind", "type", "is":
            return kindCondition(value, token: token)
        default:
            return nil
        }
    }

    private static let durationUnits: [String: Double] = [
        "s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1, "m": 60, "min": 60, "mins": 60, "minute": 60,
        "minutes": 60, "h": 3600, "hr": 3600, "hour": 3600, "hours": 3600,
    ]

    /// "duration:>10m": a comparison of how long a recording plays.
    private static func durationCondition(_ value: String) -> Condition? {
        guard let (comparison, seconds) = comparison(value, units: durationUnits) else { return nil }
        let length = duration(seconds)
        let label = switch comparison {
        case .greater: String(localized: "longer than \(length)", comment: "Search summary: a duration, like “longer than 10 min”")
        case .greaterOrEqual: String(localized: "at least \(length)", comment: "Search summary: a duration, like “at least 10 min”")
        case .less: String(localized: "shorter than \(length)", comment: "Search summary: a duration, like “shorter than 10 min”")
        case .lessOrEqual: String(localized: "at most \(length)", comment: "Search summary: a duration, like “at most 10 min”")
        case .equal: String(localized: "exactly \(length)", comment: "Search summary: a duration, like “exactly 10 min”")
        }
        return Condition(attributes: ["kMDItemDurationSeconds"], test: .compare(comparison, seconds), label: label)
    }

    private static let kindTypes: [String: String] = [
        "image": "public.image", "images": "public.image", "photo": "public.image",
        "photos": "public.image", "picture": "public.image", "pictures": "public.image",
        "video": "public.movie", "videos": "public.movie", "movie": "public.movie",
        "movies": "public.movie", "audio": "public.audio", "music": "public.audio",
        "song": "public.audio", "songs": "public.audio", "pdf": "com.adobe.pdf",
        "pdfs": "com.adobe.pdf", "text": "public.text", "presentation": "public.presentation",
        "presentations": "public.presentation", "spreadsheet": "public.spreadsheet",
        "spreadsheets": "public.spreadsheet", "document": "public.content",
        "documents": "public.content", "doc": "public.content",
        "font": "public.font", "fonts": "public.font",
    ]

    /// "kind:pdf": files of a content type by its everyday name, or, for names the index knows ("kind:swift",
    /// "kind:folder"), its extension-based kinds, which stay useful alongside download metadata too.
    private static func kindCondition(_ value: String, token: String) -> Condition? {
        guard let type = kindTypes[value.lowercased()] else { return indexKindCondition(value, token: token) }
        let label = switch type {
        case "public.image": String(localized: "images", comment: "Search summary: kind of files")
        case "public.movie": String(localized: "videos", comment: "Search summary: kind of files")
        case "public.audio": String(localized: "audio", comment: "Search summary: kind of files")
        case "com.adobe.pdf": String(localized: "PDFs", comment: "Search summary: kind of files")
        case "public.text": String(localized: "text", comment: "Search summary: kind of files (plain text)")
        case "public.presentation": String(localized: "presentations", comment: "Search summary: kind of files")
        case "public.spreadsheet": String(localized: "spreadsheets", comment: "Search summary: kind of files")
        case "public.font": String(localized: "fonts", comment: "Search summary: kind of files")
        default: String(localized: "documents", comment: "Search summary: kind of files")
        }
        var condition = Condition(attributes: ["kMDItemContentTypeTree"], test: .anyEquals(type), label: label)
        condition.isKind = true
        return condition
    }

    private static func indexKindCondition(_ value: String, token: String) -> Condition {
        let parsed = IndexQuery.parse(token)
        var extensions = parsed.extensions
        if let kind = parsed.kind { extensions.formUnion(IndexSearch.extensions(for: kind)) }
        var condition = if parsed.kind == .folder {
            Condition(attributes: ["kMDItemContentType"], test: .equals("public.folder"), label: value)
        } else if parsed.kind == .file {
            Condition(attributes: ["kMDItemContentTypeTree"], test: .anyEquals("public.data"), label: value)
        } else {
            Condition(attributes: ["kMDItemFSName"], test: .suffixes(extensions.sorted()), label: value)
        }
        condition.isKind = true
        return condition
    }

    /// ">1920", ">=5", "<10m", "1h", "1,5" (a number, optionally with one of `units`) as a comparison.
    private static func comparison(_ text: String, units: [String: Double]) -> (Condition.Comparison, Double)? {
        var rest = Substring(text.lowercased())
        var comparison = Condition.Comparison.equal
        for candidate in [Condition.Comparison.greaterOrEqual, .lessOrEqual, .greater, .less] where rest.hasPrefix(candidate.rawValue) {
            comparison = candidate
            rest = rest.dropFirst(candidate.rawValue.count)
            break
        }
        if comparison == .equal, rest.hasPrefix("=") { rest = rest.dropFirst() }
        let digits = String(rest.prefix { $0.isNumber || $0 == "." || $0 == "," })
        // "1,920" is a thousand-separated number; "1,5" a decimal comma.
        let thousands = digits.range(of: #"^\d{1,3}(,\d{3})+$"#, options: .regularExpression) != nil
        let plain = thousands ? digits.replacingOccurrences(of: ",", with: "") : digits.replacingOccurrences(of: ",", with: ".")
        guard let number = Double(plain), number.isFinite, number >= 0 else { return nil }
        let unit = rest.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        if unit.isEmpty || unit == "px" { return (comparison, number) }
        guard let factor = units[unit], (number * factor).isFinite else { return nil }
        return (comparison, number * factor)
    }

    /// "10 min", "1 hr, 30 min", "45 sec".
    private static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 2
        if seconds.isFinite, seconds <= Double(Int.max), let formatted = formatter.string(from: seconds) {
            return formatted
        }
        return "\(saturatingInt64(seconds) ?? 0) s"
    }

    /// "over 20 pages", "at most 1000 px wide": `key` is pages, width or height.
    private static func describe(_ comparison: Condition.Comparison, _ number: Int, _ key: String) -> String {
        switch (key, comparison) {
        case ("pages", .greater): String(localized: "over \(number) pages", comment: "plural")
        case ("pages", .greaterOrEqual): String(localized: "at least \(number) pages", comment: "plural")
        case ("pages", .less): String(localized: "under \(number) pages", comment: "plural")
        case ("pages", .lessOrEqual): String(localized: "at most \(number) pages", comment: "plural")
        case ("pages", .equal): String(localized: "exactly \(number) pages", comment: "plural")
        case ("width", .greater): String(localized: "over \(number) px wide", comment: "Search summary: image width in pixels")
        case ("width", .greaterOrEqual): String(localized: "at least \(number) px wide", comment: "Search summary: image width in pixels")
        case ("width", .less): String(localized: "under \(number) px wide", comment: "Search summary: image width in pixels")
        case ("width", .lessOrEqual): String(localized: "at most \(number) px wide", comment: "Search summary: image width in pixels")
        case ("width", .equal): String(localized: "exactly \(number) px wide", comment: "Search summary: image width in pixels")
        case (_, .greater): String(localized: "over \(number) px high", comment: "Search summary: image height in pixels")
        case (_, .greaterOrEqual): String(localized: "at least \(number) px high", comment: "Search summary: image height in pixels")
        case (_, .less): String(localized: "under \(number) px high", comment: "Search summary: image height in pixels")
        case (_, .lessOrEqual): String(localized: "at most \(number) px high", comment: "Search summary: image height in pixels")
        case (_, .equal): String(localized: "exactly \(number) px high", comment: "Search summary: image height in pixels")
        }
    }

    /// Plain-English searches that mean metadata ("photos taken with iPhone", "videos longer than 10 minutes", "pdfs
    /// with more than 20 pages", "songs by Miles Davis") as the same search in syntax; nil for anything else.
    package static func naturalForm(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let quote = { (raw: String) in
            let value = raw.count > 1 && raw.hasPrefix("\"") && raw.hasSuffix("\"") ? String(raw.dropFirst().dropLast()) : raw
            return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func match(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: "^" + pattern + "$", options: [.caseInsensitive]),
                  let found = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else { return nil }
            return (0..<found.numberOfRanges).map { index in
                Range(found.range(at: index), in: trimmed).map { String(trimmed[$0]) } ?? ""
            }
        }
        if let parts = match(#"(?:files?\s+)?downloaded\s+from\s+(.+)"#) {
            return "source:" + quote(parts[1])
        }
        // "taken with" or "shot on" a camera (not "photos on desktop", "pictures by date", "taken on June 3").
        let notCameras: Set<String> = ["desktop", "date", "name", "size", "kind", "the", "this", "last", "my", "today", "yesterday",
                                       "mac", "disk", "drive", "screen", "folder"]
        let months = DateFormatter().monthSymbols.map { $0.lowercased() } + DateFormatter().shortMonthSymbols.map { $0.lowercased() }
        func isCamera(_ text: String) -> Bool {
            let first = text.lowercased().split(separator: " ").first.map(String.init) ?? ""
            return !first.isEmpty && !notCameras.contains(first) && !months.contains(first) && first.first?.isNumber != true
        }
        if let parts = match(#"(?:photos?|pictures?|images?|pics?)\s+(?:taken|shot)\s+(?:with|on|by)\s+(?:an?\s+|my\s+)?(.+)"#),
           isCamera(parts[1]) {
            return "kind:image camera:" + quote(parts[1])
        }
        if let parts = match(#"(videos?|movies?|songs?|audio|music)\s+(longer|more|over|shorter|less|under)\s+(?:than\s+)?(\d+(?:[.,]\d+)?)\s*([a-z]+)"#) {
            let kind = ["video", "videos", "movie", "movies"].contains(parts[1].lowercased()) ? "video" : "audio"
            let op = ["longer", "more", "over"].contains(parts[2].lowercased()) ? ">" : "<"
            return "kind:\(kind) duration:\(op)\(parts[3])\(parts[4].lowercased())"
        }
        if let parts = match(#"(?:pdfs?|documents?)\s+(?:with\s+)?(more|over|fewer|less|under)\s+(?:than\s+)?(\d+)\s+pages?"#) {
            let op = ["more", "over"].contains(parts[1].lowercased()) ? ">" : "<"
            return "kind:pdf pages:\(op)\(parts[2])"
        }
        let notArtists: Set<String> = ["year", "date", "name", "size", "length", "genre", "album", "artist", "kind"]
        if let parts = match(#"(?:songs?|music|tracks?|albums?)\s+by\s+(.+)"#), !notArtists.contains(parts[1].lowercased()) {
            return "kind:audio artist:" + quote(parts[1])
        }
        return nil
    }

    /// Every condition at once. Values are passed as arguments, never pasted into the format.
    package var predicate: NSPredicate {
        guard !unsupportedSourceFilters else { return NSPredicate(value: false) }
        var parts = tags.map { NSPredicate(format: "ANY %K ==[c] %@", "kMDItemUserTags", $0) }
        parts += words.map { NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, $0) }
        if !extensions.isEmpty {
            parts.append(Self.any(extensions.map { NSPredicate(format: "%K ENDSWITH[c] %@", NSMetadataItemFSNameKey, "." + $0) }))
        }
        for condition in conditions where !condition.attributes.isEmpty {
            parts.append(Self.any(condition.attributes.map { attribute in
                switch condition.test {
                case .contains(let text): NSPredicate(format: "%K CONTAINS[cd] %@", attribute, text)
                case .anyContains(let text): NSPredicate(format: "ANY %K CONTAINS[cd] %@", attribute, text)
                case .anyEquals(let text): NSPredicate(format: "ANY %K == %@", attribute, text)
                case .suffixes(let extensions):
                    Self.any(extensions.map { NSPredicate(format: "%K ENDSWITH[c] %@", attribute, "." + $0) })
                case .integer(let comparison, let number):
                    NSPredicate(format: "%K \(comparison.rawValue) %@", attribute, NSNumber(value: number))
                case .date(let comparison, let date):
                    NSPredicate(format: "%K \(comparison.rawValue) %@", attribute, date as NSDate)
                case .equals(let value): NSPredicate(format: "%K == %@", attribute, value)
                case .compare(let comparison, let number):
                    NSPredicate(format: "%K \(comparison.rawValue) %@", attribute, NSNumber(value: number))
                }
            }))
        }
        return Self.all(parts)
    }

    // NSMetadataQuery throws on a compound predicate with a single condition.
    private static func all(_ parts: [NSPredicate]) -> NSPredicate {
        parts.count == 1 ? parts[0] : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    private static func any(_ parts: [NSPredicate]) -> NSPredicate {
        parts.count == 1 ? parts[0] : NSCompoundPredicate(orPredicateWithSubpredicates: parts)
    }

    /// "Tagged “Red” · images · camera “iPhone” · named “report” · .pdf", for the results summary.
    package var summary: String {
        var parts: [String] = []
        if !tags.isEmpty {
            let list = ListFormatter.localizedString(byJoining: tags.map { "“\($0)”" })
            parts.append(String(localized: "Tagged \(list)", comment: "Search summary: with Finder tags, like “Tagged “Red” and “Work””"))
        }
        var shown = Set<String>()
        parts += conditions.map(\.label).filter { !$0.isEmpty && shown.insert($0).inserted }
        if !words.isEmpty {
            let list = ListFormatter.localizedString(byJoining: words.map { "“\($0)”" })
            parts.append(String(localized: "named \(list)", comment: "Search summary: names containing words, like “named “report””"))
        }
        if !extensions.isEmpty { parts.append(extensions.map { "." + $0 }.joined(separator: ", ")) }
        guard let first = parts.first else { return "" }
        parts[0] = first.prefix(1).uppercased() + first.dropFirst()
        return parts.joined(separator: " · ")
    }

    /// A tag as a query term, quoted and escaped so any name round-trips (`tag:"Client \"A\""`).
    package static func term(forTag name: String) -> String {
        "tag:\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Runs a Spotlight query to completion (or a time limit) and returns what it found.
package enum SpotlightSearch {
    package struct Result {
        package var urls: [URL]
        package var total: Int
        package var timedOut: Bool
    }

    /// Searches `scope`, or the whole Mac when nil. Returns at most `limit` items, with the total found.
    package static func run(_ predicate: NSPredicate, scope: URL?, limit: Int = 1000, timeout: TimeInterval = 15) async -> Result {
        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = scope.map { [$0] } ?? [NSMetadataQueryLocalComputerScope]
        let state = QueryState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.finish = { timedOut in
                    query.disableUpdates()
                    query.stop()
                    let total = query.resultCount
                    var urls: [URL] = []
                    for index in 0..<max(0, min(total, limit)) {
                        if let path = (query.result(at: index) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String,
                           !path.isEmpty {
                            urls.append(URL(fileURLWithPath: path))
                        }
                    }
                    continuation.resume(returning: Result(urls: urls, total: total, timedOut: timedOut))
                }
                state.observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                                                        object: query, queue: .main) { _ in
                    MainActor.assumeIsolated { state.complete(timedOut: false) }
                }
                if !query.start() { return state.complete(timedOut: false) }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { state.complete(timedOut: true) }
            }
        } onCancel: {
            Task { @MainActor in state.complete(timedOut: false) }
        }
    }

    /// The pieces a running query's callbacks share; it finishes exactly once.
    private final class QueryState {
        var observer: NSObjectProtocol?
        var finish: ((Bool) -> Void)?

        func complete(timedOut: Bool) {
            guard let finish else { return }
            self.finish = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            finish(timedOut)
        }
    }
}
