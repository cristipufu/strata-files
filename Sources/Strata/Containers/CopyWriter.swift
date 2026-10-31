import Darwin
import CoreServices
import Foundation
import Synchronization

/// Writes listings and fetched files into a copy. Every step works relative to an open folder descriptor and never
/// follows a link, so nothing lands outside the copy whatever a container's names and links say.
package nonisolated enum CopyWriter {
    private static let tempPrefix = ".strata-fetch-"

    /// Whether a listed file is fetched with its listing: small, world-readable (a secret only its owner may read waits
    /// until it's opened), and within the folder's budget.
    package static func fetchesEagerly(size: Int64, mode: UInt32, bytes: Int64, count: Int) -> Bool {
        let (nextBytes, overflow) = bytes.addingReportingOverflow(size)
        return size >= 0 && size <= ContainerFiles.eagerFileSize && mode & 0o004 != 0
            && !overflow && nextBytes <= ContainerFiles.eagerFolderBytes && count < ContainerFiles.eagerFolderCount
    }

    /// A name in an archive stream without its leading `/`.
    package static func streamName(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.drop { $0 == "/" }) : path
    }

    /// `name` below the stream's top folder `base` ("" for `/`); nil outside it.
    package static func relative(_ name: String, to base: String) -> Substring? {
        if base.isEmpty { return Substring(name) }
        return name.hasPrefix(base + "/") ? name.dropFirst(base.count + 1) : nil
    }

    /// How the disk of the folder open at `fd` compares names: two names that fold the same are one item there. Linux
    /// tells `Foo` from `foo`; a Mac's disk usually doesn't.
    package static func folding(in fd: Int32) -> @Sendable (String) -> String {
        if fpathconf(fd, _PC_CASE_SENSITIVE) == 1 { return { $0 } }
        return { $0.decomposedStringWithCanonicalMapping.lowercased() }
    }

    /// Makes the Containers `folder` match `containers`. A Compose project's containers go in a folder named after the
    /// project; the rest stay beside those. Returns the folders to discard: containers gone, and ones made again under
    /// the same name (made afresh after). A container that moved into its project keeps the files already fetched.
    package static func syncContainers(_ containers: [ContainerInfo], engine: ContainerEngine, in folder: URL,
                               copies: ContainerCopyStore) throws -> [URL] {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(fd) }
        let folded = folding(in: fd)
        let looseNames = Set(containers.compactMap { container -> String? in
            guard ContainerCopies.stackName(container) == nil, ContainerCopies.isContainerName(container.name) else { return nil }
            return folded(container.name)
        })
        // By the name as the disk sees it: projects whose names differ only in case share one folder (named the first
        // way seen) rather than one of them going missing.
        var byStack: [String: (project: String, members: [ContainerInfo])] = [:]
        var loose: [ContainerInfo] = []
        for container in containers where ContainerCopies.isContainerName(container.name) {
            if let project = ContainerCopies.stackName(container), !looseNames.contains(folded(project)) {
                byStack[folded(project), default: (project, [])].members.append(container)
            } else {
                loose.append(container)
            }
        }
        var keep = Set<String>()
        var gone: [URL] = []
        func place(_ container: ContainerInfo, in parent: Int32, at parentURL: URL, keeping: inout Set<String>) {
            guard keeping.insert(folded(container.name)).inserted else { return }
            if let recorded = ContainerCopies.recordedSource(container.name, in: parent), recorded.id != container.id {
                gone.append(parentURL.appending(path: container.name, directoryHint: .isDirectory))
                return
            }
            try? copies.record(container, on: engine, in: parent, folder: parentURL)
        }
        for container in loose { place(container, in: fd, at: folder, keeping: &keep) }
        for (key, stack) in byStack {
            let (project, members) = stack
            guard keep.insert(key).inserted else { continue }
            // The project name is already a container folder. Move that container aside when it belongs inside the
            // project. Otherwise it's a container that's gone, renamed or now in another project (a container with
            // that name still on its own keeps it: see `looseNames`), so it's discarded and the next pass makes the
            // project's folder; until then its containers stay beside the stacks.
            var held: String?
            if let recorded = ContainerCopies.recordedSource(project, in: fd) {
                let movesIn = members.contains { $0.id == recorded.id && $0.name == project }
                guard movesIn else {
                    gone.append(folder.appending(path: project, directoryHint: .isDirectory))
                    for container in members where folded(container.name) != key {
                        place(container, in: fd, at: folder, keeping: &keep)
                    }
                    continue
                }
                let temp = ".hold-" + String(UUID().uuidString.prefix(8))
                if renameat(fd, project, fd, temp) == 0 {
                    held = temp
                    copies.forget(folder.appending(path: project).standardizedFileURL.path)
                }
            }
            mkdirat(fd, project, 0o755)
            let child = openat(fd, project, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { continue }
            defer { close(child) }
            let stack = folder.appending(path: project, directoryHint: .isDirectory)
            if let held {
                if renameat(fd, held, child, project) == 0 {
                    copies.forget(folder.appending(path: held).standardizedFileURL.path)
                }
            }
            var keepChild = Set<String>()
            for container in members {
                bringDown(container, from: fd, to: child, stack: stack, engineFolder: folder, copies: copies)
                place(container, in: child, at: stack, keeping: &keepChild)
            }
            for name in names(in: child) where !keepChild.contains(folded(name)) {
                gone.append(stack.appending(path: name, directoryHint: .isDirectory))
            }
        }
        for name in names(in: fd) where !keep.contains(folded(name)) {
            gone.append(folder.appending(path: name, directoryHint: .isDirectory))
        }
        return gone
    }

    /// Moves a container's folder from the engine's folder into its project, when an older layout left it there.
    private static func bringDown(_ container: ContainerInfo, from engineFD: Int32, to stackFD: Int32, stack: URL, engineFolder: URL,
                                  copies: ContainerCopyStore) {
        var info = stat()
        guard fstatat(stackFD, container.name, &info, AT_SYMLINK_NOFOLLOW) != 0 else { return }
        guard fstatat(engineFD, container.name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFDIR else { return }
        guard let recorded = ContainerCopies.recordedSource(container.name, in: engineFD), recorded.id == container.id else { return }
        guard renameat(engineFD, container.name, stackFD, container.name) == 0 else { return }
        copies.forget(engineFolder.appending(path: container.name).standardizedFileURL.path)
    }

    /// Makes `folder` match `entries`: folders and links made, files as placeholders (or written, from `contents`),
    /// items no longer there removed. Names the copy's disk can't tell apart from an earlier one are left out. A link
    /// leading to a folder gets that folder made (empty, inside `top`) so it shows and opens as one. Returns
    /// placeholders to fetch right away.
    package static func apply(_ entries: [ListedEntry], contents: [String: Data], to folder: URL, containerPath: String, top: URL? = nil,
                      expected: FileIdentity? = nil) throws -> [URL] {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        if let expected {
            var opened = stat()
            guard fstat(fd, &opened) == 0, FileIdentity.from(opened) == expected else { close(fd); throw POSIXError(.ESTALE) }
        }
        let folded = folding(in: fd)
        defer {
            // Writing in it changed its date; the container's comes back.
            restoreTimes(fd)
            close(fd)
        }
        let topFD = top.map { open($0.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        defer { if topFD >= 0 { close(topFD) } }
        let existing = names(in: fd)
        var listed = Set<String>()
        var eager: [URL] = []
        var eagerBytes: Int64 = 0
        let base = containerPath == "/" ? "" : containerPath
        for entry in entries where ContainerCopies.isSafeName(entry.name) && !entry.name.hasPrefix(tempPrefix) {
            let name = entry.name
            guard entry.kind != .other, listed.insert(folded(name)).inserted else { continue }
            var info = stat()
            var exists = fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0
            let type = exists ? info.st_mode & S_IFMT : 0
            switch entry.kind {
            case .directory:
                if exists, type != S_IFDIR { removeAt(fd, name); exists = false }
                if !exists { mkdirat(fd, name, 0o755) }
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child >= 0 {
                    // A folder can be an app (`Foo.app`): marked like the files.
                    try? markDownloaded(child)
                    remember(entry.modified, onFolder: child)
                    close(child)
                }
            case .symlink:
                guard let target = ContainerCopies.copyLinkTarget(entry.linkTarget, at: base + "/" + name) else { continue }
                if entry.targetIsDirectory, topFD >= 0 {
                    makeFolders(topFD, ContainerCopies.normalized(entry.linkTarget, from: ContainerCopies.normalized(base)))
                }
                if exists, type == S_IFLNK, linkTarget(name, fd: fd) == target { continue }
                if exists { removeAt(fd, name) }
                symlinkat(target, fd, name)
                setLinkTimes(fd, name, entry.modified)
            case .file:
                let same = exists && type == S_IFREG && Int64(info.st_size) == entry.size
                    && Int(info.st_mtimespec.tv_sec) == ContainerTime.seconds(entry.modified)
                let placeholder = same && ContainerCopies.isPlaceholderMode(info.st_mode)
                // A placeholder follows the container's execute bits (`chmod +x` changes neither size nor date).
                if placeholder, info.st_mode & 0o111 != mode_t(entry.mode & 0o111) {
                    fchmodat(fd, name, mode_t(entry.mode & 0o111), AT_SYMLINK_NOFOLLOW)
                }
                if let data = contents[name] {
                    if same, !placeholder { continue }
                    if exists, type != S_IFREG { removeAt(fd, name) }
                    try write(data, as: name, fd: fd, mode: entry.mode, modified: entry.modified)
                    continue
                }
                if !same {
                    if exists { removeAt(fd, name) }
                    try makePlaceholder(name, fd: fd, size: entry.size, mode: entry.mode, modified: entry.modified)
                }
                if !same || placeholder, fetchesEagerly(size: entry.size, mode: entry.mode, bytes: eagerBytes, count: eager.count) {
                    eagerBytes += entry.size
                    eager.append(folder.appending(path: name))
                }
            case .other:
                continue
            }
        }
        for name in existing where !listed.contains(folded(name)) && !name.hasPrefix(tempPrefix) {
            removeAt(fd, name)
        }
        return eager
    }

    /// Streams the container's file at `containerPath` into the placeholder at `url`, replacing it when complete.
    package static func fetchFile(_ engine: ContainerEngine, id: String, containerPath: String, to url: URL, stop: StopFlag) throws {
        let folder = url.deletingLastPathComponent()
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(fd) }
        try fetchFile(engine, id: id, containerPath: containerPath, into: fd, name: url.lastPathComponent, stop: stop)
    }

    /// The same, into the folder open at `fd`.
    private static func fetchFile(_ engine: ContainerEngine, id: String, containerPath: String, into fd: Int32, name: String, stop: StopFlag) throws {
        var placeholder = stat()
        let expectedPlaceholder = (fstatat(fd, name, &placeholder, AT_SYMLINK_NOFOLLOW) == 0
            && placeholder.st_mode & S_IFMT == S_IFREG
            && ContainerCopies.isPlaceholderMode(placeholder.st_mode)) ? FileIdentity.from(placeholder) : nil
        let temp = tempPrefix + UUID().uuidString
        var out: Int32 = -1
        var reader = TarReader()
        var entry: TarEntry?
        var done = false
        defer {
            if out >= 0 { close(out) }
            if !done { unlinkat(fd, temp, 0) }
        }
        try ContainerAPI.archive(engine, id: id, path: containerPath, shouldStop: { stop.isSet }) { chunk in
            try reader.feed(chunk) { event in
                switch event {
                case .begin(let first):
                    guard entry == nil else { return }
                    entry = first
                    if first.kind == .file {
                        out = openat(fd, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                        guard out >= 0 else { throw CocoaError(.fileWriteNoPermission) }
                        try markDownloaded(out)
                    }
                case .data(let data):
                    // Only the first entry's: anything after it in the stream isn't this file.
                    guard out >= 0, !done else { return }
                    try writeAll(data, to: out)
                case .end:
                    done = entry != nil
                }
            }
            return !done
        }
        guard done, let entry, entry.kind == .file, out >= 0 else {
            done = false
            throw ContainerAPIError.notFound
        }
        fchmod(out, mode_t(readable(entry.mode)))
        setTimes(out, entry.modified)
        close(out)
        out = -1
        // Only over the placeholder: if the folder was listed again meanwhile and it's something else now, leave that.
        var info = stat()
        guard let expectedPlaceholder,
              fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG,
              ContainerCopies.isPlaceholderMode(info.st_mode), FileIdentity.from(info) == expectedPlaceholder,
              renameat(fd, temp, fd, name) == 0 else {
            done = false
            return
        }
        restoreTimes(fd)
    }

    /// A link's own date (not what it points to).
    private static func setLinkTimes(_ fd: Int32, _ name: String, _ date: Date?) {
        guard let date, let seconds = Optional(date.timeIntervalSince1970), seconds.isFinite, abs(seconds) < 1e11 else { return }
        let spec = timespec(tv_sec: Int(seconds.rounded(.down)), tv_nsec: 0)
        var times = [spec, spec]
        utimensat(fd, name, &times, AT_SYMLINK_NOFOLLOW)
    }

    /// The extended attribute holding a copy folder's date in the container.
    private static let dateAttribute = "dev.strata.modified"

    /// Gives the folder open at `fd` its date in the container, and remembers it for after Strata writes into it.
    package static func remember(_ date: Date?, onFolder fd: Int32) {
        guard let date, ContainerTime.date(date.timeIntervalSince1970) != nil else { return }
        let text = String(date.timeIntervalSince1970)
        _ = text.withCString { fsetxattr(fd, dateAttribute, $0, strlen($0), 0, 0) }
        setTimes(fd, date)
    }

    /// Sets the folder open at `fd` back to its date in the container (if it has one).
    package static func restoreTimes(_ fd: Int32) {
        var buffer = [CChar](repeating: 0, count: 64)
        let count = fgetxattr(fd, dateAttribute, &buffer, 63, 0, 0)
        guard count > 0, let seconds = Double(String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)),
              let date = ContainerTime.date(seconds) else { return }
        setTimes(fd, date)
    }

    /// Makes the folders at `parts` below `fd` (a link's target), stopping at anything that isn't a folder or is a link.
    private static func makeFolders(_ fd: Int32, _ parts: [String]) {
        guard !parts.isEmpty, parts.count <= 64, parts.allSatisfy({ ContainerCopies.isSafeName($0) && !$0.hasPrefix(tempPrefix) }) else { return }
        var current = fd
        defer { if current != fd { close(current) } }
        for part in parts {
            var info = stat()
            if fstatat(current, part, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                guard mkdirat(current, part, 0o755) == 0 else { return }
            } else if info.st_mode & S_IFMT != S_IFDIR {
                return
            }
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if current != fd { close(current) }
            current = fd
            guard next >= 0 else { return }
            try? markDownloaded(next)
            current = next
        }
    }

    /// Writes the container's folder at `containerPath`, with everything in it, into `folder` (its copy), then removes
    /// what the container no longer has.
    package static func writeTree(_ engine: ContainerEngine, id: String, containerPath: String, into folder: URL, stop: StopFlag) throws {
        let rootFD = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let writer = TreeWriter(rootFD: rootFD, containerPath: containerPath)
        defer { writer.close() }
        try ContainerAPI.archive(engine, id: id, path: containerPath, shouldStop: { stop.isSet }) { chunk in
            try writer.feed(chunk)
        }
        let rootName = try writer.finishedRoot()
        try writer.linkHardlinks(under: rootName, engine, id: id, stop: stop)
        writer.removeWhatsGoneAndDateFolders()
    }

    /// One container folder written into its copy from a tar stream, entry by entry (depth first), then its hard links,
    /// then what the container no longer has removed.
    nonisolated private final class TreeWriter {
        let rootFD: Int32
        let containerPath: String
        let base: String
        private let folded: @Sendable (String) -> String
        /// The folders open along the current entry's path (a tar stream goes depth first).
        private var stack: [(name: String, fd: Int32)] = []
        /// Every item written, by its folded path (see `folded`), with its spelling.
        private var seen: [String: String] = [:]
        private var materialized = Set<String>()
        private var hardlinks: [(parts: [String], target: String)] = []
        /// Folders' dates in the container, set once everything is written into them.
        private var folderDates: [(parts: [String], date: Date?)] = []
        private var reader = TarReader()
        private var root: String?
        private var file: (fd: Int32, parent: Int32, temp: String, name: String, entry: TarEntry, key: String)?

        init(rootFD: Int32, containerPath: String) {
            self.rootFD = rootFD
            self.containerPath = containerPath
            base = containerPath == "/" ? "" : containerPath
            folded = folding(in: rootFD)
        }

        /// A file being written is dropped, then every folder open is closed, the copy's own last.
        func close() {
            if let open = file {
                Darwin.close(open.fd)
                unlinkat(open.parent, open.temp, 0)
            }
            closeFolders()
            Darwin.close(rootFD)
        }

        private func closeFolders() {
            stack.forEach { Darwin.close($0.fd) }
            stack.removeAll()
        }

        /// Whether to go on reading.
        func feed(_ chunk: Data) throws -> Bool {
            try reader.feed(chunk) { event in
                switch event {
                case .begin(let entry): try begin(entry)
                case .data(let data): if let open = file { try writeAll(data, to: open.fd) }
                case .end: endFile()
                }
            }
            return !reader.isFinished
        }

        /// The folder for `parts` (made if needed, never through a link), with the stack kept to that path.
        private func folderFD(_ parts: ArraySlice<String>) throws -> Int32 {
            var common = 0
            while common < stack.count, common < parts.count, stack[common].name == parts[parts.startIndex + common] { common += 1 }
            while stack.count > common { Darwin.close(stack.removeLast().fd) }
            for part in parts.dropFirst(common) {
                let parent = stack.last?.fd ?? rootFD
                var info = stat()
                if fstatat(parent, part, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT != S_IFDIR {
                    removeAt(parent, part)
                }
                mkdirat(parent, part, 0o755)
                let fd = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
                stack.append((part, fd))
                try markDownloaded(fd)
            }
            return stack.last?.fd ?? rootFD
        }

        /// An entry's path below the folder copied, as safe names, while it's the first spelling of each name on it
        /// the copy's disk can tell apart; nil for one to skip. The stream's first entry is that folder itself.
        private func place(of entry: TarEntry) -> (parts: [String], path: String, key: String)? {
            let name = streamName(entry.path)
            guard let rootName = root else {
                root = entry.kind == .directory ? name : "\u{0}"
                return nil
            }
            guard let rest = relative(name, to: rootName) else { return nil }
            let parts = rest.split(separator: "/").map(String.init)
            guard !parts.isEmpty, entry.kind != .other,
                  parts.allSatisfy({ ContainerCopies.isSafeName($0) && !$0.hasPrefix(tempPrefix) }) else { return nil }
            // Two names the copy's disk can't tell apart: the first one wins.
            let path = parts.joined(separator: "/")
            let key = parts.map(folded).joined(separator: "/")
            if let spelling = seen[key], spelling != path { return nil }
            guard parts.dropLast().indices.allSatisfy({ seen[parts[...$0].map(folded).joined(separator: "/")] == parts[...$0].joined(separator: "/")
                || seen[parts[...$0].map(folded).joined(separator: "/")] == nil }) else { return nil }
            for idx in parts.dropLast().indices {
                seen[parts[...idx].map(folded).joined(separator: "/")] = parts[...idx].joined(separator: "/")
            }
            return (parts, path, key)
        }

        private func begin(_ entry: TarEntry) throws {
            guard let (parts, path, key) = place(of: entry) else { return }
            let parent = try folderFD(parts.dropLast()[...])
            let last = parts[parts.count - 1]
            switch entry.kind {
            case .directory:
                seen[key] = path
                _ = try folderFD(parts[...])
                folderDates.append((parts, entry.modified))
            case .symlink:
                guard let target = ContainerCopies.copyLinkTarget(entry.linkTarget, at: base + "/" + path) else { return }
                seen[key] = path
                if linkTarget(last, fd: parent) == target { return }
                removeAt(parent, last)
                symlinkat(target, parent, last)
                setLinkTimes(parent, last, entry.modified)
            case .hardlink:
                // Linked to its first name once the stream is through (hardlinks carry no data).
                seen[key] = path
                hardlinks.append((parts, entry.linkTarget))
            case .file:
                seen[key] = path
                try beginFile(entry, named: last, in: parent, key: key)
            case .other:
                return
            }
        }

        /// Opens a temporary file next to the entry's place, unless the same file is already there.
        private func beginFile(_ entry: TarEntry, named last: String, in parent: Int32, key: String) throws {
            var info = stat()
            if fstatat(parent, last, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG, !ContainerCopies.isPlaceholderMode(info.st_mode),
               Int64(info.st_size) == entry.size, Int(info.st_mtimespec.tv_sec) == ContainerTime.seconds(entry.modified) {
                materialized.insert(key)
                return  // Already here.
            }
            let temp = tempPrefix + UUID().uuidString
            let out = openat(parent, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard out >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            file = (out, parent, temp, last, entry, key)
            try markDownloaded(out)
        }

        /// The file written whole takes its place (a folder there goes); one that can't keeps nothing behind.
        private func endFile() {
            guard let open = file else { return }
            file = nil
            fchmod(open.fd, mode_t(readable(open.entry.mode)))
            setTimes(open.fd, open.entry.modified)
            Darwin.close(open.fd)
            var info = stat()
            if fstatat(open.parent, open.name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR {
                removeAt(open.parent, open.name)
            }
            if renameat(open.parent, open.temp, open.parent, open.name) == 0 {
                materialized.insert(open.key)
            } else { unlinkat(open.parent, open.temp, 0) }
        }

        /// The folder copied, once the stream has gone through: one cut short says nothing about what's gone.
        func finishedRoot() throws -> String {
            guard let rootName = root, rootName != "\u{0}" else { throw ContainerAPIError.notFound }
            guard reader.isFinished else { throw ContainerAPIError.transport(.closed) }
            closeFolders()
            return rootName
        }

        func linkHardlinks(under rootName: String, _ engine: ContainerEngine, id: String, stop: StopFlag) throws {
            for link in hardlinks {
                try linkHardlink(link, under: rootName, engine, id: id, stop: stop)
            }
            closeFolders()
        }

        /// A hard link to its first name when that's a file this copy has whole; otherwise fetched on its own.
        private func linkHardlink(_ link: (parts: [String], target: String), under rootName: String,
                                  _ engine: ContainerEngine, id: String, stop: StopFlag) throws {
            // Absolute targets refer to the container root, not the basename of this copied subfolder.
            let target = containerPath == "/" ? streamName(link.target) : link.target
            let targetRest = target.hasPrefix("/") ? nil : relative(target, to: rootName)
            guard target.hasPrefix("/") || targetRest != nil else { return }
            let targetParts = targetRest?.split(separator: "/").map(String.init) ?? []
            if targetRest != nil {
                guard !targetParts.isEmpty, targetParts.allSatisfy({ ContainerCopies.isSafeName($0) && !$0.hasPrefix(tempPrefix) }) else { return }
            }
            let currentTarget = !targetParts.isEmpty
                && targetParts.allSatisfy({ ContainerCopies.isSafeName($0) && !$0.hasPrefix(tempPrefix) })
                && materialized.contains(targetParts.map(folded).joined(separator: "/"))
            seen[link.parts.map(folded).joined(separator: "/")] = link.parts.joined(separator: "/")
            let linkDir = try folderFD(link.parts.dropLast()[...])
            let name = link.parts[link.parts.count - 1]
            var linked = false
            if currentTarget, let targetDir = openPath(rootFD, targetParts.dropLast()[...]) {
                var targetInfo = stat()
                let targetName = targetParts[targetParts.count - 1]
                if fstatat(targetDir, targetName, &targetInfo, AT_SYMLINK_NOFOLLOW) == 0,
                   targetInfo.st_mode & S_IFMT == S_IFREG, !ContainerCopies.isPlaceholderMode(targetInfo.st_mode) {
                    removeAt(linkDir, name)
                    linked = linkat(targetDir, targetName, linkDir, name, 0) == 0
                }
                if targetDir != rootFD { Darwin.close(targetDir) }
            }
            if !linked {
                // Its first name is outside this folder: fetch it on its own.
                removeAt(linkDir, name)
                let path = base + "/" + link.parts.joined(separator: "/")
                try makePlaceholder(name, fd: linkDir, size: 0, mode: 0, modified: nil)
                try fetchFile(engine, id: id, containerPath: path, into: linkDir, name: name, stop: stop)
            }
            materialized.insert(link.parts.map(folded).joined(separator: "/"))
        }

        func removeWhatsGoneAndDateFolders() {
            sweep(rootFD, prefix: "", keeping: seen, folded: folded)
            for folder in folderDates.reversed() {
                guard let fd = openPath(rootFD, folder.parts[...]) else { continue }
                remember(folder.date, onFolder: fd)
                if fd != rootFD { Darwin.close(fd) }
            }
            restoreTimes(rootFD)
        }
    }

    /// Removes what's in the folder open at `fd` but not in `keeping` (folded paths), recursively and without following
    /// links.
    private static func sweep(_ fd: Int32, prefix: String, keeping: [String: String], folded: (String) -> String) {
        for name in names(in: fd) where !name.hasPrefix(tempPrefix) {
            let key = prefix + folded(name)
            guard keeping[key] != nil else {
                removeAt(fd, name)
                continue
            }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { continue }
            sweep(child, prefix: key + "/", keeping: keeping, folded: folded)
            close(child)
        }
    }

    /// The folder at `parts` below `fd`, opened without following links (nil if any part isn't a folder).
    private static func openPath(_ fd: Int32, _ parts: ArraySlice<String>) -> Int32? {
        var current = fd
        for part in parts {
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if current != fd { close(current) }
            guard next >= 0 else { return nil }
            current = next
        }
        return current
    }

    private static func write(_ data: Data, as name: String, fd: Int32, mode: UInt32, modified: Date?) throws {
        let temp = tempPrefix + UUID().uuidString
        let out = openat(fd, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        do {
            try markDownloaded(out)
            try writeAll(data, to: out)
        } catch {
            close(out)
            unlinkat(fd, temp, 0)
            throw error
        }
        fchmod(out, mode_t(readable(mode)))
        setTimes(out, modified)
        close(out)
        if renameat(fd, temp, fd, name) != 0 {
            unlinkat(fd, temp, 0)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func makePlaceholder(_ name: String, fd: Int32, size: Int64, mode: UInt32, modified: Date?) throws {
        let out = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(out) }
        // Sparse: the right size, without taking the space.
        ftruncate(out, off_t(max(size, 0)))
        setTimes(out, modified)
        // Unreadable until fetched; a program keeps its execute bits, so it shows as one (its kind and icon).
        fchmod(out, mode_t(mode & 0o111))
    }

    /// Fetched files are readable by you whatever the container said, and read-only (an edit saved into a copy would
    /// be lost at the next listing); no set-ID bits.
    package static func readable(_ mode: UInt32) -> UInt32 { (mode & 0o555) | 0o400 }

    /// A container's or a server's files come from another machine, so they're marked as downloaded: Gatekeeper checks
    /// an app, script or `.command` from one before it runs, and copies keep the mark, as Finder's do. The mark is the one
    /// macOS itself gives a download made by Strata (asked once, through its quarantine API), so it's always what this
    /// macOS expects; "0281;…;Strata;…" on macOS 26, and that as a fallback.
    package static let quarantine: [UInt8] = systemQuarantine()
        ?? Array("0281;\(String(Int(Date().timeIntervalSince1970), radix: 16));Strata;\(UUID().uuidString)".utf8)

    /// The mark macOS writes for a download by this app, read back from a scratch file. Nil unless it's one that says
    /// "downloaded" and not "already approved".
    package static func systemQuarantine() -> [UInt8]? {
        let probe = FileManager.default.temporaryDirectory.appending(path: "strata-quarantine-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
        defer { unlink(probe.path) }
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "Strata",
                                       kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String]
        var url = probe
        guard (try? url.setResourceValues(values)) != nil else { return nil }
        let size = getxattr(probe.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 5, size < 512 else { return nil }
        var mark = [UInt8](repeating: 0, count: size)
        guard getxattr(probe.path, "com.apple.quarantine", &mark, size, 0, XATTR_NOFOLLOW) == size,
              mark[4] == UInt8(ascii: ";"), let flags = UInt32(String(decoding: mark[0..<4], as: UTF8.self), radix: 16),
              flags & 0x0001 != 0, flags & 0x0040 == 0 else { return nil }
        // Flags; time; the app that downloaded it; the download's ID. The app is named when macOS left it out.
        var fields = String(decoding: mark, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4 else { return nil }
        if fields[2].isEmpty { fields[2] = "Strata" }
        return Array(fields.joined(separator: ";").utf8)
    }

    /// Marks the file or folder open at `fd` as downloaded (see `quarantine`). Throws when it can't be, so nothing
    /// unmarked is placed; disks that can't keep the mark at all are the exception.
    package static func markDownloaded(_ fd: Int32) throws {
        guard fsetxattr(fd, "com.apple.quarantine", quarantine, quarantine.count, 0, 0) != 0, errno != ENOTSUP else { return }
        throw CocoaError(.fileWriteNoPermission)
    }

    private static func setTimes(_ fd: Int32, _ date: Date?) {
        guard let date, let seconds = Optional(date.timeIntervalSince1970), seconds.isFinite, abs(seconds) < 1e11 else { return }
        let whole = seconds.rounded(.down)
        let spec = timespec(tv_sec: Int(whole), tv_nsec: min(999_999_999, max(0, Int((seconds - whole) * 1e9))))
        var times = [spec, spec]
        futimens(fd, &times)
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw CocoaError(.fileWriteOutOfSpace) }
                offset += written
            }
        }
    }

    private static func linkTarget(_ name: String, fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4097)
        let count = readlinkat(fd, name, &buffer, 4096)
        guard count >= 0 else { return nil }
        return String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The names in the folder open at `fd` (without `.` and `..`).
    package static func names(in fd: Int32) -> [String] {
        let copy = dup(fd)
        guard copy >= 0, let dir = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            return []
        }
        defer { closedir(dir) }
        // A copy of `fd` shares its place in the folder: from the start, whoever read it before.
        rewinddir(dir)
        var names: [String] = []
        while let entry = readdir(dir) {
            guard let name = DirectoryEntryName.read(entry) else { continue }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    /// Removes an item of the folder open at `fd` (a folder with all it holds), never following a link.
    package static func removeAt(_ fd: Int32, _ name: String) {
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return }
        if info.st_mode & S_IFMT == S_IFDIR {
            fchmodat(fd, name, 0o755, 0)
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if child >= 0 {
                for item in names(in: child) { removeAt(child, item) }
                close(child)
            }
            unlinkat(fd, name, AT_REMOVEDIR)
        } else {
            unlinkat(fd, name, 0)
        }
    }
}
