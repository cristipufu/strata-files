import Foundation
import Synchronization

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

    private static let queue = DispatchQueue(label: "strata.tests.scratch-volume")
    private static let pool = Mutex(Pool())
    private static let systemEntries: Set<String> = [
        ".fseventsd", ".Spotlight-V100", ".DocumentRevisions-V100", ".TemporaryItems"
    ]
    private static let registeredCleanup: Void = {
        atexit(detachSharedScratchVolume)
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
        _ = Self.registeredCleanup
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

    private static func checkoutDisk(_ fileSystem: String) throws -> SharedDisk {
        while let candidate = pool.withLock({ pool in
            pool.available.lastIndex { $0.fileSystem == fileSystem }.map { pool.available.remove(at: $0) }
        }) {
            if FileManager.default.fileExists(atPath: candidate.mount.path), cleanDisk(candidate) {
                return candidate
            }
            detachDisk(candidate)
        }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "strata-volume-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let image = folder.appending(path: "disk")
            _ = try hdiutil(["create", "-size", "64m", "-fs", fileSystem, "-volname", "StrataTest", "-type", "SPARSE", image.path, "-quiet"])
            let plist = try hdiutil(["attach", image.path + ".sparseimage", "-nobrowse", "-mountrandom", folder.path, "-plist"])
            let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
            let entities = info?["system-entities"] as? [[String: Any]] ?? []
            guard let mount = entities.compactMap({ $0["mount-point"] as? String }).first, let real = realpath(mount, nil) else {
                throw CocoaError(.fileNoSuchFile)
            }
            defer { free(real) }
            let disk = SharedDisk(folder: folder, mount: URL(fileURLWithPath: String(cString: real), isDirectory: true),
                                  fileSystem: fileSystem)
            pool.withLock { $0.all.append(disk) }
            return disk
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    private static func cleanDisk(_ disk: SharedDisk) -> Bool {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: disk.mount, includingPropertiesForKeys: nil, options: []) else {
            return false
        }
        for item in items where !systemEntries.contains(item.lastPathComponent) {
            do {
                try fm.removeItem(at: item)
            } catch {
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
        _ = try? hdiutil(["detach", disk.mount.path, "-force", "-quiet"])
        try? FileManager.default.removeItem(at: disk.folder)
    }

    fileprivate static func detachShared() {
        let disks = pool.withLock {
            let current = $0.all
            $0.available.removeAll()
            $0.all.removeAll()
            return current
        }
        for disk in disks {
            _ = try? hdiutil(["detach", disk.mount.path, "-force", "-quiet"])
            try? FileManager.default.removeItem(at: disk.folder)
        }
    }

    @discardableResult
    private static func hdiutil(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}

private nonisolated func detachSharedScratchVolume() {
    ScratchVolume.detachShared()
}
