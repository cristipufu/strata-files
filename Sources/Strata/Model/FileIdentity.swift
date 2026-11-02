import Foundation

/// The item itself, without following a symlink. Live Undo compares birth time too, so reusing an inode does not
/// make a replacement its own. History uses volume UUIDs so remounting does not change an item’s identity.
nonisolated package struct FileIdentity: Sendable, Equatable {
    package let device: dev_t
    package let inode: ino_t
    package let birthSeconds: Int
    package let birthNanoseconds: Int

    package init(device: dev_t, inode: ino_t, birthSeconds: Int, birthNanoseconds: Int) {
        self.device = device
        self.inode = inode
        self.birthSeconds = birthSeconds
        self.birthNanoseconds = birthNanoseconds
    }

    package static func read(_ path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return from(info)
    }

    package static func from(_ info: stat) -> FileIdentity {
        FileIdentity(device: info.st_dev, inode: info.st_ino,
                            birthSeconds: info.st_birthtimespec.tv_sec, birthNanoseconds: info.st_birthtimespec.tv_nsec)
    }

    package func historyKey(volumeID: String?) -> String { "\(volumeID ?? String(device))/\(inode)" }

    /// Volume UUIDs survive remounting, unlike device numbers. Preserve the device-number fallback for volumes
    /// without a UUID.
    package static func historyKey(at path: String) -> String? {
        guard let identity = read(path) else { return nil }
        let volume = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        return identity.historyKey(volumeID: volume)
    }

    /// Reading volume metadata can race a replacement. Check both sides of that lookup against the identity
    /// captured by the operation; the file currently at this path does not become ours merely by being there.
    package func historyKey(at path: String) -> String? {
        guard Self.read(path) == self else { return nil }
        let volume = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        guard Self.read(path) == self else { return nil }
        return historyKey(volumeID: volume)
    }

    package static func matchesHistory(_ recorded: String, at path: String) -> Bool {
        historyKey(at: path) == recorded
    }
}
