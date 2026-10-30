import Foundation

/// `github/acme`-style lookups for the palette: each `/`-separated part fuzzy-matches one folder name, in order.
///
/// Two sources: visited folders match with gaps (`docs/strata` finds ~/Documents/GitHub/strata), and from every root
/// (or folder directly inside one) whose name matches the first part, the rest walks down the tree, so never-opened
/// folders are found too.
/// A trailing `/` lists everything inside the matched folder.
nonisolated final class PathQuery {
    struct Hit: Sendable {
        let url: URL
        let isFolder: Bool
        let score: Int
        /// Matched character offsets in the item's name, for highlighting.
        let nameMatches: [Int]
    }

    private var listings: [URL: [(url: URL, isFolder: Bool)]] = [:]
    /// Set once the lookup's been replaced: it reads no more folders.
    private let stop: CancelFlag?

    init(stop: CancelFlag? = nil) {
        self.stop = stop
    }

    /// Runs `work` (file system reads) on a thread of its own, never the main thread or the threads Swift and Dispatch
    /// share: a read stuck on a server that stopped answering holds only that thread, and no lookup after it waits.
    static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: work()) }
            thread.name = "dev.strata.path-query"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// `resolve` away from the main thread, with a fresh cache: listings it reads are its own. Replaced (the task's
    /// cancelled), it stops reading folders.
    static func resolveOffMain(_ query: String, roots: [URL], visited: [URL]) async -> [Hit] {
        let stop = CancelFlag()
        return await withTaskCancellationHandler {
            await offMain { PathQuery(stop: stop).resolve(query, roots: roots, visited: visited) }
        } onCancel: {
            stop.set()
        }
    }

    static func isPathQuery(_ query: String) -> Bool {
        query.contains("/") && !query.hasPrefix("/") && !query.hasPrefix("~")
    }

    func resolve(_ query: String, roots: [URL], visited: [URL]) -> [Hit] {
        var segments = query.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let wildcard = segments.last == ""
        segments = segments.filter { !$0.isEmpty }
        if wildcard { segments.append("") }
        guard segments.count >= 2 else { return [] }

        var hits: [URL: Hit] = [:]
        func keep(_ hit: Hit) {
            if hits[hit.url].map({ $0.score < hit.score }) ?? true { hits[hit.url] = hit }
        }

        for (rank, url) in visited.enumerated() {
            if let match = matchWithGaps(segments, url) {
                keep(Hit(url: url, isFolder: true, score: match.score + max(0, 24 - rank / 2), nameMatches: match.indices))
            }
        }

        var seenRoots = Set<URL>()
        var starts: [(url: URL, score: Int)] = []
        for url in roots where seenRoots.insert(url.standardizedFileURL).inserted {
            if let match = Self.score(segments[0], url.lastPathComponent) { starts.append((url, match.score)) }
        }
        // The first part may also name a folder one level inside the first few roots (`strata/` inside GitHub).
        for root in roots.prefix(12) {
            for child in children(of: root, includeFiles: false, includeHidden: false) {
                if let match = Self.score(segments[0], child.url.lastPathComponent) { starts.append((child.url, match.score - 5)) }
            }
        }
        starts.sort { $0.score > $1.score }
        var frontier = Array(starts.prefix(6))
        for (level, segment) in segments.enumerated().dropFirst() {
            let isLast = level == segments.count - 1
            var next: [(url: URL, isFolder: Bool, score: Int, matches: [Int])] = []
            for base in frontier {
                for child in children(of: base.url, includeFiles: isLast, includeHidden: segment.hasPrefix(".")) {
                    if segment.isEmpty {
                        next.append((child.url, child.isFolder, base.score, []))
                    } else if let match = Self.score(segment, child.url.lastPathComponent) {
                        next.append((child.url, child.isFolder, base.score + match.score, match.indices))
                    }
                }
            }
            next.sort { $0.score != $1.score ? $0.score > $1.score : $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
            if isLast {
                for hit in next.prefix(60) {
                    keep(Hit(url: hit.url, isFolder: hit.isFolder, score: hit.score, nameMatches: hit.matches))
                }
            } else {
                frontier = next.filter(\.isFolder).prefix(8).map { ($0.url, $0.score) }
            }
        }
        return Array(hits.values.sorted { $0.score > $1.score }.prefix(60))
    }

    /// The last part must match the folder's own name; earlier parts match ancestors right to left, gaps allowed.
    private func matchWithGaps(_ segments: [String], _ url: URL) -> Fuzzy.Match? {
        guard let last = segments.last, !last.isEmpty else { return nil }
        let components = Array(url.standardizedFileURL.pathComponents.dropFirst())
        guard let name = components.last, let nameMatch = Self.score(last, name) else { return nil }
        var total = nameMatch.score
        var index = components.count - 2
        for segment in segments.dropLast().reversed() {
            var found = false
            while index >= 0 {
                let component = components[index]
                index -= 1
                if let match = Self.score(segment, component) {
                    total += match.score
                    found = true
                    break
                }
                total -= 2
            }
            if !found { return nil }
        }
        return Fuzzy.Match(score: total, indices: nameMatch.indices)
    }

    private static func score(_ segment: String, _ name: String) -> Fuzzy.Match? {
        guard let match = Fuzzy.match(segment, name) else { return nil }
        let exact = segment.caseInsensitiveCompare(name) == .orderedSame
        return exact ? Fuzzy.Match(score: match.score + 20, indices: match.indices) : match
    }

    private func children(of folder: URL, includeFiles: Bool, includeHidden: Bool) -> [(url: URL, isFolder: Bool)] {
        let all: [(url: URL, isFolder: Bool)]
        if let cached = listings[folder] {
            all = cached
        } else if stop?.isSet == true {
            return []
        } else {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
            all = urls.prefix(5000).map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return (url, values?.isDirectory == true && values?.isPackage != true)
            }
            listings[folder] = all
        }
        return all.filter { (includeFiles || $0.isFolder) && (includeHidden || !$0.url.lastPathComponent.hasPrefix(".")) }
    }
}
