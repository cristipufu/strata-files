import AppKit

/// A Finder tag: a name and one of Finder's colors.
nonisolated struct FinderTag: Hashable, Sendable {
    let name: String
    /// Finder's color number: 0 none, 1 gray, 2 green, 3 purple, 4 blue, 5 yellow, 6 red, 7 orange.
    let color: Int

    /// The seven colored tags, in Finder's menu order (red to gray), named as the system names them.
    @MainActor static var standard: [FinderTag] {
        let names = NSWorkspace.shared.fileLabels
        return [6, 7, 5, 2, 4, 3, 1].compactMap { color in
            color < names.count ? FinderTag(name: names[color], color: color) : nil
        }
    }

    var displayColor: NSColor? {
        switch color {
        case 1: .systemGray
        case 2: .systemGreen
        case 3: .systemPurple
        case 4: .systemBlue
        case 5: .systemYellow
        case 6: .systemRed
        case 7: .systemOrange
        default: nil
        }
    }
}

extension Notification.Name {
    /// Posted (object: the URLs whose tags changed) after Strata changes tags.
    static let tagsChanged = Notification.Name("StrataTagsChanged")
    /// Posted when a folder's tags have been read, for cells to show them.
    static let tagsLoaded = Notification.Name("StrataTagsLoaded")
}

/// Finder tags: read and written through the extended attribute Finder keeps them in (so Finder,
/// Spotlight and the old color labels agree) with each tag's own color kept. Reads are cached per item, since every
/// visible cell asks; a folder's tags are read off the main thread when it loads, and changes are always worked out from
/// what's on disk now, never from the cache.
final class TagStore {
    static let shared = TagStore()

    nonisolated private static let attribute = "com.apple.metadata:_kMDItemUserTags"
    /// Tag lists past these limits are someone else's doing: only the first tags are read.
    nonisolated private static let maxAttributeSize = 64 << 10
    nonisolated private static let maxTags = 100
    private var cache: [String: [FinderTag]] = [:]
    private var stale: Set<String> = []
    private static let recentKey = "recentTags"

    struct Failure: LocalizedError {
        let failures: [(url: URL, error: Error)]
        var errorDescription: String? {
            failures.count == 1
                ? String(localized: "The tags of “\(failures[0].url.lastPathComponent)” couldn’t be changed.")
                : String(localized: "The tags of \(failures.count) items couldn’t be changed.", comment: "plural")
        }
        var failureReason: String? {
            String(localized: "They’re locked, or you don’t have permission to change them.", comment: "Why tags couldn’t be changed")
        }
    }

    /// Folders whose tags are being read in the background: keep their last known values until then, rather than
    /// each cell reading on the main thread (slow on network disks).
    private var loading: Set<String> = []

    /// Last known tags only: sorting must never read extended attributes inside its comparator.
    func cachedTags(for url: URL) -> [FinderTag] { cache[url.standardizedFileURL.path] ?? [] }

    /// `url`'s tags, in the order they were added.
    func tags(for url: URL) -> [FinderTag] {
        let path = url.standardizedFileURL.path
        if let cached = cache[path], !stale.contains(path) { return cached }
        if loading.contains(url.deletingLastPathComponent().standardizedFileURL.path) { return cache[path] ?? [] }
        if cache.count > 20_000 { cache.removeAll(keepingCapacity: true); stale.removeAll(keepingCapacity: true) }
        let tags = Self.read(path, labels: NSWorkspace.shared.fileLabels)
        cache[path] = tags
        stale.remove(path)
        return tags
    }

    /// Reads the tags of a folder's items off the main thread, then shows them (cells redraw on `.tagsChanged`).
    @discardableResult
    func load(_ entries: [FileEntry], in folder: URL? = nil) -> Task<Void, Never> {
        let folders = folder.map { Set([$0.standardizedFileURL.path]) }
            ?? Set(entries.map { $0.url.deletingLastPathComponent().standardizedFileURL.path })
        loading.formUnion(folders)
        let paths = entries.map { $0.url.standardizedFileURL.path }
        let labels = NSWorkspace.shared.fileLabels
        return Task {
            let tags = await Self.readAll(paths, labels: labels)
            for (path, list) in tags { cache[path] = list; stale.remove(path) }
            loading.subtract(folders)
            NotificationCenter.default.post(name: .tagsLoaded, object: nil)
        }
    }

    @concurrent
    private static func readAll(_ paths: [String], labels: [String]) async -> [String: [FinderTag]] {
        var result: [String: [FinderTag]] = [:]
        result.reserveCapacity(paths.count)
        for path in paths { result[path] = read(path, labels: labels) }
        return result
    }

