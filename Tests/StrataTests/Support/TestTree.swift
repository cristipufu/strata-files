import Foundation
@testable import Strata

/// A folder of files made for one test and removed after it. `snapshot` lists everything in it (links as links, never
/// followed), so a test can check that an operation changed what it was meant to and nothing else.
///
/// Items are written as relative paths: `"a/"` is a folder, `"a/b.txt"` a file holding its own path, and
/// `"name -> target"` a symbolic link (to `target` in the tree; one starting with "/" or "." is written as is).
final class TestTree {
    /// Spelled the way folder listings spell it (the temporary folder is reached through `/var`, a link).
    let root: URL

    convenience init(_ items: String...) throws {
        try self.init(items)
    }

    init(_ items: [String]) throws {
        let made = FileManager.default.temporaryDirectory.appending(path: "strata-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        guard let real = realpath(made.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        root = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        free(real)
        try add(items)
    }

    deinit {
        // Whatever a test locked (read-only folders, immutable files) must still go.
        if let paths = FileManager.default.enumerator(atPath: root.path) {
            for case let path as String in paths {
                let full = root.appending(path: path).path
                chflags(full, 0)
                var info = stat()
                if lstat(full, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { chmod(full, 0o755) }
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ path: String) -> URL { root.appending(path: path) }

    func add(_ items: [String]) throws {
        let fm = FileManager.default
        for item in items {
            if let arrow = item.range(of: " -> ") {
                let link = url(String(item[..<arrow.lowerBound]))
                let target = String(item[arrow.upperBound...])
                try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                let raw = target.hasPrefix("/") || target.hasPrefix(".")
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: raw ? target : url(target).path)
            } else if item.hasSuffix("/") {
                try fm.createDirectory(at: url(item), withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: url(item).deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(item.utf8).write(to: url(item))
            }
        }
    }

    /// Every item, sorted: folders end in "/", links read "name -> target" (the target relative to the tree when it's
    /// inside it).
    func snapshot() -> [String] { Self.listing(of: root) }

    /// `snapshot` for any folder (a test server's, say). Files named "._…" are listed too, which FileManager leaves out.
    static func listing(of root: URL) -> [String] {
        var items: [String] = []
        func walk(_ folder: String) {
            for name in names(in: root.appending(path: folder).path) {
                let relative = folder.isEmpty ? name : folder + "/" + name
                let full = root.appending(path: relative).path
                var info = stat()
                guard lstat(full, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFLNK:
                    let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: full)) ?? "?"
                    let shown = target.hasPrefix(root.path + "/") ? String(target.dropFirst(root.path.count + 1)) : target
                    items.append("\(relative) -> \(shown)")
                case S_IFDIR:
                    items.append(relative + "/")
                    walk(relative)
                default:
                    items.append(relative)
                }
            }
        }
        walk("")
        return items.sorted()
    }

    static func path(of fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    /// Read from the folder itself, not through FileManager, which leaves out files named "._…". A directory record is
    /// only as long as its name: `DirectoryEntryName` reads it within that length. A name that isn't text shows as a
    /// marker, so a whole listing still has something there.
    private static func names(in folder: String) -> [String] {
        guard let stream = opendir(folder) else { return [] }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = DirectoryEntryName.read(entry) ?? "<a name that isn't text>"
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    /// Takes back out of your Trash exactly what this tree's items were moved to it as (History, a test run's own, has
    /// where each went; replaced items too).
    func removeFromTrash() {
        let prefix = root.path + "/"
        for entry in OperationLog.shared.entries {
            for pair in entry.pairs + entry.replaced where pair[0].hasPrefix(prefix) {
                let trashed = URL(fileURLWithPath: pair[1])
                Self.removeFromTrash(trashed, matching: entry.identities[pair[1]])
            }
        }
    }

    /// Restoring an item frees its old Trash name for another test. Cleanup must still identify our own file.
    static func removeFromTrash(_ url: URL, matching identity: String?) {
        guard Trash.isInTrash(url), let identity, OperationLog.identity(url.path) == identity else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// What a file says (each file starts out holding its own path).
    func text(_ path: String) -> String? {
        try? String(contentsOf: url(path), encoding: .utf8)
    }
}
