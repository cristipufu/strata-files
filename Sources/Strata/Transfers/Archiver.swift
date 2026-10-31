import Foundation
import os
import StrataArchiveClient

/// Compress (zip, like Finder) and extract (like Archive Utility), with the care an archive from anywhere needs:
/// - The archive is parsed only by a sandboxed worker of the archive service. Strata writes what it sends into a private
///   folder on the destination's disk, never outside it or through a link (see `ArchiveWriter`).
/// - The result is checked before it's moved into place: links must stay inside what's placed, special files are dropped,
///   setuid bits cleared, and anything that can't be checked stops the extraction.
/// - The disk's free space is checked first and watched while extracting, so an archive bomb can't fill it.
package nonisolated enum Archiver {
    private static let log = Logger(subsystem: "dev.strata.app", category: "archives")

    package struct Failure: LocalizedError, Equatable {
        package let message: String
        package var errorDescription: String? { message }
    }

    /// What a survey of an archive says before it's extracted; its counts are lower bounds when it didn't finish.
    package typealias Inspection = PreviewArchiveSurvey

    /// Progress and cancellation, shared with the job that runs it.
    package final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var reader: PipeReader?
        private var cancelled = false
        private var done = 0

        package var isCancelled: Bool { lock.withLock { cancelled } }
        /// Entries written so far.
        package var entriesDone: Int { lock.withLock { done } }

        package func cancel() {
            let (process, reader) = lock.withLock { () -> (Process?, PipeReader?) in
                cancelled = true
                return (self.process, self.reader)
            }
            if let process, process.isRunning { process.terminate() }
            reader?.stop()
        }

        fileprivate func attach(_ process: Process?) { lock.withLock { self.process = process } }
        /// The read Extract writes from, which cancelling stops.
        fileprivate func attach(reader: PipeReader?) { lock.withLock { self.reader = reader } }
        package func advance(_ count: Int) { lock.withLock { done += count } }
    }

    /// Kept free while extracting: a tenth of what's free, at most 1 GB, so small disks can still take small archives.
    package static func reserve(free: Int64) -> Int64 {
        min(1 << 30, max(0, free) / 10)
    }

    /// The disk holding `fd` right now, for the watchdog: the space actually free (not counting what the system could
    /// purge), and its allocation block, the least anything written there takes up.
    package static func space(of fd: Int32) -> (free: Int64, block: Int64)? {
        var info = statfs()
        guard fstatfs(fd, &info) == 0 else { return nil }
        return (Int64(clamping: info.f_bavail).saturatingMultiply(Int64(info.f_bsize)), Int64(info.f_bsize))
    }

    /// Free space on `url`'s disk, read fresh each time (a URL caches what it was first told).
    package static func availableSpace(onDiskOf url: URL) -> Int64? {
        let fresh = URL(fileURLWithPath: url.path)
        let values = try? fresh.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    // MARK: - Compress

    /// Zips `items` next to the first one: `Name.zip` for one item, `Archive.zip` for several (a taken name gets a
    /// number). Returns the zip.
    package static func compress(_ items: [URL], copies: CopyProviders, control: Control) throws -> URL {
        guard let first = items.first else { throw Failure(message: String(localized: "Nothing to compress.")) }
        let fm = FileManager.default
        let folder = first.deletingLastPathComponent()
        try requireWritable(folder)
        try requireOutsideCopies(folder, copies: copies)
        let name = items.count == 1 ? first.lastPathComponent + ".zip"
            // The name is translated; the extension stays .zip whatever the translation.
            : FileOps.nameText(String(localized: "Archive", comment: "Name of the zip made from several items, as Finder names it (“Archive.zip”); the .zip is added"),
                               english: "Archive") + ".zip"
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        defer { removeTree(work) }
        let zip = work.appending(path: name)
        if items.count == 1, !isSymlink(first) {
            try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", "-V", first.path, zip.path],
                    control: control)
        } else {
            // ditto takes one source (and would follow a lone link): gather the items in a folder first. On APFS these
            // copies are clones, instant and free; links stay links; the folder's own name isn't stored.
            let staging = work.appending(path: "Archive", directoryHint: .isDirectory)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            for item in items {
                guard !control.isCancelled else { throw CancellationError() }
                try fm.copyItem(at: item, to: uniqueURL(staging.appending(path: item.lastPathComponent)))
            }
            try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "-V", staging.path, zip.path],
                    control: control)
        }
        return try place(zip, in: folder, as: name)
    }

    // MARK: - Extract

    /// Surveys `archive` in the archive service's sandboxed worker to learn its size and whether it's encrypted. A
    /// link to an archive surveys the archive, which is what is extracted. Doesn't throw: a survey that didn't finish
    /// comes back incomplete, with what it counted so far. Runs off the main thread.
    @concurrent
    package static func inspect(_ archive: URL) async -> Inspection {
        guard let source = try? PreviewArchiveSource(archive.resolvingSymlinksInPath()),
              let survey = try? await PreviewArchiveReader.survey(source, timeout: 30) else { return Inspection() }
        return survey
    }

    /// Extracts `archive` into `folder` like Archive Utility: one top-level item keeps its name; several go in a folder
    /// named after the archive. Taken names get a number. Returns what was created.
    package static func extract(_ archive: URL, inspection: Inspection, into folder: URL, copies: CopyProviders,
                        control: Control) throws -> URL {
        let fm = FileManager.default
        try requireWritable(folder)
        try requireOutsideCopies(folder, copies: copies)
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        defer { removeTree(work) }
        let root = work.appending(path: "contents", directoryHint: .isDirectory)
        try unpack(archive, inspection: inspection, into: root, control: control)
        let top = try listed(root.path, keepingAttributes: keepsAttributes(root.path)).map { root.appending(path: $0) }
        guard let only = top.first else { throw Failure(message: String(localized: "“\(archive.lastPathComponent)” is empty.")) }
        if top.count == 1, !only.lastPathComponent.hasPrefix(".") {
            // What's placed is that one item, so links inside it must stay inside it, and it can't be a link itself.
            guard !isSymlink(only) else {
                throw Failure(message: String(localized: "“\(archive.lastPathComponent)” holds only a link, so it wasn’t extracted."))
            }
            try check(only, control: control, quarantine: quarantine(of: archive))
            return try place(only, in: folder, as: only.lastPathComponent)
        }
        try check(root, control: control, quarantine: quarantine(of: archive))
        return try place(root, in: folder, as: baseName(archive))
    }

    /// Extracts `archive`'s contents into the new folder `destination` (for browsing an archive as a folder).
    package static func extractContents(_ archive: URL, inspection: Inspection, to destination: URL,
                                control: Control) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try requireWritable(parent)
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: parent, create: true)
        defer { removeTree(work) }
        let root = work.appending(path: "contents", directoryHint: .isDirectory)
        try unpack(archive, inspection: inspection, into: root, control: control)
        try check(root, control: control, quarantine: quarantine(of: archive))
        // The copy's place is new: never replace what's there.
        guard renamex_np(root.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// The archive's name without its archive extensions ("Photos.tar.gz" → "Photos").
    package static func baseName(_ archive: URL) -> String {
        let name = archive.lastPathComponent
        let lower = name.lowercased()
        var base = (name as NSString).deletingPathExtension
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz", ".tar.lzma", ".tar.z"] where lower.hasSuffix(suffix) {
            base = String(name.dropLast(suffix.count))
        }
        // ".zip" and "..zip" have no extension to NSString (they're hidden names), but it's still the archive's.
        if base == name, let dot = name.lastIndex(of: ".") { base = String(name[..<dot]) }
        // Never a name that isn't one: "", ".", ".." (".tar.gz", "...tar.gz").
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard trimmed.isEmpty else { return base }
        return FileOps.nameText(String(localized: "Archive", comment: "Name of the folder extracted from an archive whose own name can’t be used"),
                                english: "Archive")
    }

    private static func unpack(_ archive: URL, inspection: Inspection, into root: URL,
                               control: Control) throws {
        if inspection.encrypted { throw passwordProtected(archive) }
        let disk = root.deletingLastPathComponent()
        // If even what the survey knows the archive holds doesn't fit, the archive won't.
        if let atLeast = inspection.lowerBound, let free = availableSpace(onDiskOf: disk),
           atLeast > free - reserve(free: free) {
            let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
            let needed = format(inspection.bytes), usable = format(max(0, free - reserve(free: free)))
            throw Failure(message: String(localized: "There isn’t enough space to extract “\(archive.lastPathComponent)”: it needs \(needed), and \(usable) can be used."))
        }
        // `root`'s parent is a private folder; `root` itself becomes the extracted folder, so it gets usual permissions,
        // which bound what anything inside gets.
        guard mkdir(root.path, 0o777) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let folder = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(folder) }
        var info = stat()
        guard fstat(folder, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var complete = false
        let status: ArchiveService.Status
        do {
            // A link to an archive extracts the archive, which mustn't change while it's read.
            let source = try PreviewArchiveSource(archive.resolvingSymlinksInPath())
            let file = try source.open()
            defer { try? file.close() }
            let reader = try PipeReader()
            control.attach(reader: reader)
            defer { control.attach(reader: nil) }
            // A Stop that came before the reader was attached would have found nothing to stop.
            guard !control.isCancelled else { throw CancellationError() }
            status = try PreviewArchiveReader.unpack(file, reader: reader) { output in
                complete = try ArchiveWriter.write(into: folder, permissions: info.st_mode, control: control) {
                    try reader.readSome(output, into: $0)
                }
            }
            try source.verify(file)
        } catch let error as POSIXError {
            log.info("An archive couldn't be extracted: \(error.localizedDescription, privacy: .public)")
            throw Failure(message: PreviewArchiveError.unreadable.localizedDescription)
        }
        if let failure = failure(complete: complete, status: status, archive: archive) { throw failure }
        try checkedPermissions(root.path, 0o700)
    }

    /// Why Extract's read of `archive` failed, if it did. A stream that reached its end mark is complete whatever the
    /// service could still say about its worker, which sends that mark only once it has read everything.
    package static func failure(complete: Bool, status: ArchiveService.Status, archive: URL) -> Failure? {
        guard !complete else { return nil }
        switch PreviewArchiveReader.error(for: status) {
        case .password: return passwordProtected(archive)
        case .limit: return pastLimits(archive)
        case let error?: return Failure(message: error.localizedDescription)
        case nil: return Failure(message: PreviewArchiveError.unreadable.localizedDescription)
        }
    }

    private static func pastLimits(_ archive: URL) -> Failure {
        Failure(message: String(localized: "“\(archive.lastPathComponent)” goes past the limits Strata sets for reading archives, so it wasn’t extracted."))
    }

    private static func passwordProtected(_ archive: URL) -> Failure {
        Failure(message: ArchiveLister.passwordProtected(archive.lastPathComponent))
    }

    /// Everything in `boundary` (a folder, or a single file) must stay inside it: a link may only point within it,
    /// resolved step by step from where the link sits (a ".." that would leave the boundary refuses it, through other
    /// links too). Special files (pipes, devices, sockets) are dropped, setuid/setgid bits and access lists cleared.
    /// Folders are made readable as they're walked, so none can hide anything; whatever can't be checked stops the
    /// extraction.
    ///
    /// `quarantine`: the archive's own quarantine mark (it was downloaded). Every extracted item gets exactly that mark,
    /// replacing any the archive itself carried (a crafted one could claim an app was already approved), so Gatekeeper
    /// checks whatever came inside. If an item can't be marked, nothing is extracted.
    package static func check(_ boundary: URL, control: Control? = nil, quarantine: Data? = nil) throws {
        let rootPath = boundary.path
        var info = stat()
        guard lstat(rootPath, &info) == 0 else { throw Failure(message: String(localized: "The extracted files couldn’t be checked.")) }
        try clearFlagsAndAccessList(rootPath)
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            if info.st_mode & (S_ISUID | S_ISGID | S_ISVTX) != 0 || (quarantine != nil && info.st_mode & S_IWUSR == 0) {
                try checkedPermissions(rootPath, (info.st_mode & ~(S_ISUID | S_ISGID | S_ISVTX) & 0o7777) | (quarantine != nil ? S_IWUSR : 0))
            }
            if let quarantine { try markQuarantined(rootPath, quarantine) }
            return
        case S_IFDIR:
            try checkedPermissions(rootPath, (info.st_mode & 0o7777 & ~(S_ISUID | S_ISGID | S_ISVTX)) | S_IRWXU)
            if let quarantine { try markQuarantined(rootPath, quarantine) }
        default:
            throw Failure(message: String(localized: "The archive holds nothing that can be extracted safely."))
        }
        var seen = 0, folders = [""]
        let keepingAttributes = keepsAttributes(rootPath)
        while let folder = folders.popLast() {
            for name in try listed(folder.isEmpty ? rootPath : rootPath + "/" + folder, keepingAttributes: keepingAttributes) {
                seen += 1
                if seen % 256 == 0, control?.isCancelled == true { throw CancellationError() }
                let relative = folder.isEmpty ? name : folder + "/" + name
                if try checkItem(relative, in: rootPath, quarantine: quarantine) { folders.append(relative) }
            }
        }
    }

    /// Every name in a folder being checked, or the check fails. On a disk that doesn't keep extended attributes itself
    /// (FAT, exFAT, some shares), the system keeps an item's in a "._name" file beside it: those are the system's, not
    /// the archive's, and can't even take a quarantine mark.
    private static func listed(_ path: String, keepingAttributes: Bool) throws -> [String] {
        let names: [String]
        do {
            names = try self.names(inFolderAt: path)
        } catch {
            throw Failure(message: String(localized: "The extracted files couldn’t all be checked (\(error.localizedDescription)), so nothing was extracted."))
        }
        guard !keepingAttributes else { return names }
        let attributeFiles = attributeFiles(in: names) { name in
            var info = stat()
            return lstat(path + "/" + name, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
        }
        return names.filter { !attributeFiles.contains($0) }
    }

    /// Of `names`, those the system would keep another's extended attributes in: a plain file named for an item beside it.
    package static func attributeFiles(in names: [String], isFile: (String) -> Bool) -> Set<String> {
        let all = Set(names.map { Array($0.utf8) })
        return Set(names.filter { name in attributedItem(of: name.utf8).map { all.contains($0) } == true && isFile(name) })
    }

    /// The item whose attributes a disk that keeps them in "._" files keeps in a file called `name`: "x" for "._x",
    /// spelled with the very same bytes, as the system names the file after its item. Nil for any other name: no "._"
    /// file takes attributes, so "._._x" is never one, and neither are "._." and "._..".
    package static func attributedItem(of name: some Collection<UInt8>) -> [UInt8]? {
        let prefix = Array("._".utf8)
        guard name.starts(with: prefix) else { return nil }
        let item = Array(name.dropFirst(2))
        return item.isEmpty || item.starts(with: prefix) || item == Array(".".utf8) || item == Array("..".utf8) ? nil : item
    }

    /// Whether the disk holding `path` keeps extended attributes itself; one it can't tell counts as keeping them, so
    /// that every name is checked.
    private static func keepsAttributes(_ path: String) -> Bool {
        attributesKept { getattrlist(path, &$0, $1, $2, 0) } ?? true
    }

    /// A disk that can't tell counts as keeping them in files, so that Extract's writer numbers what could be taken for
    /// them.
    package static func attributesInFiles(of fd: Int32) -> Bool {
        !(attributesKept { fgetattrlist(fd, &$0, $1, $2, 0) } ?? false)
    }

    /// Nil when the disk can't tell.
    private static func attributesKept(reading: (inout attrlist, UnsafeMutableRawPointer?, Int) -> Int32) -> Bool? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        // The returned length, then the volume's capabilities and which of them it reports.
        var reply = [UInt32](repeating: 0, count: 9)
        let size = reply.count * MemoryLayout<UInt32>.size
        guard reply.withUnsafeMutableBytes({ reading(&request, $0.baseAddress, size) }) == 0 else { return nil }
        let interfaces = Int(VOL_CAPABILITIES_INTERFACES), native = UInt32(VOL_CAP_INT_EXTENDED_ATTR)
        let capabilities = reply[1 + interfaces], valid = reply[5 + interfaces]
        guard valid & native != 0 else { return nil }
        return capabilities & native != 0
    }

    /// Checks one item inside the boundary at `rootPath`; whether it's a folder to check inside.
    private static func checkItem(_ relative: String, in rootPath: String, quarantine: Data?) throws -> Bool {
        let path = rootPath + "/" + relative
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw Failure(message: String(localized: "“\(relative)” in the archive couldn’t be checked, so nothing was extracted."))
        }
        try clearFlagsAndAccessList(path)
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            let parent = relative.split(separator: "/").dropLast().map(String.init)
            var budget = 4096
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
                  resolve(target, from: parent, in: rootPath, hops: 0, budget: &budget) != nil else {
                throw Failure(message: String(localized: "This archive contains a link that points outside it (“\(relative)”), so it wasn’t extracted."))
            }
            if let quarantine { try markQuarantined(path, quarantine) }
        case S_IFDIR:
            // Readable and enterable, so the walk sees what's inside (and the folder can be removed later).
            try checkedPermissions(path, (info.st_mode & 0o7777 & ~(S_ISUID | S_ISGID | S_ISVTX)) | S_IRWXU)
            if let quarantine { try markQuarantined(path, quarantine) }
            return true
        case S_IFREG:
            if info.st_mode & (S_ISUID | S_ISGID | S_ISVTX) != 0 || (quarantine != nil && info.st_mode & S_IWUSR == 0) {
                try checkedPermissions(path, (info.st_mode & ~(S_ISUID | S_ISGID | S_ISVTX) & 0o7777) | (quarantine != nil ? S_IWUSR : 0))
            }
            if let quarantine { try markQuarantined(path, quarantine) }
        default:
            try FileManager.default.removeItem(atPath: path)
        }
        return false
    }

    /// Where a link's `target` leads, as path components inside `root`, following links on the way; nil when it would
    /// leave `root` (an absolute target, a ".." past the top), loops, can't be checked, or takes more than `budget`
    /// steps in all (links made of links can't multiply the work). `parent`: the link's folder inside `root`.
    package static func resolve(_ target: String, from parent: [String], in root: String, hops: Int, budget: inout Int) -> [String]? {
        guard hops < 32, !target.hasPrefix("/") else { return nil }
        var stack = parent
        for part in target.split(separator: "/") {
            budget -= 1
            guard budget > 0 else { return nil }
            if part == "." { continue }
            if part == ".." {
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
                continue
            }
            stack.append(String(part))
            // A link on the way leads somewhere else: follow it from its own folder. A missing part is just a name (the
            // link dangles inside); anything that can't be looked at refuses the link.
            var info = stat()
            let path = root + "/" + stack.joined(separator: "/")
            if lstat(path, &info) != 0 {
                guard errno == ENOENT else { return nil }
                continue
            }
            if info.st_mode & S_IFMT == S_IFLNK {
                guard let next = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
                      let resolved = resolve(next, from: Array(stack.dropLast()), in: root, hops: hops + 1, budget: &budget)
                else { return nil }
                stack = resolved
            }
        }
        return stack
    }

    /// Drops an access list the archive restored (one that denies deleting would make the items impossible to undo or
    /// clean up). Never through a link.
    private static func checkedPermissions(_ path: String, _ mode: mode_t) throws {
        guard lchmod(path, mode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func clearFlagsAndAccessList(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let locks = UInt32(UF_IMMUTABLE | UF_APPEND)
        if info.st_flags & locks != 0, lchflags(path, info.st_flags & ~locks) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard let empty = acl_init(0) else { throw POSIXError(.ENOMEM) }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        if acl_set_link_np(path, ACL_TYPE_EXTENDED, empty) != 0, errno != ENOTSUP {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static let quarantineAttribute = "com.apple.quarantine"

    /// The archive's quarantine mark, if it has one.
    private static func quarantine(of archive: URL) -> Data? {
        let size = getxattr(archive.path, quarantineAttribute, nil, 0, 0, 0)
        guard size > 0, size < 4096 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(archive.path, quarantineAttribute, $0.baseAddress, size, 0, 0) }
        return read > 0 ? data.prefix(read) : nil
    }

    /// Gives `path` the archive's quarantine mark, replacing any it has (never through a link). Fails closed, except on
    /// disks that can't keep extended attributes at all.
    private static func markQuarantined(_ path: String, _ value: Data) throws {
        let result = value.withUnsafeBytes { setxattr(path, quarantineAttribute, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
        guard result != 0, errno != ENOTSUP else { return }
        let name = (path as NSString).lastPathComponent
        throw Failure(message: String(localized: "“\(name)” couldn’t be marked as downloaded, so nothing was extracted."))
    }

    // MARK: - Placing results

    /// Moves `item` into `folder` as `name`, or `name 2`, `name 3`… when taken, claiming the name atomically (nothing
    /// that appears meanwhile is ever replaced). Disks without exclusive renames (exFAT) claim the name first with an
    /// empty placeholder.
    package static func place(_ item: URL, in folder: URL, as name: String, supportsExclusiveRename: Bool = true) throws -> URL {
        let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true && !isSymlink(item)
        // Folders have no extension to keep, except packages ("Foo.app" → "Foo 2.app").
        let keepsExtension = !isFolder || (try? item.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
        for n in 1...10_000 {
            let candidate = n == 1 ? name : FileOps.name(name, adding: " \(n)", keepingExtension: keepsExtension)
            let destination = folder.appending(path: candidate, directoryHint: isFolder ? .isDirectory : .notDirectory)
            if !supportsExclusiveRename { errno = ENOTSUP } else
            if renamex_np(item.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return destination }
            let code = errno
            if code == EEXIST { continue }
            guard code == ENOTSUP || code == EINVAL else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            // The placeholder takes the name or fails because it's taken; then the item replaces only that.
            let placeholderIdentity: FileIdentity?
            if isFolder {
                if mkdir(destination.path, 0o700) != 0 {
                    let mkdirErr = errno
                    if mkdirErr == EEXIST { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: mkdirErr) ?? .EIO)
                }
                placeholderIdentity = FileIdentity.read(destination.path)
            } else {
                let fd = open(destination.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
                if fd < 0 {
                    let openErr = errno
                    if openErr == EEXIST { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: openErr) ?? .EIO)
                }
                var info = stat()
                placeholderIdentity = fstat(fd, &info) == 0 ? FileIdentity.from(info) : nil
                close(fd)
            }
            if rename(item.path, destination.path) == 0 { return destination }
            let error = errno
            if let placeholderIdentity, FileIdentity.read(destination.path) == placeholderIdentity {
                if isFolder { rmdir(destination.path) } else { unlink(destination.path) }
            }
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        throw Failure(message: String(localized: "No free name for “\(name)”."))
    }

    /// `url`, or `name 2.ext`, `name 3.ext`… when it's taken (a dangling link counts as taken). For staging only:
    /// final names are claimed by `place`.
    package static func uniqueURL(_ url: URL) -> URL {
        func taken(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0
        }
        guard taken(url) else { return url }
        let folder = url.deletingLastPathComponent()
        for n in 2... {
            let candidate = folder.appending(path: FileOps.name(url.lastPathComponent, adding: " \(n)",
                                                                keepingExtension: !url.hasDirectoryPath),
                                             directoryHint: url.hasDirectoryPath ? .isDirectory : .notDirectory)
            if !taken(candidate) { return candidate }
        }
        return url
    }

    /// Nothing is made inside an archive opened as a folder (a temporary copy).
    private static func requireOutsideCopies(_ folder: URL, copies: CopyProviders) throws {
        guard !ReadOnlyCopies.contains(folder, copies: copies) else {
            throw Failure(message: String(localized: "Nothing can be made in a read-only copy (an archive opened as a folder, or a container’s files). Copy what you need out first."))
        }
    }

    private static func requireWritable(_ folder: URL) throws {
        guard access(folder.path, W_OK) == 0 else {
            let name = FileManager.default.displayName(atPath: folder.path)
            throw Failure(message: String(localized: "“\(name)” can’t be changed, so nothing can be made there."))
        }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    /// Removes `url` even when the archive left folders without permissions or with access lists, and however deep the
    /// tree goes: everything is reached through open folders, never long paths, and never through links.
    package static func removeTree(_ url: URL) {
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { return }
        defer { close(parent) }
        removeTree(url.lastPathComponent, in: parent)
    }

    /// Remove one child of an already opened folder. Cache owners pin their root without following a replacement
    /// symlink; recursive cleanup keeps using descriptor-relative paths below it.
    package static func removeTree(_ name: String, in parent: Int32) {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0),
              hasEntry(name, in: parent) else { return }
        removeEntry(in: parent, name)
    }

    package static func hasEntry(_ name: String, in parent: Int32) -> Bool {
        entries(parent).contains(name)
    }

    private static func removeEntry(in parent: Int32, _ name: String) {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return }
        // A locked (or append-only) item can't be changed or deleted until it's unlocked. Opened without following a
        // link and without waiting (a FIFO).
        let locks = UInt32(UF_IMMUTABLE | UF_APPEND)
        if info.st_flags & locks != 0 {
            let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_SYMLINK | O_CLOEXEC)
            if fd >= 0 {
                fchflags(fd, info.st_flags & ~locks)
                close(fd)
            }
        }
        // Owner rights first: a folder must be readable and changeable to empty it; any entry may carry an access list
        // that denies deleting it.
        if info.st_mode & S_IFMT != S_IFLNK { fchmodat(parent, name, (info.st_mode & 0o7777) | S_IRWXU, AT_SYMLINK_NOFOLLOW) }
        if info.st_mode & S_IFMT == S_IFDIR {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return }
            if let empty = acl_init(0) {
                acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED)
                acl_free(UnsafeMutableRawPointer(empty))
            }
            for child in entries(fd) { removeEntry(in: fd, child) }
            close(fd)
            unlinkat(parent, name, AT_REMOVEDIR)
        } else {
            if info.st_mode & S_IFMT == S_IFREG {
                let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                if fd >= 0 {
                    if let empty = acl_init(0) {
                        acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED)
                        acl_free(UnsafeMutableRawPointer(empty))
                    }
                    close(fd)
                }
            }
            unlinkat(parent, name, 0)
        }
    }

    /// The names in an open folder.
    package static func entries(_ fd: Int32) -> [String] {
        let copy = dup(fd)
        guard copy >= 0, let dir = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            return []
        }
        defer { closedir(dir) }
        rewinddir(dir)
        var names: [String] = []
        while let entry = readdir(dir) {
            guard let name = DirectoryEntryName.read(entry) else { continue }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    /// Every name in the folder at `path`, read from the folder itself (FileManager leaves out files named "._…",
    /// taking them for another file's metadata), never through a link; throws when it can't list them all.
    package static func names(inFolderAt path: String) throws -> [String] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        return try ChosenFile.entries(in: fd).map(\.name)
    }

    // MARK: - Running the tools

    /// Runs ditto, counting the items it copies, until it exits or `control` cancels.
    private static func run(_ tool: String, _ arguments: [String], control: Control) throws {
        guard !control.isCancelled else { throw CancellationError() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = ["LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        control.attach(process)
        defer { control.attach(nil) }
        try process.run()
        // A Stop that came between attaching and starting would have found nothing to stop.
        if control.isCancelled { process.terminate() }

        var pending = Data()
        var tail: [Substring] = []
        let reader = pipe.fileHandleForReading
        while let chunk = try? reader.read(upToCount: 1 << 16), !chunk.isEmpty {
            pending.append(chunk)
            guard let last = pending.lastIndex(of: UInt8(ascii: "\n")) else { continue }
            let text = String(decoding: pending[...last], as: UTF8.self)
            pending.removeSubrange(...last)
            var count = 0
            for line in text.split(separator: "\n") {
                if line.hasPrefix("copying file") { count += 1 }
                // Kept for the error message: the last lines that aren't progress.
                if !isProgress(line) {
                    tail.append(line.suffix(300))
                    if tail.count > 20 { tail.removeFirst() }
                }
            }
            control.advance(count)
        }
        if !pending.isEmpty {
            let text = String(decoding: pending, as: UTF8.self)
            var count = 0
            for line in text.split(separator: "\n") {
                if line.hasPrefix("copying file") { count += 1 }
                if !isProgress(line) {
                    tail.append(line.suffix(300))
                    if tail.count > 20 { tail.removeFirst() }
                }
            }
            if count > 0 { control.advance(count) }
        }
        process.waitUntilExit()
        if control.isCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let status = Int(process.terminationStatus)
            throw Failure(message: reason(tail) ?? String(localized: "It stopped with an error (\(status)).",
                                                          comment: "An archive tool failed; the number is its exit status"))
        }
    }

    /// Lines ditto prints for each item as it goes ("copying file ./a ...", ">>> Copying a", "12 bytes for ./a").
    private static func isProgress(_ line: Substring) -> Bool {
        line.hasPrefix("copying file") || line.hasPrefix(">>> ") || line.contains(" bytes for ")
    }

    /// ditto's last real error, in plain words.
    private static func reason(_ lines: [Substring]) -> String? {
        for line in lines.reversed() {
            var text = line[...]
            if text.hasPrefix("ditto: ") { text = text.dropFirst("ditto: ".count) }
            // Drop errno noise: "…: Unknown error: -1", "…: Undefined error: 0".
            for noise in [": Unknown error", ": Undefined error"] {
                if let range = text.range(of: noise) { text = text[..<range.lowerBound] }
            }
            let message = text.trimmingCharacters(in: .whitespaces)
            if !message.isEmpty { return String(message.suffix(300)) }
        }
        return nil
    }
}