    /// Marks a folder's tags for rereading. Keep their last known values for sorting and background reads: browsing
    /// an ancestor in another window must not temporarily turn every descendant into an untagged item.
    func invalidate(_ folder: URL?) {
        guard let folder else { cache.removeAll(); stale.removeAll(); return }
        let path = folder.standardizedFileURL.path
        let prefix = path == "/" ? "/" : path + "/"
        stale.formUnion(cache.keys.filter { $0.hasPrefix(prefix) })
    }

    /// Whether a listed item can carry tags from Strata, by what its listing says: for showing tag controls without
    /// reading the disk again. Tagging itself checks `canTag(_: URL)` as it writes.
    nonisolated static func canTag(_ entry: FileEntry) -> Bool {
        !entry.isSymlink && !ReadOnlyCopies.contains(entry.url)
    }

    /// Whether `url` can carry tags from Strata: not a link (its target's tags would change instead), and not inside an
    /// archive opened as a folder (a temporary copy).
    nonisolated static func canTag(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT != S_IFLNK && !ReadOnlyCopies.contains(url)
    }

    /// Adds `tag` to every item, or removes it from all of them when they all have it already (Finder's colored circles).
    func toggle(_ tag: FinderTag, on urls: [URL], undo: UndoManager?) throws {
        let current = urls.filter(Self.canTag).map { (url: $0, tags: onDisk($0)) }
        let everyHas = current.allSatisfy { $0.tags.contains { $0.name.caseInsensitiveCompare(tag.name) == .orderedSame } }
        try apply(current.map { item in
            var tags = item.tags.filter { $0.name.caseInsensitiveCompare(tag.name) != .orderedSame }
            if !everyHas { tags.append(tag) }
            return (item.url, tags)
        }, undo: undo, added: everyHas ? [] : [tag.name])
    }

