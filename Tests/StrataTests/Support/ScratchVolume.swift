import Darwin
import Foundation
import Synchronization
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

/// A disk of its own for a test (a small disk image, attached without showing in Finder and detached when the test
/// process exits), for moves that cross disks: a copy and then the original removed, so the item is a new file where it
/// lands. Attached on a serial queue and pooled across sequential callers (`make`, `eject`): `hdiutil` takes seconds,
/// and other tests' work waits on the main thread and on Swift's shared threads.
nonisolated final class ScratchVolume: @unchecked Sendable {
    private struct SharedDisk: Equatable {
        let folder: URL
        let mount: URL
        let fileSystem: String
    }

    private struct Pool {
        var available: [SharedDisk] = []
        var all: [SharedDisk] = []
    }

    struct HdiutilFailure: Error, CustomStringConvertible {
        let description: String
        /// What hdiutil exited with, when it failed by exiting so; nil when a signal stopped it, or when its output
        /// couldn't be read or made sense of.
        let status: Int32?

        init(description: String, status: Int32? = nil) {
            self.description = description
            self.status = status
        }

        /// How `command` ended, and then what it said: a process a signal stopped has no exit status, only the
        /// signal's number in its place.
        init(_ command: String, ended reason: Process.TerminationReason, status: Int32, saying said: String) {
            let exited = reason == .exit
            let ended = "hdiutil \(command) " + (exited ? "exited with \(status)" : "was stopped by signal \(status)")
            self.init(description: said.isEmpty ? ended : "\(ended): \(said)", status: exited ? status : nil)
        }
    }

    private static let imageFile = "disk.sparseimage"
    private static let queue = DispatchQueue(label: "strata.tests.scratch-volume")
    private static let pool = Mutex(Pool())
    private static let systemEntries: Set<String> = [
        ".fseventsd", ".Spotlight-V100", ".DocumentRevisions-V100", ".TemporaryItems"
    ]
    private static let prepared: Void = {
        atexit(detachSharedScratchVolume)
        sweep(in: FileManager.default.temporaryDirectory).forEach(report)
    }()

    /// The disk's top folder.
    let root: URL
    private let disk: SharedDisk
    private let state = Mutex(false)

    /// `fileSystem` as `hdiutil create -fs` takes it: APFS, or ExFAT for a disk that keeps extended attributes in
    /// "._" files beside its items.
    static func make(fileSystem: String = "APFS") async throws -> ScratchVolume {
        try await withCheckedThrowingContinuation { done in
            queue.async { done.resume(with: Result { try ScratchVolume(fileSystem: fileSystem) }) }
        }
    }

    func eject() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Self.queue.async {
                self.release()
                done.resume()
            }
        }
    }

    private init(fileSystem: String) throws {
        _ = Self.prepared
        let checkedOut = try Self.checkoutDisk(fileSystem)
        disk = checkedOut
        root = checkedOut.mount
    }

    /// A test that stopped early still leaves its disk cleaned up.
    deinit {
        let shouldRelease = state.withLock { released in
            guard !released else { return false }
            released = true
            return true
        }
        guard shouldRelease else { return }
        let disk = self.disk
        Self.queue.sync {
            Self.recycleOrDetach(disk)
        }
    }

    private func release() {
        let shouldRelease = state.withLock { released in
            guard !released else { return false }
            released = true
            return true
        }
        guard shouldRelease else { return }
        Self.recycleOrDetach(disk)
    }

    /// A path on the disk.
    func url(_ path: String) -> URL { root.appending(path: path) }

    /// Removes the folders of disks that processes which have ended left in `directory`, detaching their disks first;
    /// what couldn't be done, said. A folder whose owner may still run, or without one, is left alone.
    static func sweep(in directory: URL, attached: () throws -> [String] = attachedImagePaths) -> [String] {
        let names: [String]
        do {
            // Names only: other tests' folders come and go here meanwhile.
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            return ["couldn't list \(directory.path): \(error)"]
        }
        var problems: [String] = [], ended: [OpenedFolder] = []
        for name in names where name.hasPrefix("strata-volume-") {
            let url = directory.appending(path: name, directoryHint: .isDirectory)
            let folder: OpenedFolder
            do {
                guard let opened = try OpenedFolder(url) else { continue }
                folder = opened
            } catch let error as POSIXError where error.code == .ENOTDIR || error.code == .ELOOP {
                // Not a folder at all: nothing a disk left.
                continue
            } catch {
                problems.append("couldn't open \(url.path): \(error)")
                continue
            }
            do {
                // The owner is read through the folder that would be removed, so the two are the same.
                if let owner = try RunOwner(markerIn: folder.fd), !owner.isRunning { ended.append(folder) }
            } catch {
                problems.append("left \(url.path): couldn't read its owner: \(error)")
            }
        }
        return problems + discard(ended, attached: attached)
    }

    /// The disk images attached now, as hdiutil lists them.
    static func attachedImages() throws -> [[String: Any]] {
        let plist = try hdiutil(["info", "-plist"])
        guard let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else {
            throw HdiutilFailure(description: "hdiutil info gave no property list")
        }
        // With nothing attached, there may be no list at all.
        return info["images"] as? [[String: Any]] ?? []
    }

    static func attachedImagePaths() throws -> [String] {
        try attachedImages().compactMap { $0["image-path"] as? String }
    }

    /// The disk the image at `path` is attached as, among `images`: its own, which carries its partition scheme, not a
    /// container the system made from it, nor a slice of either.
    static func wholeDisk(of path: String, in images: [[String: Any]]) -> String? {
        let ours = spellings(path)
        guard let image = images.first(where: { ($0["image-path"] as? String).map { !spellings($0).isDisjoint(with: ours) } == true })
        else { return nil }
        let entities = image["system-entities"] as? [[String: Any]] ?? []
        return entities.lazy.compactMap { entity -> String? in
            guard let device = entity["dev-entry"] as? String, device.hasPrefix("/dev/disk"),
                  (entity["content-hint"] as? String)?.hasSuffix("_partition_scheme") == true else { return nil }
            let number = device.dropFirst("/dev/disk".count)
            return !number.isEmpty && number.allSatisfy({ $0.isASCII && $0.isNumber }) ? device : nil
        }.first
    }

    private static func checkoutDisk(_ fileSystem: String) throws -> SharedDisk {
        while let candidate = pool.withLock({ pool in
            pool.available.lastIndex { $0.fileSystem == fileSystem }.map { pool.available.remove(at: $0) }
        }) {
            if isMounted(candidate), cleanDisk(candidate) {
                return candidate
            }
            detachDisk(candidate)
        }
        return try newDisk(fileSystem)
    }

    /// A new disk, tried again on a fresh image when making one fails, as it can on a busy machine. A failed attempt is
    /// reported even when a later one works.
    private static func newDisk(_ fileSystem: String) throws -> SharedDisk {
        for attempt in 1..<3 {
            do {
                return try addFreshDisk(fileSystem)
            } catch {
                report("attempt \(attempt) to make a disk failed, trying again on a fresh image: \(error)")
                Thread.sleep(forTimeInterval: Double(attempt))
            }
        }
        return try addFreshDisk(fileSystem)
    }

    private static func addFreshDisk(_ fileSystem: String) throws -> SharedDisk {
        let disk = try attachFreshDisk(fileSystem)
        pool.withLock { $0.all.append(disk) }
        return disk
    }

    private static func attachFreshDisk(_ fileSystem: String) throws -> SharedDisk {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "strata-volume-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            // Without its own start time, a process leaves its folder unmarked, which no sweep ever takes.
            try RunOwner.current?.marker.write(to: folder.appending(path: RunOwner.file))
            let image = folder.appending(path: "disk")
            try hdiutil(["create", "-size", "64m", "-fs", fileSystem, "-volname", "StrataTest", "-type", "SPARSE", image.path])
            let plist = try hdiutil(["attach", image.path + ".sparseimage", "-nobrowse", "-mountrandom", folder.path, "-plist"])
            let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
            let entities = info?["system-entities"] as? [[String: Any]] ?? []
            guard let mount = entities.compactMap({ $0["mount-point"] as? String }).first, let real = realpath(mount, nil) else {
                throw HdiutilFailure(description: "hdiutil attach named no mount point for \(image.path).sparseimage")
            }
            defer { free(real) }
            return SharedDisk(folder: folder, mount: URL(fileURLWithPath: String(cString: real), isDirectory: true),
                              fileSystem: fileSystem)
        } catch {
            // An attach can fail after attaching: the image made for this attempt, at a path no other has, is detached.
            do {
                try detach(image: folder.appending(path: imageFile).path)
            } catch {
                report("couldn't detach the image of \(folder.path): \(error)")
            }
            discard([folder]).forEach(report)
            throw error
        }
    }

    /// Whether a disk is still mounted where it was, and not only its empty mount folder left.
    private static func isMounted(_ disk: SharedDisk) -> Bool {
        var mount = stat(), folder = stat()
        return lstat(disk.mount.path, &mount) == 0 && lstat(disk.folder.path, &folder) == 0 && mount.st_dev != folder.st_dev
    }

    /// Empties the disk for its next test; whether it could. Every name is read from the folder itself, "._" files on a
    /// disk that keeps attributes in them included.
    private static func cleanDisk(_ disk: SharedDisk) -> Bool {
        guard let names = try? Archiver.names(inFolderAt: disk.mount.path) else { return false }
        for name in names where !systemEntries.contains(name) {
            do {
                try FileManager.default.removeItem(at: disk.mount.appending(path: name))
            } catch {
                // Removing an item also removes the "._" file a disk keeps for it.
                if (error as? CocoaError)?.code == .fileNoSuchFile { continue }
                return false
            }
        }
        return true
    }

    private static func recycleOrDetach(_ disk: SharedDisk) {
        if cleanDisk(disk) {
            pool.withLock {
                if $0.all.contains(disk) {
                    $0.available.append(disk)
                }
            }
        } else {
            detachDisk(disk)
        }
    }

    private static func detachDisk(_ disk: SharedDisk) {
        pool.withLock {
            $0.available.removeAll { $0 == disk }
            $0.all.removeAll { $0 == disk }
        }
        discard([disk.folder]).forEach(report)
    }

    fileprivate static func detachShared() {
        let disks = pool.withLock {
            let current = $0.all
            $0.available.removeAll()
            $0.all.removeAll()
            return current
        }
        discard(disks.map(\.folder)).forEach(report)
    }

    /// A disk's folder, opened relative to its parent without following a link.
    private final class OpenedFolder {
        let url: URL
        let parent: Int32
        let fd: Int32

        /// Nil when the folder is gone.
        init?(_ url: URL) throws {
            // Both are opened before either is kept: a folder that fails here never runs deinit.
            let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard parent >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                let failure = errno
                close(parent)
                if failure == ENOENT { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
            }
            self.url = url
            self.parent = parent
            self.fd = fd
        }

        deinit {
            close(fd)
            close(parent)
        }

        func names() throws -> [String] { try ChosenFile.names(in: fd) }
    }

    /// Detaches the disks mounted in `folders` and removes them; what couldn't be done, said. A folder whose image is
    /// still attached, or that holds anything besides its image, its owner and the empty folders its disks were mounted
    /// on, is left as it is.
    private static func discard(_ folders: [URL]) -> [String] {
        var problems: [String] = [], opened: [OpenedFolder] = []
        for url in folders {
            do {
                if let folder = try OpenedFolder(url) { opened.append(folder) }
            } catch {
                problems.append("couldn't open \(url.path): \(error)")
            }
        }
        return problems + discard(opened, attached: attachedImagePaths)
    }

    private static func discard(_ folders: [OpenedFolder], attached: () throws -> [String]) -> [String] {
        var problems: [String] = [], detached: [OpenedFolder] = []
        for folder in folders {
            if let problem = detachMounts(in: folder) { problems.append(problem) } else { detached.append(folder) }
        }
        guard !detached.isEmpty else { return problems }
        let images: [(path: String, spellings: Set<String>)]
        do {
            images = try attached().map { ($0, spellings($0)) }
        } catch {
            return problems + detached.map { "left \($0.url.path): couldn't list the attached disk images: \(error)" }
        }
        for folder in detached {
            let prefixes = spellings(folder.url.path).map { $0 + "/" }
            let inside = images.filter { image in image.spellings.contains { path in prefixes.contains { path.hasPrefix($0) } } }
            if !inside.isEmpty {
                problems.append("left \(folder.url.path): \(inside.map(\.path).joined(separator: ", ")) is attached but not mounted there")
            } else if let problem = removeFolder(folder) {
                problems.append(problem)
            }
        }
        return problems
    }

    /// Detaches what's mounted on the folders in `folder`, each opened without following a link, so a disk mounted
    /// anywhere else is never touched.
    private static func detachMounts(in folder: OpenedFolder) -> String? {
        let names: [String]
        do {
            names = try folder.names()
        } catch {
            return "couldn't read \(folder.url.path): \(error)"
        }
        var problems: [String] = []
        for name in names where name.hasPrefix("dmg.") {
            do {
                // Each try detaches what's mounted here then, which another process may have detached meanwhile. A
                // disk that unmounted but stays attached is left for `discard` to report: the only way back to it is a
                // path, which a link could lead elsewhere.
                try detach { mountPoint(name, in: folder.fd) }
            } catch {
                let mount = folder.url.appending(path: name).path
                problems.append("couldn't detach the disk mounted on \(mount): \(error)")
            }
        }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }

    /// Where the disk mounted on the folder `name` in the opened `folder` is mounted, as the system records it; nil when
    /// nothing is. A disk mounted there makes that folder, opened without following a link, a file system of its own.
    private static func mountPoint(_ name: String, in folder: Int32) -> String? {
        let fd = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var inside = stat(), outside = stat(), mounted = statfs()
        guard fstat(fd, &inside) == 0, fstat(folder, &outside) == 0, inside.st_dev != outside.st_dev,
              fstatfs(fd, &mounted) == 0 else { return nil }
        return withUnsafeBytes(of: mounted.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// Removes a disk's folder: first the empty folders its disks were mounted on, then its image and owner, then the
    /// folder. One holding anything else is left as it is.
    private static func removeFolder(_ folder: OpenedFolder) -> String? {
        func failed(_ doing: String, _ name: String, code: Int32 = errno) -> String {
            "couldn't \(doing) \(folder.url.appending(path: name).path): \(String(cString: strerror(code)))"
        }
        let names: [String]
        do {
            names = try folder.names()
        } catch {
            return "couldn't read \(folder.url.path): \(error)"
        }
        let mounts = names.filter { $0.hasPrefix("dmg.") }
        let files = names.filter { $0 == imageFile || $0 == RunOwner.file }
        let others = names.filter { !$0.hasPrefix("dmg.") && $0 != imageFile && $0 != RunOwner.file }
            + mounts.filter { !isEmptyFolder($0, in: folder.fd) } + files.filter { !isFile($0, in: folder.fd) }
        guard others.isEmpty else { return "left \(folder.url.path), which holds \(others.joined(separator: ", "))" }
        for name in mounts {
            if unlinkat(folder.fd, name, AT_REMOVEDIR) != 0, errno != ENOENT { return failed("remove", name) }
        }
        // The owner goes last, so a folder left partway still names its owner for a later sweep.
        for name in [imageFile, RunOwner.file] where files.contains(name) {
            if unlinkat(folder.fd, name, 0) != 0, errno != ENOENT { return failed("remove", name) }
        }
        guard unlinkat(folder.parent, folder.url.lastPathComponent, AT_REMOVEDIR) != 0, errno != ENOENT else { return nil }
        let code = errno
        return "couldn't remove \(folder.url.path): \(String(cString: strerror(code)))"
    }

    /// Whether `name` in the opened `folder` is an empty folder, itself and not a link to one, or already gone.
    private static func isEmptyFolder(_ name: String, in folder: Int32) -> Bool {
        let fd = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT }
        defer { close(fd) }
        return (try? ChosenFile.names(in: fd).isEmpty) == true
    }

    /// Whether `name` in the opened `folder` is a file, itself and not a link, or already gone.
    private static func isFile(_ name: String, in folder: Int32) -> Bool {
        var info = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT }
        return info.st_mode & S_IFMT == S_IFREG
    }

    /// The ways hdiutil may write `path`: as given or resolved, with or without the /private that /var stands for. Only a
    /// disk's own paths are resolved: another image's could be on a share that no longer answers.
    private static func spellings(_ path: String) -> Set<String> {
        func plain(_ path: String) -> String { path.hasPrefix("/private/") ? String(path.dropFirst(8)) : path }
        guard path.contains("/strata-volume-"), let real = realpath(path, nil) else { return [plain(path)] }
        defer { free(real) }
        return [plain(path), plain(String(cString: real))]
    }

    private static func report(_ problem: String) {
        try? FileHandle.standardError.write(contentsOf: Data("ScratchVolume: \(problem)\n".utf8))
    }

    /// Detaches the disk the image at `image` is attached as, if it is: an image Strata's tests made, at a path no
    /// other has.
    static func detach(image: String) throws {
        try detach { wholeDisk(of: image, in: try attachedImages()) }
    }

    /// Detaches what `target` names, if it names anything, asking it again after each failed try: a failure is no
    /// failure once there's nothing left, as when another process detached it meanwhile. A disk the system is busy
    /// with can refuse for a moment, even forced (hdiutil exits with EBUSY), and can go anyway after saying so; it's
    /// tried again after a pause, up to `retries` times, and by then its device name can be another disk's.
    static func detach(retries: Int = 4, pause: () -> Void = { Thread.sleep(forTimeInterval: 0.5) },
                       run: ([String]) throws -> Data = hdiutil, target: () throws -> String?) throws {
        guard var current = try target() else { return }
        for attempt in 0... {
            do {
                _ = try run(["detach", current, "-force"])
                return
            } catch let failure {
                let busy = isBusy(failure)
                // After the last busy try too, so a disk that goes anyway after saying so isn't reported.
                if busy { pause() }
                let next: String?
                do {
                    next = try target()
                } catch {
                    // Why the disk wouldn't go says more than a failed look after it.
                    throw failure
                }
                guard let next else { return }
                guard busy, attempt < retries else { throw failure }
                current = next
            }
        }
    }

    private static func isBusy(_ error: Error) -> Bool {
        (error as? HdiutilFailure)?.status == EBUSY
    }

    /// Runs hdiutil; one that fails says why, in hdiutil's own words.
    @discardableResult
    static func hdiutil(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Its messages are read on a thread of their own while its output is read here, so hdiutil never waits on a
        // full pipe, and no busy pool of shared threads can keep that reading from starting.
        let messages = Mutex(Data())
        let drained = DispatchSemaphore(value: 0)
        let reader = errors.fileHandleForReading
        Thread {
            let read: Data
            do {
                read = try reader.readToEnd() ?? Data()
            } catch {
                // Stopping reading, so hdiutil can't wait on a full pipe.
                try? reader.close()
                read = Data("(its messages couldn't be read: \(error))".utf8)
            }
            messages.withLock { $0 = read }
            drained.signal()
        }.start()
        let data = Result { try output.fileHandleForReading.readToEnd() ?? Data() }
        // A read that failed stops reading, so hdiutil can't wait on a full pipe meanwhile.
        if case .failure = data { try? output.fileHandleForReading.close() }
        drained.wait()
        process.waitUntilExit()
        let command = arguments.first ?? ""
        if case .failure(let error) = data {
            throw HdiutilFailure(description: "couldn't read what hdiutil \(command) said: \(error)")
        }
        guard process.terminationStatus == 0 else {
            let said = String(decoding: messages.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw HdiutilFailure(command, ended: process.terminationReason, status: process.terminationStatus,
                                 saying: said)
        }
        return try data.get()
    }
}

private nonisolated func detachSharedScratchVolume() {
    ScratchVolume.detachShared()
}
