import AppKit

extension Notification.Name {
    /// Posted after Strata empties the Trash or deletes something for good.
    static let trashChanged = Notification.Name("StrataTrashChanged")
}

/// Your Trash: each disk's Trash folder, where an item in it came from (for Put Back), and emptying it.
enum Trash {
    /// The startup disk's Trash, in your home folder.
    nonisolated static let home = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".Trash", directoryHint: .isDirectory).standardizedFileURL
    nonisolated private static let homePath = home.path
    /// Lowercased, for comparing paths the way the (case-insensitive) startup disk does.
    nonisolated private static let homePathLower = home.path.lowercased()
    nonisolated private static let uid = String(getuid())
    /// The home Trash's identity, so another spelling of its path (`~/.trash`, a link to it) is still the Trash.
    nonisolated private static let homeIdentity: (dev: dev_t, ino: ino_t)? = {
        var info = stat()
        return stat(homePath, &info) == 0 ? (info.st_dev, info.st_ino) : nil
    }()

    /// One disk's Trash and what's in it.
    struct Contents: Sendable {
        let folder: URL
        /// The disk's name ("Macintosh HD", "Backup").
        let disk: String
        let count: Int
    }

    /// Every Trash of yours: the home one and each other local disk's `.Trashes/<your user id>`. Only real folders
    /// count: a disk could carry a symlink there, and emptying must never reach anything outside the Trash. Network
    /// disks are left out (their server could swap a folder for a link between a check and a delete).
    nonisolated static func folders() -> [URL] {
        var result: [URL] = []
        if isRealFolder(home) { result.append(home) }
        let keys: [URLResourceKey] = [.volumeIsLocalKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for volume in volumes where volume.path != "/" {
            guard (try? volume.resourceValues(forKeys: Set(keys)))?.volumeIsLocal == true else { continue }
            let trashes = volume.appending(path: ".Trashes", directoryHint: .isDirectory)
            let mine = trashes.appending(path: uid, directoryHint: .isDirectory)
            if isRealFolder(trashes), isRealFolder(mine) { result.append(mine) }
        }
        return result
    }

    /// Whether `folder` is one of your Trash folders (judged by where it is, without listing the disks). Spellings
    /// differ only in case on most Mac disks, so names compare without it; a folder named like the home Trash is
    /// checked by identity.
    nonisolated static func isTrash(_ folder: URL) -> Bool {
        let folder = folder.standardizedFileURL
        let lower = folder.path.lowercased()
        if lower == homePathLower {
            var info = stat()
            return stat(folder.path, &info) == 0 && homeIdentity.map { $0.dev == info.st_dev && $0.ino == info.st_ino } ?? true
        }
        let trashes = folder.deletingLastPathComponent()
        guard folder.lastPathComponent == uid, trashes.lastPathComponent.lowercased() == ".trashes" else { return false }
        let volume = trashes.deletingLastPathComponent()
        return (try? volume.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
    }

    /// Whether `url` is a Trash however its path is spelled: through a link to a folder on the way, say. A link to a
    /// Trash is only a link.
    nonisolated static func isTrash(anySpelling url: URL) -> Bool {
        isTrash(url) || isTrash(url.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: url.lastPathComponent))
    }

    /// Whether `item` sits directly in a Trash (things inside a trashed folder can't be put back on their own).
    nonisolated static func contains(_ item: URL) -> Bool {
        isTrash(item.deletingLastPathComponent())
    }

    /// Whether `url` is in a Trash at any depth (any spelling of its path's case).
    nonisolated static func isInTrash(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path.lowercased()
        if path.hasPrefix(homePathLower + "/") { return true }
        // Other disks' Trashes: `/Volumes/<disk>/.Trashes/<uid>/…`.
        guard path.contains("/.trashes/") else { return false }
        var folder = url.standardizedFileURL.deletingLastPathComponent()
        while folder.path != "/" {
            if isTrash(folder) { return true }
            folder.deleteLastPathComponent()
        }
        return false
    }

    /// Whether the home Trash has anything in it (for its icon). Reads at most a few entries.
    nonisolated static var isHomeEmpty: Bool {
        guard let dir = opendir(homePath) else { return true }
        defer { closedir(dir) }
        while let entry = readdir(dir) {
            guard let name = DirectoryEntryName.read(entry) else { return false }
            if name != ".", name != "..", name != ".DS_Store" { return false }
        }
        return true
    }

    /// What every Trash holds, per disk.
    @concurrent
    static func contents() async -> [Contents] {
        folders().map { folder in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let volume = folder.path == homePath ? URL(fileURLWithPath: "/") : folder.deletingLastPathComponent().deletingLastPathComponent()
            let disk = (try? volume.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? volume.lastPathComponent
            return Contents(folder: folder, disk: disk, count: names.filter { $0 != ".DS_Store" }.count)
        }
    }

    // MARK: - Put Back

    /// Where each of `items` (directly in a Trash) was before it went there. History knows what Strata trashed; the
    /// Trash's records know what Finder and other apps trashed (Finder writes its records a little later). Items whose
    /// origin isn't known, or would be unsafe to restore to, are left out.
    static func originalLocations(of items: [URL]) async -> [URL: URL] {
        let items = items.filter(contains)
        guard !items.isEmpty else { return [:] }
        let moved = OperationLog.shared.movedFrom(items)
        var result: [URL: URL] = [:]
        var needRecords: [URL] = []
        for item in items {
            // History wins unless the item was put in the Trash again after Strata last put it there (by Finder, say).
            if let hit = moved[item.standardizedFileURL.path], !isInTrash(hit.from),
               hit.date.timeIntervalSince(arrived(item) ?? .distantPast) > -5 {
                result[item] = hit.from
            } else {
                needRecords.append(item)
            }
        }
        for (trash, inTrash) in Dictionary(grouping: needRecords, by: { $0.deletingLastPathComponent().standardizedFileURL }) {
            let (records, written) = await finderRecords(trash)
            for item in inTrash {
                // A record older than the item is about something else that once had its name. (Disks that keep no
                // such dates, like most USB sticks, can't tell: the record is taken.)
                guard let record = records[item.lastPathComponent],
                      arrived(item).map({ written.timeIntervalSince($0) > -2 }) ?? true,
                      let location = location(record, of: item, onDiskOf: trash) else { continue }
                result[item] = location
            }
        }
        return result
    }

    /// Where a record says `item` came from: its folder is relative to the root of the disk the Trash is on. Records are
    /// untrusted, so the result must stay on that disk without passing through a symlink, use plain names (never ".."),
    /// keep the item's extension, and not be in a Trash.
    nonisolated static func location(_ record: DSStore.PutBack, of item: URL, onDiskOf trash: URL) -> URL? {
        let parts = record.folder.split(separator: "/").map(String.init)
        let names = parts + [record.name]
        guard !record.name.isEmpty, !record.name.contains("/"),
              !names.contains(where: { $0 == "." || $0 == ".." || $0.contains("\0") }),
              (record.name as NSString).pathExtension.lowercased() == item.pathExtension.lowercased() else { return nil }
        // The home Trash is on the startup disk ("/"); any other is `<disk>/.Trashes/<uid>`.
        let base = trash.standardizedFileURL.path == homePath ? URL(fileURLWithPath: "/", isDirectory: true)
                                                              : trash.deletingLastPathComponent().deletingLastPathComponent()
        var info = stat()
        guard lstat(trash.path, &info) == 0 else { return nil }
        let device = info.st_dev
        var url = base
        var exists = true
        for part in parts {
            url.append(path: part, directoryHint: .isDirectory)
            // Existing folders on the way must be real folders on the Trash's disk; missing ones are made.
            guard exists else { continue }
            if lstat(url.path, &info) != 0 { exists = false; continue }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_dev == device else { return nil }
        }
        url.append(path: record.name)
        // Judged on the real path, so another spelling of a Trash's name ("Users/me/.TRASH/") can't slip through.
        return isInTrash(url) || isInTrash(canonical(url)) ? nil : url
    }

    /// `url` with its deepest existing folder resolved by the system (real case, no links), the rest appended.
    nonisolated private static func canonical(_ url: URL) -> URL {
        var existing = url.deletingLastPathComponent()
        var rest = [url.lastPathComponent]
        while existing.path != "/", access(existing.path, F_OK) != 0 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        guard let real = realpath(existing.path, nil) else { return url }
        defer { free(real) }
        var result = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        for part in rest { result.append(path: part) }
        return result
    }

    // MARK: - Emptying

    /// What emptying did: how many items went, and the items, or Trash folders, that couldn't (a locked file, say),
    /// with why.
    struct Emptied {
        var removed = 0
        var failures: [(url: URL, error: Error)] = []
    }

    /// Deletes everything in every Trash for good, off the main thread. Each Trash's records file goes too: its Put
    /// Back records would be stale.
    @concurrent
    static func empty() async -> Emptied {
        empty(folders())
    }

    /// Deletes everything in `trashes`, which must be Trash folders (see `folders()`). Each Trash is opened once, never
    /// through a link, and everything is deleted relative to that open folder: swapping a folder for a link while it
    /// runs can't redirect the deletion anywhere else. `listing` lists an open folder whole or fails.
    nonisolated static func empty(_ trashes: [URL],
                                  listing: (Int32) throws -> [String] = ChosenFile.names(in:)) -> Emptied {
        var emptied = Emptied()
        for folder in trashes {
            let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            // One that's gone meanwhile has nothing to empty.
            guard fd >= 0 else {
                let error = errno
                if error != ENOENT { emptied.failures.append(failure(folder, error)) }
                continue
            }
            defer { close(fd) }
            var listError: Int32 = 0
            for name in entries(fd, listing, error: &listError) {
                let error = removeTree(in: fd, name, listing: listing)
                // The Trash's records file isn't one of its items, and one that went meanwhile (emptied elsewhere, say)
                // wasn't deleted here and didn't fail.
                guard name != ".DS_Store", error != ENOENT else { continue }
                if error == 0 {
                    emptied.removed += 1
                } else {
                    emptied.failures.append(failure(folder.appending(path: name), error))
                }
            }
            if listError != 0 { emptied.failures.append(failure(folder, listError)) }
        }
        return emptied
    }

    nonisolated private static func failure(_ url: URL, _ code: Int32) -> (url: URL, error: Error) {
        (url, POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))
    }

    /// The names in an open folder: none from one that can't be listed whole, so that nothing in it is deleted as if
    /// the rest weren't there, and `error` says why. Never ENOENT, which says that an item itself is gone.
    nonisolated private static func entries(_ fd: Int32, _ listing: (Int32) throws -> [String],
                                            error: inout Int32) -> [String] {
        do {
            return try listing(fd)
        } catch let thrown {
            let code = (thrown as? POSIXError)?.code.rawValue ?? EIO
            error = code == ENOENT ? EIO : code
            return []
        }
    }

    /// Deletes `name` in the open folder `parent`: a file or link directly, a folder after its contents (opened without
    /// following links). Returns 0, or the first error (a locked file, say).
    nonisolated private static func removeTree(in parent: Int32, _ name: String, depth: Int = 0,
                                               listing: (Int32) throws -> [String]) -> Int32 {
        if unlinkat(parent, name, 0) == 0 { return 0 }
        let unlinkError = errno
        guard depth < 128 else { return ELOOP }
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
           (info.st_mode & S_IFMT) == S_IFDIR,
           info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) == 0,
           (info.st_mode & S_IRWXU) != S_IRWXU {
            _ = fchmodat(parent, name, (info.st_mode & 0o7777) | S_IRWXU, AT_SYMLINK_NOFOLLOW)
        }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        // Not a folder: why the file itself couldn't be deleted (locked, say).
        guard fd >= 0 else { return errno == ENOTDIR || errno == ELOOP ? unlinkError : errno }
        var firstError: Int32 = 0
        for child in entries(fd, listing, error: &firstError) {
            let error = removeTree(in: fd, child, depth: depth + 1, listing: listing)
            // One that went meanwhile never stands for a folder that's gone too, hiding why a sibling stayed.
            if firstError == 0, error != ENOENT { firstError = error }
        }
        close(fd)
        // Gone after all: it held nothing, whatever its listing said.
        guard unlinkat(parent, name, AT_REMOVEDIR) != 0 else { return 0 }
        return firstError != 0 ? firstError : errno
    }

    // MARK: - Private

    nonisolated private static func isRealFolder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// When `item` arrived where it is: the date it was added to its folder, or, on disks that don't keep that (FAT,
    /// exFAT), when its attributes last changed (a move updates it).
    nonisolated private static func arrived(_ item: URL) -> Date? {
        let values = try? item.resourceValues(forKeys: [.addedToDirectoryDateKey, .attributeModificationDateKey])
        return values?.addedToDirectoryDate ?? values?.attributeModificationDate
    }

    /// Put Back records for one Trash and when they were written, read again only when the records file changes.
    private static var recordCache: [String: (modified: Date, records: [String: DSStore.PutBack])] = [:]

    private static func finderRecords(_ trash: URL) async -> (records: [String: DSStore.PutBack], written: Date) {
        let file = trash.appending(path: ".DS_Store")
        guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return ([:], .distantPast) }
        if let cached = recordCache[trash.path], cached.modified == modified { return (cached.records, modified) }
        let records = await parse(file)
        recordCache[trash.path] = (modified, records)
        return (records, modified)
    }

    @concurrent
    private static func parse(_ file: URL) async -> [String: DSStore.PutBack] {
        DSStore.putBackRecords(at: file)
    }
}
