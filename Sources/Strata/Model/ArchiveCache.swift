import CryptoKit
import Foundation

/// Archives opened as folders. Each is extracted once (safely, see `Archiver`) into Strata's caches:
/// `Archives/<hash>/contents/…`, where the hash covers the archive's real path, identity, size and change times, so a
/// changed archive is extracted again. A `source` file next to the copy says which archive it came from (the copy's own
/// folder is always named `contents`, so no archive name can be mistaken for it).
///
/// The copy's files keep their usual permissions, so what you copy out is an ordinary file; Strata itself doesn't change
/// anything inside a copy. Copies not opened for a day, copies whose archive is gone and older copies of an archive
/// are removed, and the whole cache is kept under a size limit, least recently opened first.
package nonisolated enum ArchiveCache {
    package static let root: URL = {
        SecureStorage.caches.appending(path: "Archives", directoryHint: .isDirectory).standardizedFileURL
    }()

    private static let rootPath = root.path
    private static let copyName = "contents"
    /// Past this, the least recently opened copies go.
    package static let sizeLimit: Int64 = 10 << 30

    /// Where `archive`'s copy lives (whether or not it's been made). Nil when the archive can't be read.
    package static func folder(for archive: URL) -> URL? {
        let real = archive.resolvingSymlinksInPath()
        var info = stat()
        guard stat(real.path, &info) == 0 else { return nil }
        // Tools that keep modification dates can't fake the change time or the file's identity.
        let key = "\(real.standardizedFileURL.path)|\(info.st_dev)|\(info.st_ino)|\(info.st_size)|"
            + "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: hash, directoryHint: .isDirectory).appending(path: copyName, directoryHint: .isDirectory)
    }

    /// The finished copy of `archive`, if there is one.
    package static func existing(for archive: URL) -> URL? {
        guard let folder = folder(for: archive), source(of: folder) == archive.resolvingSymlinksInPath().standardizedFileURL,
              FileManager.default.fileExists(atPath: folder.path) else { return nil }
        return folder
    }

    /// Records where a finished copy came from, and removes older copies of the same archive.
    package static func finish(_ folder: URL, from archive: URL) throws {
        let source = archive.resolvingSymlinksInPath().standardizedFileURL
        try Data(source.path.utf8).write(to: sourceFile(folder))
        for other in copies() where other.top.standardizedFileURL != folder.standardizedFileURL && other.source == source {
            setAside(other.entry)
        }
    }

    /// Whether `url` is the cache or inside it (an archive's copy).
    package static func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    /// For a folder inside an archive's copy: the archive, and the copy's top folder.
    package static func archive(containing url: URL) -> (archive: URL, top: URL)? {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let parts = path.dropFirst(rootPath.count + 1).split(separator: "/")
        guard parts.count >= 2, parts[1] == copyName else { return nil }
        let top = root.appending(path: String(parts[0]), directoryHint: .isDirectory).appending(path: copyName, directoryHint: .isDirectory)
        guard let archive = source(of: top) else { return nil }
        return (archive, top)
    }

    /// Where an item inside an archive's copy appears to be, spelled through the archive (".../Trip.zip/Trip/Day 1"):
    /// the copy's top folder is the archive itself. Nil outside copies.
    package static func apparentURL(_ url: URL) -> URL? {
        guard let (archive, top) = archive(containing: url) else { return nil }
        let inner = url.standardizedFileURL.path.dropFirst(top.standardizedFileURL.path.count).split(separator: "/")
        return inner.reduce(archive) { $0.appending(path: String($1)) }
    }

    /// Marks a copy as just used, so pruning keeps it.
    package static func touch(_ folder: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.deletingLastPathComponent().path)
    }

    /// Removes copies not opened for `age`, copies whose archive is gone (or unfinished ones), and then the least
    /// recently opened until the cache is under `sizeLimit`. `keeping`: top folders in use (shown, being made) stay.
    package static func prune(olderThan age: TimeInterval = 24 * 60 * 60, keeping keep: Set<String> = []) {
        var survivors: [(entry: URL, used: Date, size: Int64)] = []
        for copy in copies() {
            if keep.contains(copy.top.standardizedFileURL.path) { continue }
            // Read fresh: an open in another window may have just marked it used.
            let used = (try? URL(fileURLWithPath: copy.entry.path).resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let idle = Date().timeIntervalSince(used)
            // Unfinished copies (no source yet) are only left alone while they could still be being made.
            let sourceGone = copy.source.map { !FileManager.default.fileExists(atPath: $0.path) } ?? (idle > 60 * 60)
            if idle > age || sourceGone {
                remove(copy.entry)
            } else {
                survivors.append((copy.entry, used, size(of: copy.entry)))
            }
        }
        var total = survivors.map(\.size).saturatingSum
        for copy in survivors.sorted(by: { $0.used < $1.used }) where total > sizeLimit {
            remove(copy.entry)
            total = max(0, total - copy.size)
        }
    }

    /// Removes a copy's `<hash>` folder (made writable and cleared first, whatever the archive set). Never the cache
    /// itself or anything outside it.
    package static func remove(_ entry: URL) {
        let path = entry.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/"), !path.dropFirst(rootPath.count + 1).contains("/") else { return }
        Archiver.removeTree(entry)
    }

    /// `remove` for the main thread: the copy's `<hash>` folder leaves its place at once (one rename, however big the
    /// copy) and is removed away from the main thread. One left by a quit goes at the next prune, as an unfinished
    /// copy. Returns where it was set aside; nil when it wasn't a whole copy of the cache, or wasn't there.
    @discardableResult
    package static func setAside(_ entry: URL) -> URL? {
        let path = entry.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/"), !path.dropFirst(rootPath.count + 1).contains("/") else { return nil }
        let aside = root.appending(path: "removing-" + UUID().uuidString, directoryHint: .isDirectory)
        guard renamex_np(path, aside.path, UInt32(RENAME_EXCL)) == 0 else { return nil }
        DispatchQueue.global(qos: .utility).async { remove(aside) }
        return aside
    }

    // MARK: - Private

    private static func sourceFile(_ folder: URL) -> URL {
        folder.deletingLastPathComponent().appending(path: "source")
    }

    private static func source(of folder: URL) -> URL? {
        guard let data = try? Data(contentsOf: sourceFile(folder)), data.count < 4096,
              let path = String(data: data, encoding: .utf8), path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // An archive is never inside the cache's own bookkeeping folder.
        return url.path == rootPath ? nil : url
    }

    /// Every copy: its `<hash>` folder, its top folder, and the archive it came from (nil when unfinished).
    private static func copies() -> [(entry: URL, top: URL, source: URL?)] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries.map { entry in
            let top = entry.appending(path: copyName, directoryHint: .isDirectory)
            return (entry, top, source(of: top))
        }
    }

    private static func size(of folder: URL) -> Int64 {
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [])
        while let url = walker?.nextObject() as? URL {
            total = [total, Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)].saturatingSum
        }
        return total
    }
}
