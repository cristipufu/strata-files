import Foundation
import StrataArchiveClient
import UniformTypeIdentifiers

/// Writes what Extract's worker reads out of an archive (CArchivePreview.h) into `root`, a new folder in a private one.
/// The worker that parses the archive can't write a file, so Strata writes them, and trusts nothing it is sent: each
/// record is checked before anything is made from it, and every item is made relative to a folder this writer opened,
/// never through a link and never over another item (a taken name gets a number, as Finder numbers copies). Like tar, it
/// restores permissions within the umask, without setuid, setgid or sticky bits, and times, giving folders theirs once
/// nothing more is written inside them; Mac metadata goes back as copyfile puts it back. It stops when the disk runs low
/// on space. On a disk that keeps an item's extended attributes in "._name" beside it (exFAT, FAT, some shares), no item
/// meets its partner there ("._x" and "x"): one that would gets a number, as on a taken name.
package nonisolated final class ArchiveWriter {
    private struct Times {
        var modified: timespec?, accessed: timespec?, created: timespec?
        var isEmpty: Bool { modified == nil && accessed == nil && created == nil }
    }

    private struct Attribute {
        let name: Data
        let value: Data
    }

    private struct Entry {
        enum Kind: UInt8 { case file = 1, folder, link, hardLink }
        let kind: Kind
        let path: [Data]
        /// A link's target, or the path a hard link shares.
        let link: Data
        let linked: [Data]
        let mode: mode_t
        let times: Times
        let attributes: [Attribute]
    }

    /// The stream ended before its end mark: the worker stopped, and its status says why.
    private struct StreamEnded: Error {}

    /// A path as a key that hashes every byte of its names: `Data` hashes only its first 80, so names an archive made
    /// alike there would all collide.
    private struct Key: Hashable {
        let path: [Data]

        init(_ path: [Data]) { self.path = path }

        func hash(into hasher: inout Hasher) {
            path.forEach { Self.combine($0, into: &hasher) }
        }

        static func combine(_ name: Data, into hasher: inout Hasher) {
            hasher.combine(name.count)
            name.withUnsafeBytes { hasher.combine(bytes: $0) }
        }
    }

    /// How often the disk's free space is read again: after this much is written, or on a disk with little free, a
    /// quarter of the reserve, so a check comes before the reserve is gone. Each item and each write counts as at least
    /// a block of the disk, however little it holds.
    private static let checkedEvery: Int64 = 16 << 20
    /// Folders kept open for the entries after them, the least recently used closed first.
    private static let openFolders = 64
    private static let accessList = Data("com.apple.acl.text".utf8)
    private static let installedMark = Data("com.apple.root.installed".utf8)
    private static let attributeFilePrefix = Data("._".utf8)

    private let root: Int32
    private let permissions: mode_t
    private let attributesInFiles: Bool
    private let control: Archiver.Control
    private let space: (Int32) -> (free: Int64, block: Int64)?
    private let read: (UnsafeMutableRawBufferPointer) throws -> Int
    private let started = timespec(tv_sec: time(nil), tv_nsec: 0)
    private var buffer = [UInt8](repeating: 0, count: 1 << 17)
    private var start = 0, end = 0
    private var reserve: Int64?
    private var checkedAfter = checkedEvery, unchecked: Int64 = 0, block: Int64 = 4096
    /// Open folders by the hash of their path in the archive, which is checked on a match: an entry opens only the
    /// folders below the deepest one already open.
    private var folders: [Int: (path: [Data], fd: Int32, used: Int)] = [:], uses = 0
    /// What the writer keeps for later is bounded, since the archive decides how much it would be: past `memory`
    /// bytes, a folder gets its times at once (what's written inside it later may move them), and a taken name is
    /// numbered by trying each number again.
    private let memory: Int
    private var remembered = 0
    /// In the order of their entries, so the latest entry for a folder sets its times even under another spelling of its
    /// name that the disk takes for the same one.
    private var folderTimes: [Key: (times: Times, order: Int)] = [:], folderEntries = 0
    /// For a name an entry found taken, under every spelling a disk could take for it: the next number to try. And
    /// for a file's path, the name the latest such entry got, which a hard link to that name shares, as tar would share
    /// the latest item of a name.
    private var nextNumber: [Key: Int] = [:], latest: [Key: Data] = [:]
    /// A folder whose name another item had got a number; what's inside it goes there. The folders numbered, by inode:
    /// another of the archive's folders with that name isn't one of them.
    private var folderNames: [Key: Data] = [:], numberedFolders: Set<UInt64> = []

    /// Writes every entry `read` brings (0 once the stream ends), then the folders' times; whether the stream was
    /// complete. One that ended early leaves why to the read's status. `permissions`: what a new folder gets here, which
    /// bounds what any item gets.
    package static func write(into root: Int32, permissions: mode_t, control: Archiver.Control,
                      space: @escaping (Int32) -> (free: Int64, block: Int64)? = Archiver.space(of:),
                      attributesInFiles: (Int32) -> Bool = Archiver.attributesInFiles(of:),
                      memory: Int = 64 << 20,
                      read: @escaping (UnsafeMutableRawBufferPointer) throws -> Int) throws -> Bool {
        try ArchiveWriter(root: root, permissions: permissions, control: control, space: space,
                          attributesInFiles: attributesInFiles(root), memory: memory, read: read).run()
    }

    private init(root: Int32, permissions: mode_t, control: Archiver.Control,
                 space: @escaping (Int32) -> (free: Int64, block: Int64)?, attributesInFiles: Bool, memory: Int,
                 read: @escaping (UnsafeMutableRawBufferPointer) throws -> Int) {
        self.root = root; self.permissions = permissions & 0o777; self.control = control
        self.space = space; self.memory = memory; self.read = read
        self.attributesInFiles = attributesInFiles
    }

    deinit {
        folders.values.forEach { close($0.fd) }
    }

    private func run() throws -> Bool {
        if let space = space(root) { watch(space) }
        do {
            guard try bytes(4) == Data("SAU1".utf8) else { throw unreadable }
            while let entry = try nextEntry() {
                guard !control.isCancelled else { throw CancellationError() }
                try makeRoom(for: 0)
                try write(entry)
                control.advance(1)
            }
            guard try !fill() else { throw unreadable }
        } catch is StreamEnded {
            return false
        }
        for (key, (times, _)) in folderTimes.sorted(by: { $0.value.order < $1.value.order }) {
            guard !control.isCancelled else { throw CancellationError() }
            let path = key.path
            let fd = try subfolder(path, in: folder(path.dropLast(), creating: false), creating: false)
            defer { close(fd) }
            try setTimes(times, on: fd, path)
        }
        return true
    }

    // MARK: - Reading the stream

    private var unreadable: Archiver.Failure { Archiver.Failure(message: PreviewArchiveError.unreadable.localizedDescription) }

    /// Makes a byte available; false at the end of the stream.
    private func fill() throws -> Bool {
        if start < end { return true }
        start = 0
        end = try buffer.withUnsafeMutableBytes { try read($0) }
        return end > 0
    }

    private func byte() throws -> UInt8 {
        guard try fill() else { throw StreamEnded() }
        defer { start += 1 }
        return buffer[start]
    }

    private func number(_ width: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<width { value = value << 8 | UInt64(try byte()) }
        return value
    }

    private func bytes(_ count: Int) throws -> Data {
        var data = Data(capacity: count)
        while data.count < count {
            guard try fill() else { throw StreamEnded() }
            let taken = min(count - data.count, end - start)
            data.append(contentsOf: buffer[start..<(start + taken)])
            start += taken
        }
        return data
    }

    /// A length the worker sends, at most `limit`.
    private func length(_ width: Int, limit: Int) throws -> Int {
        let value = try number(width)
        guard value <= UInt64(limit) else { throw unreadable }
        return Int(value)
    }

    /// The next entry's record; nil at the end mark.
    private func nextEntry() throws -> Entry? {
        let tag = try byte()
        guard tag != 0 else { return nil }
        guard let kind = Entry.Kind(rawValue: tag) else { throw unreadable }
        let path = try components(bytes(length(4, limit: 4096)))
        let link = try bytes(length(4, limit: 4096))
        let mode = mode_t(try number(2)) & 0o7777
        let times = try nextTimes(), attributes = try nextAttributes()
        switch kind {
        case .file, .folder: guard link.isEmpty else { throw unreadable }
        case .link: guard !link.isEmpty, !link.contains(0) else { throw unreadable }
        case .hardLink: break
        }
        return Entry(kind: kind, path: path, link: link, linked: kind == .hardLink ? try components(link) : [],
                     mode: mode, times: times, attributes: attributes)
    }

    /// A path the worker sends, as tar writes it: names a folder can hold, separated by slashes.
    private func components(_ path: Data) throws -> [Data] {
        let parts = path.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false).map { Data($0) }
        guard !path.isEmpty, parts.count <= 128, parts.allSatisfy({ part in
            !part.isEmpty && part.count <= 255 && !part.contains(0) && part != Data(".".utf8) && part != Data("..".utf8)
        }) else { throw unreadable }
        return parts
    }

    private func nextTimes() throws -> Times {
        let set = try byte()
        guard set & ~7 == 0 else { throw unreadable }
        func time() throws -> timespec {
            let seconds = Int64(bitPattern: try number(8)), nanoseconds = try number(4)
            guard nanoseconds < 1_000_000_000 else { throw unreadable }
            return timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds))
        }
        var times = Times()
        if set & 1 != 0 { times.modified = try time() }
        if set & 2 != 0 { times.accessed = try time() }
        if set & 4 != 0 { times.created = try time() }
        return times
    }

    private func nextAttributes() throws -> [Attribute] {
        var attributes: [Attribute] = [], total = 0
        for _ in 0..<(try number(2)) {
            let name = try bytes(length(1, limit: Int(XATTR_MAXNAMELEN)))
            guard !name.isEmpty, !name.contains(0) else { throw unreadable }
            let size = try length(4, limit: ArchiveService.metadataLimit - total)
            total += size
            attributes.append(Attribute(name: name, value: try bytes(size)))
        }
        return attributes
    }

    private func chunkLength() throws -> Int { try length(4, limit: ArchiveService.chunkLimit) }

    // MARK: - Writing

    private func write(_ entry: Entry) throws {
        switch entry.kind {
        case .file: try writeFile(entry)
        case .folder: try writeFolder(entry)
        case .link: try writeLink(entry)
        case .hardLink: try writeHardLink(entry)
        }
    }

    private func writeFile(_ entry: Entry) throws {
        let parent = try folder(entry.path.dropLast())
        let (fd, _) = try create(entry.path, in: parent) {
            openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        defer { close(fd) }
        try copyContents(into: fd, entry.path)
        try finish(fd, entry, mode: entry.mode & 0o777 & permissions)
    }

    /// A folder already made, by an earlier entry inside it or of the same name, is the same folder; it keeps the times
    /// of the latest entry that gives any, as tar does.
    private func writeFolder(_ entry: Entry) throws {
        let parent = try folder(entry.path.dropLast())
        let fd = try subfolder(entry.path, in: parent, creating: true, itsOwnEntry: true)
        defer { close(fd) }
        let key = Key(entry.path)
        let later = !entry.times.isEmpty && (folderTimes[key] != nil || remembering(Self.cost(entry.path) + 48))
        try finish(fd, entry, mode: ((entry.mode & 0o777) | 0o700) & permissions, times: !later)
        if later {
            folderEntries += 1
            folderTimes[key] = (entry.times, folderEntries)
        }
    }

    /// Where the link leads isn't checked here: `Archiver.check` refuses any that leads out of what's placed.
    private func writeLink(_ entry: Entry) throws {
        let parent = try folder(entry.path.dropLast())
        let target = entry.link.map { CChar(bitPattern: $0) } + [0]
        let (_, name) = try create(entry.path, in: parent) { name in
            target.withUnsafeBufferPointer { symlinkat($0.baseAddress!, parent, name) }
        }
        let fd = named(name) { openat(parent, $0, O_RDONLY | O_SYMLINK | O_CLOEXEC) }
        guard fd.result >= 0 else { throw failure(entry.path, fd.error) }
        defer { close(fd.result) }
        var info = stat()
        guard fstat(fd.result, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { throw failure(entry.path, ESTALE) }
        try finish(fd.result, entry, mode: nil)
    }

    /// A hard link to an item an earlier entry made. One that carries contents of its own (as new cpio and pax archives
    /// may) writes them into the file it shares, and its metadata applies; one that doesn't only shares the file, as tar
    /// takes it.
    private func writeHardLink(_ entry: Entry) throws {
        let linked = entry.linked
        // Its own descriptor: opening the entry's folder next could close a kept one.
        let source = fcntl(try folder(linked.dropLast(), creating: false), F_DUPFD_CLOEXEC, 0)
        guard source >= 0 else { throw failure(entry.path, errno) }
        defer { close(source) }
        let parent = try folder(entry.path.dropLast())
        let sourceData = latest[Key(linked)] ?? linked.last!
        // A "._" item beside its partner could be the system's file of that item's attributes.
        if attributesInFiles, let item = Archiver.attributedItem(of: sourceData), exists(Data(item), in: source) != false {
            throw failure(entry.path, EPERM)
        }
        let sourceName = sourceData.map { CChar(bitPattern: $0) } + [0]
        let (_, name) = try create(entry.path, in: parent) { name in
            sourceName.withUnsafeBufferPointer { linkat(source, $0.baseAddress!, parent, name, 0) }
        }
        let first = try chunkLength()
        guard first > 0 else { return }
        // The file it shares may already have read-only permissions; its own come after its contents.
        let writable = named(name) { fchmodat(parent, $0, 0o600, AT_SYMLINK_NOFOLLOW) }
        guard writable.result == 0 else { throw failure(entry.path, writable.error) }
        let fd = named(name) { openat(parent, $0, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC) }
        guard fd.result >= 0 else { throw failure(entry.path, fd.error) }
        defer { close(fd.result) }
        try copyContents(into: fd.result, entry.path, first: first)
        try finish(fd.result, entry, mode: entry.mode & 0o777 & permissions)
    }

    /// Makes a new item called `path.last` with `make`, or `name 2`, `name 3`… when that name is taken, the way Finder
    /// numbers a copy: nothing is ever replaced, not even an earlier entry of the same name (on a disk that ignores
    /// case, "Read Me" and "READ ME" are one name). A file's numbered name is remembered for the hard links to it, and
    /// a file is numbered only while the writer can remember it; a folder is numbered without an extension, unless it's
    /// a package ("Foo 2.app"). Numbering carries on from the last number any spelling of the name got, after trying the
    /// name itself.
    private func create(_ path: [Data], in parent: Int32, folder: Bool = false,
                        _ make: (UnsafePointer<CChar>) -> Int32) throws -> (result: Int32, name: Data) {
        let name = path.last!, key = Key(path)
        var number = 1, spellings: Key?
        while number <= 10_000 {
            let candidate = number == 1 ? name : String(validating: name, as: UTF8.self).map {
                Data(FileOps.name($0, adding: " \(number)", keepingExtension: !folder || Self.isPackage($0)).utf8)
            }
            guard let candidate else { break }
            let made = meetsAttributeFile(candidate, in: parent) ? (result: -1, error: EEXIST) : named(candidate, make)
            if made.result >= 0 {
                if let spellings {
                    nextNumber[spellings] = number + 1
                    if !folder { latest[key] = candidate }
                }
                return (made.result, candidate)
            }
            guard made.error == EEXIST else { throw failure(path, made.error) }
            if let spellings {
                number += 1
                nextNumber[spellings] = number
                continue
            }
            let taken = Self.spellings(path)
            guard folder || latest[key] != nil || remembering(Self.cost(path) + name.count + 48),
                  nextNumber[taken] != nil || remembering(Self.cost(taken.path) + 16) else { break }
            spellings = taken
            number = max(2, nextNumber[taken] ?? 2)
        }
        throw failure(path, EEXIST)
    }

    /// Whether `name` is in the opened `folder`, not followed if it's a link; nil when that can't be told. A name the disk
    /// can't hold, too long or not in its alphabet, isn't there.
    private func exists(_ name: Data, in folder: Int32) -> Bool? {
        var info = stat()
        let found = named(name) { fstatat(folder, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if found.result == 0 { return true }
        return [ENOENT, ENAMETOOLONG, EILSEQ, EINVAL].contains(found.error) ? false : nil
    }

    /// On a disk that keeps attributes in "._" files, whether an item made as `name` in the opened `folder` would meet its
    /// partner there, which counts as taking a taken name: made over a "._name", it would have the system take that file
    /// over or remove it, and made as "._x" beside "x", it would be taken for x's attributes, which Extract's check leaves
    /// to the system. The disk's own lookup finds a partner under any spelling it takes for the same name; one it can't
    /// tell about counts as there.
    private func meetsAttributeFile(_ name: Data, in folder: Int32) -> Bool {
        guard attributesInFiles else { return false }
        let attributeFile = Self.attributeFilePrefix + name
        let overAttributeFile = Archiver.attributedItem(of: attributeFile).map { Data($0) == name } == true
            && exists(attributeFile, in: folder) != false
        let besideItem = Archiver.attributedItem(of: name).map { exists(Data($0), in: folder) != false } ?? false
        return overAttributeFile || besideItem
    }

    /// Whether a folder of this name is a package, which keeps its extension.
    private static func isPackage(_ name: String) -> Bool {
        UTType(filenameExtension: (name as NSString).pathExtension, conformingTo: .directory)?.conforms(to: .package) == true
    }

    /// One key for the spellings of a path a disk may take for the same one, in case and in Unicode form.
    private static func spellings(_ path: [Data]) -> Key {
        Key(path.map { Data(String(decoding: $0, as: UTF8.self).lowercased().decomposedStringWithCanonicalMapping.utf8) })
    }

    /// About what keeping `path` takes up.
    private static func cost(_ path: [Data]) -> Int { path.reduce(64) { $0 + $1.count + 32 } }

    /// Whether `bytes` more still fit in what the writer may keep for later, counting them if they do.
    private func remembering(_ bytes: Int) -> Bool {
        guard bytes <= memory - remembered else { return false }
        remembered += bytes
        return true
    }

    /// The folder at `path` inside the root, opened one name at a time below the deepest folder already open, never
    /// following a link. With `creating`, a missing folder is made as an implied one, as tar makes it. It stays open for
    /// the entries after it: the caller doesn't close it, and keeps it only until the next folder it asks for.
    private func folder(_ path: ArraySlice<Data>, creating: Bool = true) throws -> Int32 {
        uses += 1
        var hasher = Hasher(), keys: [Int] = []
        for part in path {
            Key.combine(part, into: &hasher)
            let prefix = hasher
            keys.append(prefix.finalize())
        }
        var depth = path.count, fd = root
        while depth > 0 {
            if let open = folders[keys[depth - 1]], open.path.elementsEqual(path.prefix(depth)) {
                folders[keys[depth - 1]]?.used = uses
                fd = open.fd
                break
            }
            depth -= 1
        }
        while depth < path.count {
            let reached = Array(path.prefix(depth + 1))
            fd = try subfolder(reached, in: fd, creating: creating)
            if let replaced = folders[keys[depth]] {
                close(replaced.fd)
            } else if folders.count >= Self.openFolders, let oldest = folders.min(by: { $0.value.used < $1.value.used }) {
                close(oldest.value.fd)
                folders[oldest.key] = nil
            }
            folders[keys[depth]] = (reached, fd, uses)
            depth += 1
        }
        return fd
    }

    /// The folder `path` names in `parent`, opened without following a link, under the name it got: with `creating`,
    /// made when missing, and given a number when another item already has its name, as a file would get one. A link
    /// where a folder holding other entries should be refuses the archive, as tar refuses to write through it; for the
    /// folder's own entry, a link of its name is another item, as tar would replace it.
    private func subfolder(_ path: [Data], in parent: Int32, creating: Bool, itsOwnEntry: Bool = false) throws -> Int32 {
        let key = Key(path)
        let name = folderNames[key] ?? path.last!
        var opened = openFolder(name, in: parent)
        // A folder that would meet its "._" partner is numbered, below.
        let meets = opened.result < 0 && opened.error == ENOENT && creating && meetsAttributeFile(name, in: parent)
        if opened.result < 0, opened.error == ENOENT, creating, !meets {
            try makeRoom(for: 0)
            let made = named(name) { mkdirat(parent, $0, permissions) }
            guard made.result == 0 || made.error == EEXIST else { throw failure(path, made.error) }
            opened = openFolder(name, in: parent)
        }
        if opened.result >= 0 {
            guard folderNames[key] == nil else { return opened.result }
            var info = stat()
            guard fstat(opened.result, &info) == 0 else {
                let error = errno
                close(opened.result)
                throw failure(path, error)
            }
            guard numberedFolders.contains(info.st_ino) else { return opened.result }
            close(opened.result)
        } else if !meets {
            guard opened.error == ENOTDIR else { throw failure(path, opened.error) }
            var info = stat()
            if !itsOwnEntry, named(name, { fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }).result == 0,
               info.st_mode & S_IFMT == S_IFLNK {
                throw throughLink(path)
            }
        }
        guard creating, folderNames[key] == nil, remembering(Self.cost(path) + name.count + 48) else {
            throw fileAndFolder(path)
        }
        try makeRoom(for: 0)
        let (_, numbered) = try create(path, in: parent, folder: true) { mkdirat(parent, $0, permissions) }
        let fd = openFolder(numbered, in: parent)
        var info = stat()
        guard fd.result >= 0, fstat(fd.result, &info) == 0 else {
            if fd.result >= 0 { close(fd.result) }
            throw failure(path, fd.result >= 0 ? errno : fd.error)
        }
        folderNames[key] = numbered
        numberedFolders.insert(info.st_ino)
        return fd.result
    }

    private func openFolder(_ name: Data, in parent: Int32) -> (result: Int32, error: Int32) {
        named(name) { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
    }

    /// Mac metadata, then permissions, then times, which the other two could change. Times of a folder wait until
    /// nothing more is written inside it.
    private func finish(_ fd: Int32, _ entry: Entry, mode: mode_t?, times: Bool = true) throws {
        try apply(entry.attributes, to: fd, entry.path)
        if let mode, fchmod(fd, mode) != 0 { throw failure(entry.path, errno) }
        if times { try setTimes(entry.times, on: fd, entry.path) }
    }

    /// As copyfile puts them back when it unpacks them for tar, with no intent given: those the system keeps then,
    /// never an access list (Strata drops those), and one that can't be set fails the entry, except the mark only the
    /// system may set on what it installed.
    private func apply(_ attributes: [Attribute], to fd: Int32, _ path: [Data]) throws {
        for attribute in attributes where attribute.name != Self.accessList {
            guard named(attribute.name, { xattr_preserve_for_intent($0, 0) }).result == 1 else { continue }
            // A resource fork takes up the disk as contents do.
            try makeRoom(for: Int64(attribute.value.count))
            let applied = named(attribute.name) { name in
                attribute.value.isEmpty
                    ? withUnsafeBytes(of: 0) { fsetxattr(fd, name, $0.baseAddress, 0, 0, 0) }
                    : attribute.value.withUnsafeBytes { fsetxattr(fd, name, $0.baseAddress, $0.count, 0, 0) }
            }
            guard applied.result == 0 || (applied.error == EPERM && attribute.name == Self.installedMark) else {
                throw failure(path, applied.error)
            }
        }
    }

    /// As tar sets them: a time the archive doesn't give is when extracting started, and a creation time goes in first
    /// as the modification time, since setting an earlier one moves the creation time back with it.
    private func setTimes(_ times: Times, on fd: Int32, _ path: [Data]) throws {
        guard !times.isEmpty else { return }
        let accessed = times.accessed ?? started, modified = times.modified ?? started
        if let created = times.created, (created.tv_sec, created.tv_nsec) < (modified.tv_sec, modified.tv_nsec) {
            var stamps = [accessed, created]
            guard futimens(fd, &stamps) == 0 else { throw failure(path, errno) }
        }
        var stamps = [accessed, modified]
        guard futimens(fd, &stamps) == 0 else { throw failure(path, errno) }
    }

    private func copyContents(into fd: Int32, _ path: [Data], first: Int? = nil) throws {
        var length = try first ?? chunkLength()
        while length > 0 {
            guard !control.isCancelled else { throw CancellationError() }
            try makeRoom(for: Int64(length))
            var remaining = length
            while remaining > 0 {
                guard try fill() else { throw StreamEnded() }
                let count = min(remaining, end - start)
                try writeBuffered(count, to: fd, path)
                start += count
                remaining -= count
            }
            length = try chunkLength()
        }
    }

    private func writeBuffered(_ count: Int, to fd: Int32, _ path: [Data]) throws {
        try buffer.withUnsafeBytes { bytes in
            var offset = start
            while offset < start + count {
                let written = Darwin.write(fd, bytes.baseAddress! + offset, start + count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw failure(path, written < 0 ? errno : EIO) }
                offset += written
            }
        }
    }

    /// Before writing `bytes`, or making an item: stops, as the disk watchdog around tar did, when less than the reserve
    /// kept when extracting started would then be left. Anything as large as `checkedAfter` is checked before it's
    /// written.
    private func makeRoom(for bytes: Int64) throws {
        let taken = (max(bytes, 1) + block - 1) / block * block
        unchecked += taken
        // Until the space has been read once, it's read before every write; one that couldn't be read is read again.
        guard reserve == nil || unchecked >= checkedAfter, let space = space(root) else { return }
        if reserve == nil { watch(space) }
        unchecked = 0
        if let reserve, space.free - taken < reserve {
            throw Archiver.Failure(message: String(localized: "Stopped: the disk was running out of space."))
        }
    }

    /// The reserve kept free from here on, and how often the space is read again, from the disk as it is now.
    private func watch(_ space: (free: Int64, block: Int64)) {
        let reserve = Archiver.reserve(free: space.free)
        self.reserve = reserve
        checkedAfter = min(Self.checkedEvery, reserve / 4)
        block = max(1, space.block)
    }

    /// Calls `body` with `name` as a C string: its result, and the error it left.
    private func named(_ name: Data, _ body: (UnsafePointer<CChar>) -> Int32) -> (result: Int32, error: Int32) {
        let bytes = name.map { CChar(bitPattern: $0) } + [0]
        return bytes.withUnsafeBufferPointer { pointer in
            let result = body(pointer.baseAddress!)
            return (result, result < 0 ? errno : 0)
        }
    }

    // MARK: - Messages

    private func shown(_ path: [Data]) -> String {
        path.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/")
    }

    private func failure(_ path: [Data], _ error: Int32) -> Archiver.Failure {
        let reason = String(cString: strerror(error))
        return Archiver.Failure(message: String(localized: "“\(shown(path))” in the archive couldn’t be written (\(reason)), so nothing was extracted."))
    }

    private func fileAndFolder(_ path: [Data]) -> Archiver.Failure {
        Archiver.Failure(message: String(localized: "“\(shown(path))” is both a file and a folder in the archive, so nothing was extracted."))
    }

    private func throughLink(_ path: [Data]) -> Archiver.Failure {
        Archiver.Failure(message: String(localized: "This archive tries to write outside its folder (“\(shown(path))”), so it wasn’t extracted."))
    }
}
