import AppKit

/// What drop checks ask the disk while a drag moves (where items really are, which disk, whether a folder opens or is
/// a package), read away from the main thread once per drag: views ask on every move of the pointer, and on a server
/// each answer is a round trip. Until a fact is read, the checks go by what the paths say; the drop itself waits for
/// what it asks (`FileDrop.decided`).
final class DragFacts {
    nonisolated struct Fact: Sendable {
        let realPath: String
        let device: dev_t?
        let opens: Bool
        let isPackage: Bool
        /// A folder itself, not a link to one.
        let isFolder: Bool
    }

    private static var current: DragFacts?

    /// The facts of the drag `info` belongs to; a new drag starts afresh.
    static func of(_ info: NSDraggingInfo) -> DragFacts {
        if let current, current.sequence == info.draggingSequenceNumber { return current }
        let facts = DragFacts(sequence: info.draggingSequenceNumber, read: DragFacts.read)
        current = facts
        return facts
    }

    private let sequence: Int
    private var facts: [String: Fact] = [:]
    private var reads: BatchedReads<Fact>!
    /// Asked about and not yet known, since `answer` began.
    private var unknown: Set<String> = []

    init(sequence: Int, read: @escaping @Sendable ([String]) -> [String: Fact]) {
        self.sequence = sequence
        reads = BatchedReads(read: read) { [weak self] found in self?.facts.merge(found) { _, new in new } }
    }

    /// What's known of `path`; nil until it's been read (it's asked for).
    func fact(_ path: String) -> Fact? {
        if let fact = facts[path] { return fact }
        unknown.insert(path)
        reads.request(path)
        return nil
    }

    func settled() async {
        await reads.settled()
    }

    /// `body`'s answer from what's known, and the paths it asked about that aren't (they're being read).
    func answer<T>(_ body: (DragFacts) -> T) -> (value: T, unknown: Set<String>) {
        unknown = []
        let value = body(self)
        return (value, unknown)
    }

    /// Returns once `paths` have been read; the drag's other reads may still be going.
    func read(_ paths: Set<String>) async {
        await reads.settled(paths)
    }

    func isInside(_ urls: [URL], _ target: URL) -> Bool {
        let parents = Set(urls.map { $0.deletingLastPathComponent().path })
        let real = parents.reduce(into: [String: String]()) { found, parent in found[parent] = fact(parent)?.realPath }
        guard let resolved = fact(target.path)?.realPath, real.count == parents.count else {
            return FileDrop.isInside(urls.map(\.standardized.path), target.standardized.path)
        }
        let items = urls.compactMap { url in
            real[url.deletingLastPathComponent().path].map { ($0 as NSString).appendingPathComponent(url.lastPathComponent) }
        }
        return FileDrop.isInside(items, resolved)
    }

    func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let first = fact(a.path), second = fact(b.path)
        guard let first, let second else {
            return DiskOfPath.volume(of: a.standardized.path) == DiskOfPath.volume(of: b.standardized.path)
        }
        return first.device != nil && first.device == second.device
    }

    /// Whether `folder` can be read into; not until that's known.
    func opens(_ folder: URL) -> Bool { fact(folder.path)?.opens == true }

    /// Whether `folder` is a package (an app); taken to be one until that's known.
    func isPackage(_ folder: URL) -> Bool { fact(folder.path)?.isPackage != false }

    /// Whether `url` is a folder that isn't a package or a link; not until that's known.
    func isPlainFolder(_ url: URL) -> Bool { fact(url.path).map { $0.isFolder && !$0.isPackage } ?? false }

    nonisolated static func read(_ paths: [String]) -> [String: Fact] {
        var facts: [String: Fact] = [:]
        for path in paths {
            let url = URL(fileURLWithPath: path)
            var info = stat()
            facts[path] = Fact(realPath: RealPath.of(path), device: TransferEngine.device(url),
                               opens: access(path, R_OK | X_OK) == 0,
                               isPackage: (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true,
                               isFolder: lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR)
        }
        return facts
    }
}