    /// Adds `adding` to every item and removes `removing` (lowercased names) from each, keeping their other tags.
    func update(_ urls: [URL], adding: [String], removing: Set<String>, undo: UndoManager?) throws {
        let added = adding.map(Self.clean).filter { !$0.isEmpty }
        try apply(urls.filter(Self.canTag).map { url in
            var tags = onDisk(url).filter { !removing.contains($0.name.lowercased()) }
            for name in added where !tags.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                tags.append(FinderTag(name: name, color: Self.color(forNew: name)))
            }
            return (url, tags)
        }, undo: undo, added: added)
    }

    /// Tags to suggest: the seven colored ones, then others you've added here, most recent first.
    var suggestions: [FinderTag] {
        let standard = FinderTag.standard
        let standardNames = Set(standard.map { $0.name.lowercased() })
        let recent = (Prefs.shared.defaults.stringArray(forKey: Self.recentKey) ?? [])
            .filter { !standardNames.contains($0.lowercased()) }
            .map { FinderTag(name: $0, color: 0) }
        return standard + recent
    }

    /// Takes a tag out of the suggestions (and the sidebar). The colored ones always stay.
    func forget(_ name: String) {
        var recent = Prefs.shared.defaults.stringArray(forKey: Self.recentKey) ?? []
        recent.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        Prefs.shared.defaults.set(recent, forKey: Self.recentKey)
        NotificationCenter.default.post(name: .tagsChanged, object: [URL]())
    }

    // MARK: - Private

    /// The item's tags as they are on disk now (bypassing the cache: Finder may have changed them).
    private func onDisk(_ url: URL) -> [FinderTag] {
        Self.read(url.standardizedFileURL.path, labels: NSWorkspace.shared.fileLabels)
    }

    /// Writes each item's tags, going on past failures (reported together at the end). Links are skipped.
    private func apply(_ changes: [(URL, [FinderTag])], undo: UndoManager?, added: [String]) throws {
        var previous: [(url: URL, identity: FileIdentity?, tags: [FinderTag])] = []
        var changed: [URL] = []
        var failures: [(url: URL, error: Error)] = []
        let labels = NSWorkspace.shared.fileLabels
        for (url, tags) in changes {
            let path = url.standardizedFileURL.path
            guard Self.canTag(url) else { continue }
            guard let chosen = try? ChosenFile(url) else {
                failures.append((url, POSIXError(.ESTALE)))
                continue
            }
            // Duplicates and empty names are dropped; the first spelling wins.
            var seen = Set<String>()
            let wanted = tags.compactMap { tag -> FinderTag? in
                let name = Self.clean(tag.name)
                guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
                return FinderTag(name: name, color: tag.color)
            }
            do {
                let previousTags = try chosen.withDescriptor { fd, info -> [FinderTag]? in
                    guard info.st_mode & S_IFMT != S_IFLNK else { throw CocoaError(.fileWriteUnsupportedScheme) }
                    let before = Self.read(fd, labels: labels)
                    guard wanted != before else { return nil }
                    try Self.write(wanted, to: fd)
                    return before
                }
                guard let previousTags else { continue }
                cache[path] = nil
                stale.remove(path)
                previous.append((url, chosen.identity, previousTags))
                changed.append(url)
            } catch {
                failures.append((url, error))
            }
        }
        if !changed.isEmpty {
            registerUndo(previous, undo: undo)
            remember(added)
            NotificationCenter.default.post(name: .tagsChanged, object: changed)
        }
        if !failures.isEmpty { throw Failure(failures: failures) }
    }

    private func registerUndo(_ previous: [(url: URL, identity: FileIdentity?, tags: [FinderTag])], undo: UndoManager?) {
        guard let undo else { return }
        undo.registerUndo(withTarget: undo) { [weak self] undo in
            MainActor.assumeIsolated {
                guard let self else { return }
                let valid = previous.compactMap { item -> (URL, [FinderTag])? in
                    guard let identity = item.identity, FileIdentity.read(item.url.standardizedFileURL.path) == identity else { return nil }
                    return (item.url, item.tags)
                }
                try? self.apply(valid, undo: undo, added: [])
            }
        }
        undo.setActionName(String(localized: "Tags", comment: "Undo action name: changing Finder tags"))
    }

    /// Names you added here, for suggestions and the sidebar (only those you chose, most recent first).
    private func remember(_ names: [String]) {
        guard !names.isEmpty else { return }
        var recent = Prefs.shared.defaults.stringArray(forKey: Self.recentKey) ?? []
        for name in names.reversed() {
            recent.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
            recent.insert(name, at: 0)
        }
        Prefs.shared.defaults.set(Array(recent.prefix(30)), forKey: Self.recentKey)
    }

    /// A new tag's color: one of the colored tags by name, else none.
    private static func color(forNew name: String) -> Int {
        FinderTag.standard.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.color ?? 0
    }

    /// One line, trimmed: a tag name can't hold line breaks (they'd be read back as a color).
    nonisolated static func clean(_ name: String) -> String {
        name.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Reads the tag attribute without following a symlink: a binary property list of "Name\nColor" strings.
    /// `labels` is the system's list of colored tag names (passed in, so this can run off the main thread).
    nonisolated static func read(_ path: String, labels: [String]) -> [FinderTag] {
        let size = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size <= maxAttributeSize else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read > 0 else { return [] }
        return parse(data.prefix(read), labels: labels)
    }

    nonisolated private static func read(_ fd: Int32, labels: [String]) -> [FinderTag] {
        let size = fgetxattr(fd, attribute, nil, 0, 0, 0)
        guard size > 0, size <= maxAttributeSize else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { fgetxattr(fd, attribute, $0.baseAddress, size, 0, 0) }
        guard read > 0 else { return [] }
        return parse(data.prefix(read), labels: labels)
    }

    nonisolated static func parse(_ data: Data, labels: [String]) -> [FinderTag] {
        guard BinaryPropertyListBudget.permitsDecoding(data) else { return [] }
        guard let strings = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] else { return [] }
        var seen = Set<String>()
        var tags: [FinderTag] = []
        for entry in strings {
            guard tags.count < maxTags else { break }
            // "Name\n6": the color follows the last line break, when it's one of Finder's color numbers.
            var name = entry
            var color: Int?
            if let split = entry.lastIndex(of: "\n"), let number = Int(entry[entry.index(after: split)...]), (0...7).contains(number) {
                name = String(entry[..<split])
                color = number
            }
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            // No color recorded: the colored tags are known by name.
            tags.append(FinderTag(name: name, color: color ?? labels.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame } ?? 0))
        }
        return tags
    }

    /// Writes "Name\nColor" strings directly (never through a link), to keep colors the system wouldn't know.
    nonisolated private static func write(_ tags: [FinderTag], to fd: Int32) throws {
        let strings = tags.map { "\($0.name)\n\($0.color)" }
        let data = try PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0)
        let result = data.withUnsafeBytes { fsetxattr(fd, attribute, $0.baseAddress, data.count, 0, 0) }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
