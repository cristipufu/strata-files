import CryptoKit
import Darwin
import Foundation
import Synchronization

/// Which container a copy is of, and how to reach its engine.
package nonisolated struct ContainerSource: Codable, Sendable, Equatable {
    package let socket: String
    package let apiVersion: String
    package let engineName: String
    package let id: String
    package let name: String

    package var engine: ContainerEngine { ContainerEngine(socket: socket, name: engineName, apiVersion: apiVersion) }
}

/// An engine, as recorded on its Containers folder.
package nonisolated struct EngineRecord: Codable, Sendable, Equatable {
    package let socket: String
    package let apiVersion: String
    package let name: String

    package init(_ engine: ContainerEngine) {
        socket = engine.socket
        apiVersion = engine.apiVersion
        name = engine.name
    }

    package var engine: ContainerEngine { ContainerEngine(socket: socket, name: name, apiVersion: apiVersion) }
}

/// Container files, browsed as read-only copies in Strata's caches. `Containers/<engine>/` is the Containers folder.
/// A Compose project's containers live in a folder named after the project; every other container is a folder of its
/// own beside those. Each container folder is that container's `/`, filled in folder by folder as you browse (see
/// `ContainerFiles`). Which engine and container a folder is of is kept in an extended attribute on it, so nothing but
/// the container's own files shows inside.
///
/// Like an archive's copy (see `ArchiveCache`), nothing in it is changed from Strata; it only ever reads the container.
/// A file not fetched yet is a *placeholder*: the right size and date, but no permissions at all, so nothing can read
/// zeros from it by mistake. Links are rewritten to point inside the copy: an absolute link in a container means a path
/// in that container, never one on this Mac. Everything is removed when Strata quits.
package nonisolated final class ContainerCopyStore: Sendable {
    package let root: URL
    private let rootPath: String
    private let sources = Mutex<[String: ContainerSource]>([:])
    private let engines = Mutex<[String: EngineRecord]>([:])

    package static let shared = ContainerCopyStore(
        root: SecureStorage.Context.shared.caches.appending(path: "Containers.noindex", directoryHint: .isDirectory))

    package init(root: URL) {
        let resolved = Self.rootURL(root)
        self.root = resolved
        self.rootPath = resolved.path
    }

    /// Foundation standardizes system aliases such as /private/var only when their path exists. Normalize an
    /// existing ancestor first so creating the cache cannot change its identity.
    private static func rootURL(_ root: URL) -> URL {
        let root = root.standardizedFileURL
        guard root.isFileURL, root.path.hasPrefix("/"), root.path != "/" else { return root }
        var parent = root.deletingLastPathComponent(), missing = [root.lastPathComponent]
        while parent.path != "/", !FileManager.default.fileExists(atPath: parent.path) {
            missing.append(parent.lastPathComponent)
            parent.deleteLastPathComponent()
        }
        return missing.reversed().reduce(parent.standardizedFileURL) { $0.appending(path: $1, directoryHint: .isDirectory) }
    }

    /// The engine's Containers folder, made if needed.
    package func prepare(_ engine: ContainerEngine) throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: rootPath) {
            // Spotlight has no business indexing other machines' files (`.noindex` keeps it out).
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let folder = root.appending(path: ContainerCopies.engineKey(engine.socket), directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let record = EngineRecord(engine)
        try ContainerCopies.setAttribute(ContainerCopies.engineAttribute, record, on: folder)
        engines.withLock { $0[folder.path] = record }
        return folder
    }

    /// A container's folder (its `/`), made if needed. One from a Compose project is made inside that project's folder.
    package func prepare(_ container: ContainerInfo, on engine: ContainerEngine) throws -> URL {
        guard ContainerCopies.isContainerName(container.name) else { throw CocoaError(.fileWriteInvalidFileName) }
        let parent = try stackFolder(for: container, in: prepare(engine))
        let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        try record(container, on: engine, in: fd, folder: parent)
        return parent.appending(path: container.name, directoryHint: .isDirectory)
    }

    /// Where `container`'s folder goes: its Compose project's folder, or the engine's folder when it isn't in one.
    /// The project folder is made if needed. When a container's folder already has the project's name (a container on
    /// its own, called that), it stays beside the stacks, as `CopyWriter.syncContainers` places it: never inside that
    /// container's files.
    package func stackFolder(for container: ContainerInfo, in engineFolder: URL) throws -> URL {
        guard let name = ContainerCopies.stackName(container) else { return engineFolder }
        let fd = open(engineFolder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let taken = ContainerCopies.recordedSource(name, in: fd) != nil
        close(fd)
        if taken { return engineFolder }
        let stack = engineFolder.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stack, withIntermediateDirectories: true)
        return stack
    }

    /// Makes (or keeps) the folder for `container` in the Containers folder open at `fd`, recording its source and
    /// giving it the container's date.
    package func record(_ container: ContainerInfo, on engine: ContainerEngine, in fd: Int32, folder: URL) throws {
        let name = container.name
        guard ContainerCopies.isContainerName(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT != S_IFDIR { CopyWriter.removeAt(fd, name) }
        mkdirat(fd, name, 0o755)
        // Two containers whose names differ only in case can't both have a folder on this disk: the first keeps it.
        guard CopyWriter.names(in: fd).contains(name) else { throw CocoaError(.fileWriteFileExists) }
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(child) }
        try CopyWriter.markDownloaded(child)
        let source = ContainerSource(socket: engine.socket, apiVersion: engine.apiVersion, engineName: engine.name,
                                     id: container.id, name: name)
        let data = try JSONEncoder().encode(source)
        let attribute = ContainerCopies.sourceAttribute
        guard data.withUnsafeBytes({ fsetxattr(child, attribute, $0.baseAddress, $0.count, 0, 0) }) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        CopyWriter.remember(container.created, onFolder: child)
        sources.withLock { $0[folder.appending(path: name).standardizedFileURL.path] = source }
    }

    /// Whether `url` is the cache or inside it.
    package func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    /// For an engine's Containers folder itself: the engine.
    package func engineFolder(_ url: URL) -> ContainerEngine? {
        guard let parts = components(url), parts.count == 1 else { return nil }
        return engineRecord(root.appending(path: parts[0], directoryHint: .isDirectory))?.engine
    }

    /// The Containers folder `url` is in or is (nil outside them).
    package func containersFolder(of url: URL) -> URL? {
        guard let first = components(url)?.first else { return nil }
        return root.appending(path: first, directoryHint: .isDirectory)
    }

    /// For a path inside a container's folder: which container it's of, and its top folder (the container's `/`).
    /// A container sits in the engine's folder, or one level down inside its Compose project.
    package func copy(containing url: URL) -> (source: ContainerSource, top: URL)? {
        guard let parts = components(url), parts.count >= 2 else { return nil }
        for depth in [2, 3] where depth <= parts.count {
            let top = parts.prefix(depth).reduce(root) { $0.appending(path: $1, directoryHint: .isDirectory) }
            if let source = source(of: top) { return (source, top) }
        }
        return nil
    }

    /// Whether `url` is a container's top folder.
    package func isContainerTop(_ url: URL) -> Bool {
        guard let parts = components(url), (2...3).contains(parts.count) else { return false }
        return source(of: url) != nil
    }

    /// A Compose project's folder: directly in the engine's folder, and not a container itself.
    package func isStack(_ url: URL) -> Bool {
        guard components(url)?.count == 2, engineFolder(url.deletingLastPathComponent()) != nil else { return false }
        return source(of: url) == nil
    }

    private func components(_ url: URL) -> [String]? {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let parts = path.dropFirst(rootPath.count + 1).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first, !first.hasPrefix(".") else { return nil }
        return parts
    }

    private func source(of top: URL) -> ContainerSource? {
        let path = top.standardizedFileURL.path
        if let known = sources.withLock({ $0[path] }) { return known }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let attribute = ContainerCopies.sourceAttribute
        guard let source = ContainerCopies.readAttribute(attribute, ContainerSource.self, from: fd),
              ContainerAPI.isContainerID(source.id), source.socket.hasPrefix("/"),
              source.name == URL(fileURLWithPath: path).lastPathComponent else { return nil }
        sources.withLock { $0[path] = source }
        return source
    }

    private func engineRecord(_ folder: URL) -> EngineRecord? {
        let path = folder.standardizedFileURL.path
        if let known = engines.withLock({ $0[path] }) { return known }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let record = ContainerCopies.readAttribute(ContainerCopies.engineAttribute, EngineRecord.self, from: fd),
              record.socket.hasPrefix("/"), EngineDiscovery.isAPIVersion(record.apiVersion) else { return nil }
        engines.withLock { $0[path] = record }
        return record
    }

    /// Forgets what's known about the folder at `path` (it was removed).
    package func forget(_ path: String) {
        sources.withLock { cache in cache = cache.filter { $0.key != path && !$0.key.hasPrefix(path + "/") } }
        engines.withLock { cache in cache = cache.filter { $0.key != path && !$0.key.hasPrefix(path + "/") } }
    }

    /// How an item in a copy is shown: "web:/etc/hosts". Nil outside copies.
    package func apparentPath(_ url: URL) -> String? {
        guard let (source, top) = copy(containing: url),
              let path = ContainerCopies.containerPath(of: url, top: top) else { return nil }
        return "\(source.name):\(path)"
    }

    /// A file in a copy that hasn't been fetched from its container yet (a regular file with no permissions).
    package func isPlaceholder(_ url: URL) -> Bool {
        guard contains(url) else { return false }
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
            && ContainerCopies.isPlaceholderMode(info.st_mode)
    }

    /// Removes an engine's folder, a Compose project's folder, or a container's folder. Never the cache itself, and
    /// never a folder inside a container (its files aren't Strata's to delete).
    package func remove(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return }
        let depth = path.dropFirst(rootPath.count + 1).split(separator: "/").count
        guard (1...3).contains(depth) else { return }
        // Three deep is a container in a project's folder, never a folder in a container's own files.
        if depth == 3, source(of: folder.deletingLastPathComponent()) != nil { return }
        forget(path)
        Archiver.removeTree(folder)
    }

    /// At quit (and at launch, for anything a crash left): containers' files don't outlive Strata (a container's files
    /// can be secrets). Moved aside at once and removed in the background (`removeSetAside`), so it never holds things up.
    package func setAsideForRemoval() {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let aside = root.deletingLastPathComponent().appending(path: "Containers-removed-\(UUID().uuidString).noindex")
        try? FileManager.default.moveItem(at: root, to: aside)
        sources.withLock { $0.removeAll() }
        engines.withLock { $0.removeAll() }
    }

    /// Removes what was set aside (beside the copies' folder).
    package func removeSetAside() {
        let parent = root.deletingLastPathComponent()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix("Containers-removed-") {
            Archiver.removeTree(parent.appending(path: name))
        }
    }
}

