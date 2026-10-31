import CryptoKit
import Foundation

nonisolated extension TransferEngine {
    // MARK: - Small operations

    /// `rename(2)` that refuses to overwrite. Returns 0 or an errno.
    package static func rename(_ source: URL, to destination: URL, supportsExclusiveRename: Bool = true) -> Int32 {
        if !supportsExclusiveRename { errno = ENOTSUP } else
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return 0 }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else { return code }
        // File systems without RENAME_EXCL: claim the name with an exclusive placeholder, then replace only that.
        var srcInfo = stat()
        guard lstat(source.path, &srcInfo) == 0 else { return errno }
        let isFolder = (srcInfo.st_mode & S_IFMT) == S_IFDIR
        let placeholderIdentity: FileIdentity?
        if isFolder {
            if mkdir(destination.path, 0o700) != 0 { return errno }
            placeholderIdentity = FileIdentity.read(destination.path)
        } else {
            let fd = open(destination.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            if fd < 0 { return errno }
            var dstInfo = stat()
            placeholderIdentity = fstat(fd, &dstInfo) == 0 ? FileIdentity.from(dstInfo) : nil
            close(fd)
        }
        if Darwin.rename(source.path, destination.path) == 0 { return 0 }
        let error = errno
        if let placeholderIdentity, FileIdentity.read(destination.path) == placeholderIdentity {
            if isFolder { rmdir(destination.path) } else { unlink(destination.path) }
        }
        return error
    }

    package static func trash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }

    /// Removes `url` while it's what the operation made (`created`, by path): in a folder, only what the operation made,
    /// opened from `root`'s folder down without following links. Anything else stays.
    package static func removeIfPresent(_ url: URL, in root: URL? = nil, created: [String: FileIdentity],
                                keepRootDirectory: Bool = false) {
        guard !created.isEmpty, let dirFD = openOwnedParent(of: url, in: root ?? url, created: created) else { return }
        defer { close(dirFD) }
        removeOwned(url, in: dirFD, created: created, keepRootDirectory: keepRootDirectory)
    }

    /// The folder `url` is in, opened from `base`'s folder down without following links, each folder below `base`'s
    /// one the operation made (`created`); nil when one isn't, or `url` isn't inside `base`.
    private static func openOwnedParent(of url: URL, in base: URL, created: [String: FileIdentity]) -> Int32? {
        let baseParent = base.deletingLastPathComponent().path
        var dirFD = open(baseParent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dirFD >= 0 else { return nil }
        guard url.path != base.path else { return dirFD }
        let prefix = base.path == "/" ? "/" : base.path + "/"
        guard url.path.hasPrefix(prefix) else {
            close(dirFD)
            return nil
        }
        let relativeParent = String(url.deletingLastPathComponent().path.dropFirst(baseParent.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var currentPath = baseParent
        for component in relativeParent.split(separator: "/").map(String.init) {
            currentPath = (currentPath as NSString).appendingPathComponent(component)
            guard let expected = created[currentPath] else {
                close(dirFD)
                return nil
            }
            let nextFD = openat(dirFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(dirFD)
            guard nextFD >= 0 else { return nil }
            var info = stat()
            guard fstat(nextFD, &info) == 0, FileIdentity.from(info) == expected else {
                close(nextFD)
                return nil
            }
            dirFD = nextFD
        }
        return dirFD
    }

    /// Removes `url` from its open folder `dirFD` while it's the item the operation made: a file or link directly, a
    /// folder through `removeOwnedTree`.
    private static func removeOwned(_ url: URL, in dirFD: Int32, created: [String: FileIdentity], keepRootDirectory: Bool) {
        let targetName = url.lastPathComponent
        let targetPath = url.path
        guard let expectedTarget = created[targetPath] else { return }
        var targetInfo = stat()
        guard fstatat(dirFD, targetName, &targetInfo, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity.from(targetInfo) == expectedTarget else {
            return
        }
        if targetInfo.st_mode & S_IFMT != S_IFDIR {
            if !keepRootDirectory { _ = unlinkat(dirFD, targetName, 0) }
            return
        }
        let rootDirFD = openat(dirFD, targetName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDirFD >= 0 else { return }
        var openedInfo = stat()
        guard fstat(rootDirFD, &openedInfo) == 0, FileIdentity.from(openedInfo) == expectedTarget else {
            close(rootDirFD)
            return
        }
        removeOwnedTree(rootDirFD, named: targetName, at: targetPath, in: dirFD, created: created, keep: keepRootDirectory)
    }

    /// Removes what in the open folder `rootFD` the operation made, depth first, each folder opened without following
    /// links and checked against `created` before anything in it goes; then the folder itself, unless `keep`. Closes
    /// `rootFD`, never `dirFD`.
    private static func removeOwnedTree(_ rootFD: Int32, named name: String, at path: String, in dirFD: Int32,
                                        created: [String: FileIdentity], keep: Bool) {
        var stack: [(parentFD: Int32, fd: Int32, name: String, path: String, expanded: Bool, keep: Bool)] = [
            (parentFD: dirFD, fd: rootFD, name: name, path: path, expanded: false, keep: keep)
        ]
        while let frame = stack.popLast() {
            if !frame.expanded {
                let currentFD: Int32
                if frame.fd >= 0 {
                    currentFD = frame.fd
                } else {
                    let opened = openat(frame.parentFD, frame.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard opened >= 0 else { continue }
                    var openedChild = stat()
                    guard let expectedChild = created[frame.path],
                          fstat(opened, &openedChild) == 0, FileIdentity.from(openedChild) == expectedChild else {
                        close(opened)
                        continue
                    }
                    currentFD = opened
                }
                var dirInfo = stat()
                if !frame.keep, fstat(currentFD, &dirInfo) == 0, (dirInfo.st_mode & S_IRWXU) != S_IRWXU {
                    _ = fchmod(currentFD, (dirInfo.st_mode & 0o7777) | S_IRWXU)
                }
                stack.append((parentFD: frame.parentFD, fd: currentFD, name: frame.name,
                              path: frame.path, expanded: true, keep: frame.keep))
                let frame = (parentFD: frame.parentFD, fd: currentFD, name: frame.name, path: frame.path, expanded: false, keep: frame.keep)
                for childName in Archiver.entries(frame.fd) {
                    let childPath = (frame.path as NSString).appendingPathComponent(childName)
                    guard let expectedChild = created[childPath] else { continue }
                    var childInfo = stat()
                    guard fstatat(frame.fd, childName, &childInfo, AT_SYMLINK_NOFOLLOW) == 0,
                          FileIdentity.from(childInfo) == expectedChild else { continue }
                    if childInfo.st_mode & S_IFMT == S_IFDIR {
                        stack.append((parentFD: frame.fd, fd: -1, name: childName,
                                      path: childPath, expanded: false, keep: false))
                    } else {
                        _ = unlinkat(frame.fd, childName, 0)
                    }
                }
            } else {
                close(frame.fd)
                if !frame.keep { _ = unlinkat(frame.parentFD, frame.name, AT_REMOVEDIR) }
            }
        }
    }

    /// The first difference between `source` and its copy (an item added, or a file whose size or modification date
    /// changed after it was copied), or nil when the copy has everything the original has.
    package static func changedSinceCopy(_ source: URL, copy: URL) -> String? {
        let root = source.path
        let unchecked = String(localized: "it couldn’t be checked", comment: "Why a moved item’s original was kept, in parentheses")
        guard let cpath = strdup(root) else { return unchecked }
        defer { free(cpath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return unchecked }
        defer { fts_close(fts) }
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_DP { continue }
            if info == FTS_DNR || info == FTS_ERR || info == FTS_NS { return unchecked }
            let path = String(cString: entry.pointee.fts_path)
            let relative = path.count > root.count ? String(path.dropFirst(root.count)) : ""
            let name = relative.isEmpty ? source.lastPathComponent : String(relative.dropFirst())
            var original = stat(), copied = stat()
            guard lstat(path, &original) == 0 else { continue }   // Removed meanwhile: nothing to lose.
            guard lstat(copy.path + relative, &copied) == 0,
                   original.st_mode & S_IFMT == copied.st_mode & S_IFMT else {
                return String(localized: "“\(name)” is new", comment: "Why a moved item’s original was kept, in parentheses")
            }
            // An edit after the copy makes the original newer. Some disks keep coarser dates (FAT: 2 seconds, nothing
            // before 1980), so only a clearly newer original, or a different size, counts.
            let (grace, overflow) = copied.st_mtimespec.tv_sec.addingReportingOverflow(2)
            if original.st_mode & S_IFMT == S_IFREG,
               original.st_size != copied.st_size || (!overflow && original.st_mtimespec.tv_sec > grace) {
                return String(localized: "“\(name)” was modified", comment: "Why a moved item’s original was kept, in parentheses")
            }
            if original.st_mode & S_IFMT == S_IFLNK, readLink(path) != readLink(copy.path + relative) {
                return String(localized: "“\(name)” was modified", comment: "Why a moved item’s original was kept, in parentheses")
            }
        }
        return nil
    }

    package static var changedSince: String { String(localized: "The items have moved or been changed since.") }

    /// Removes the original after a cross-volume move. Returns an error message, or nil on success.
    static func removeSource(_ url: URL, destination: URL? = nil, landed: FileIdentity? = nil,
                                     sourceParent: TransferRetryTarget.PathIdentity? = nil,
                                     sourceIdentities: [String: FileIdentity] = [:]) -> String? {
        if let destination, let landed, FileIdentity.read(destination.path) != landed {
            let reason = describe(EACCES)
            return String(localized: "Copied, but the original couldn’t be removed: \(reason)")
        }
        if let sourceParent, FileIdentity.read(sourceParent.path) != sourceParent.identity {
            let reason = describe(EACCES)
            return String(localized: "Copied, but the original couldn’t be removed: \(reason)")
        }
        let owned = sourceIdentities.isEmpty ? snapshotIdentities(url) : sourceIdentities
        guard let rootID = owned[url.path], FileIdentity.read(url.path) == rootID else {
            guard exists(url) else { return nil }
            let reason = describe(EACCES)
            return String(localized: "Copied, but the original couldn’t be removed: \(reason)")
        }
        for (path, expected) in owned {
            if let current = FileIdentity.read(path), current != expected {
                let reason = describe(EACCES)
                return String(localized: "Copied, but the original couldn’t be removed: \(reason)")
            }
        }
        removeIfPresent(url, in: url, created: owned)
        guard !exists(url) else {
            let reason = describe(EACCES)
            return String(localized: "Copied, but the original couldn’t be removed: \(reason)")
        }
        return nil
    }

    /// A folder that isn't a package (apps and bundles are replaced, never merged into).
    package static func isPlainFolder(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        return (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true
    }

    /// One copy a merge needs: `decision` is nil (new item), `.replace` (incoming is newer) or `.keepBoth` (a file
    /// meets a folder).
    package struct MergeStep: Sendable {
        package let source: URL
        package let destination: URL
        package let decision: ConflictDecision?
    }

    /// What merging folder `source` into folder `destination` copies: everything missing, subfolders merged in turn,
    /// and same-named items only where the incoming one is newer.
    package static func mergePlan(_ source: URL, into destination: URL) -> [MergeStep] {
        hooks.beforeMergePlan?(source)
        var steps: [MergeStep] = []
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []).sorted()
        for name in names where name != ".DS_Store" {
            let from = source.appending(path: name), to = destination.appending(path: name)
            var incoming = stat(), existing = stat()
            guard lstat(from.path, &incoming) == 0 else { continue }
            guard lstat(to.path, &existing) == 0 else {
                steps.append(MergeStep(source: from, destination: to, decision: nil))
                continue
            }
            let bothFolders = isPlainFolder(from) && isPlainFolder(to)
            if bothFolders {
                steps += mergePlan(from, into: to)
            } else if (incoming.st_mode & S_IFMT == S_IFDIR) != (existing.st_mode & S_IFMT == S_IFDIR) {
                steps.append(MergeStep(source: from, destination: to, decision: .keepBoth))
            } else if incoming.st_mtimespec.tv_sec > existing.st_mtimespec.tv_sec {
                steps.append(MergeStep(source: from, destination: to, decision: .replace))
            }
        }
        return steps
    }

    package static func temporaryURL(for destination: URL) -> URL {
        let token = UUID().uuidString.prefix(8)
        // ".<name>.strata-XXXXXXXX" must stay within the 255-byte name limit.
        let name = fitting(destination.lastPathComponent, maxBytes: 255 - 17)
        return destination.deletingLastPathComponent().appending(path: ".\(name).strata-\(token)")
    }

    /// `name` cut (at a character boundary) to at most `maxBytes` of UTF-8.
    package static func fitting(_ name: String, maxBytes: Int) -> String {
        guard name.utf8.count > maxBytes else { return name }
        var result = ""
        for character in name {
            guard result.utf8.count + String(character).utf8.count <= maxBytes else { break }
            result.append(character)
        }
        return result
    }

    package static func describe(_ code: Int32) -> String {
        switch code {
        case EACCES, EPERM: String(localized: "You don’t have permission")
        case ENOENT: String(localized: "The item couldn’t be found")
        case ENOSPC: String(localized: "The disk is full")
        case EEXIST: String(localized: "An item with the same name already exists")
        case EROFS: String(localized: "The disk is read-only")
        case ENAMETOOLONG: String(localized: "The name is too long")
        case EXDEV: String(localized: "It’s on a different disk")
        default: String(cString: strerror(code))
        }
    }

    static func trashMessage(_ url: URL, _ error: Error) -> String {
        String(localized: "“\(url.lastPathComponent)” couldn’t be moved to the Trash, so it wasn’t replaced")
    }
}