package nonisolated enum ContainerCopies {
    fileprivate static let sourceAttribute = "dev.strata.container"
    fileprivate static let engineAttribute = "dev.strata.engine"

    /// An engine's folder name: the same engine always gets the same one.
    package static func engineKey(_ socket: String) -> String {
        SHA256.hash(data: Data(socket.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The Compose project a container is grouped under, when that name can be a folder. Nil leaves it beside the stacks.
    package static func stackName(_ container: ContainerInfo) -> String? {
        guard let project = container.compose?.project, isContainerName(project) else { return nil }
        return project
    }

    /// The container recorded on the folder named `name` in the folder open at `fd`, if any.
    package static func recordedSource(_ name: String, in fd: Int32) -> ContainerSource? {
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { return nil }
        defer { close(child) }
        return readAttribute(sourceAttribute, ContainerSource.self, from: child)
    }

    /// A container's name as a folder name: what Docker allows, nothing hidden.
    package static func isContainerName(_ name: String) -> Bool {
        isSafeName(name) && !name.hasPrefix(".") && name.utf8.count <= 128
    }

    fileprivate static func setAttribute(_ name: String, _ value: some Encodable, on folder: URL) throws {
        let data = try JSONEncoder().encode(value)
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        guard data.withUnsafeBytes({ fsetxattr(fd, name, $0.baseAddress, $0.count, 0, 0) }) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    fileprivate static func readAttribute<T: Decodable>(_ name: String, _ type: T.Type, from fd: Int32) -> T? {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let count = fgetxattr(fd, name, &buffer, buffer.count, 0, 0)
        guard count > 0 else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(buffer[0..<count]))
    }

    /// `url`'s path inside the container ("/etc/hosts"); nil outside `top`.
    package static func containerPath(of url: URL, top: URL) -> String? {
        let path = url.standardizedFileURL.path, topPath = top.standardizedFileURL.path
        if path == topPath { return "/" }
        guard path.hasPrefix(topPath + "/") else { return nil }
        return String(path.dropFirst(topPath.count))
    }

    /// Where the container's `path` is in the copy.
    package static func url(forContainerPath path: String, top: URL) -> URL {
        normalized(path).reduce(top) { $0.appending(path: $1) }
    }

    /// The components of `path` with `.` and empty parts gone and `..` taken back, stopping at `/` the way the
    /// container's root does.
    package static func normalized(_ path: String, from base: [String] = []) -> [String] {
        var parts = path.hasPrefix("/") ? [] : base
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        return parts
    }

    /// The target to give a link at container path `link` that points to `target` in the container: relative, so it
    /// resolves inside the copy, and never above its top (as `..` never goes above a container's `/`).
    package static func copyLinkTarget(_ target: String, at link: String) -> String? {
        guard !target.isEmpty, !target.contains("\0"), target.utf8.count <= 4096 else { return nil }
        let folder = Array(normalized(link).dropLast())
        let resolved = normalized(target, from: folder)
        var common = 0
        while common < folder.count, common < resolved.count, folder[common] == resolved[common] {
            common += 1
        }
        let up = Array(repeating: "..", count: folder.count - common)
        let parts = up + resolved.dropFirst(common)
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    /// A name a container listing may give a copy: one path component, nothing that steps elsewhere.
    package static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") && name.utf8.count <= 255
    }

    /// A placeholder can't be read or written; it keeps only the container's execute bits, so a program shows as a
    /// Unix executable before it's fetched. A fetched file is always readable.
    package static func isPlaceholderMode(_ mode: mode_t) -> Bool { mode & 0o666 == 0 }

    /// Only entries recorded by the transfer worker are changed. The source can disappear after a copy; its
    /// continued existence is neither proof of destination ownership nor a condition for dropping unsafe links.
    package static func finishCopyingOut(_ url: URL, owned: [String: FileIdentity]) throws {
        let top = url.path
        for (path, identity) in owned.sorted(by: { $0.key.count < $1.key.count }) {
            guard path == top || path.hasPrefix(top + "/"), FileIdentity.read(path) == identity else { continue }
            let chosen = try ChosenFile(URL(fileURLWithPath: path), resolveParent: false)
            guard chosen.identity == identity else { continue }
            try chosen.withDescriptor { fd, info in
                let kind = info.st_mode & S_IFMT
                if kind == S_IFLNK {
                    let relative = String(path.dropFirst(min(path.count, top.count + 1)))
                    var budget = 4096
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
                    if path == top || Archiver.resolve(target, from: relative.split(separator: "/").dropLast().map(String.init),
                                                       in: top, hops: 0, budget: &budget) == nil {
                        try chosen.remove()
                    }
                } else if kind == S_IFREG || kind == S_IFDIR {
                    if kind == S_IFDIR {
                        for name in [sourceAttribute, engineAttribute, "dev.strata.modified"] {
                            if fremovexattr(fd, name, 0) != 0, errno != ENOATTR, errno != ENOTSUP {
                                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                            }
                        }
                    }
                    if info.st_mode & S_IWUSR == 0, fchmod(fd, (info.st_mode & 0o7777) | S_IWUSR) != 0 {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
            }
        }
    }

}

/// Strata's read-only copies: archives opened as folders and container files. Nothing inside one is changed from
/// Strata, and nothing is moved or saved into one. The app's own copies count for every window, not only `copies`:
/// refusing a change inside a copy Strata keeps is never wrong.
package nonisolated enum ReadOnlyCopies {
    package static func contains(_ url: URL, copies: CopyProviders) -> Bool {
        ArchiveCache.contains(url) || ContainerCopyStore.shared.contains(url) || RemoteCopyStore.shared.contains(url)
            || copies.isClipboardStaging(url)
            || copies.contains(url) || copies.remoteCopies.contains(url) || copies.containerCopies.contains(url)
    }
}
