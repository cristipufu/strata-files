import Foundation

nonisolated package enum RemovalVolume: Sendable {
    case writable, readOnly, protectedSystem

    package typealias Reader = @Sendable (URL) -> RemovalVolume

    package static func read(_ item: URL) -> Self {
        var volume = statfs()
        // Removing a link changes its parent, never the volume its target belongs to.
        guard statfs(item.deletingLastPathComponent().path, &volume) == 0,
              volume.f_flags & UInt32(MNT_RDONLY) != 0 else { return .writable }
        return volume.f_flags & UInt32(MNT_ROOTFS) != 0 ? .protectedSystem : .readOnly
    }

    package static func refusal(in items: [URL], read: Reader) -> Refusal? {
        for item in items {
            let volume = read(item)
            if volume != .writable { return Refusal(item: item, volume: volume) }
        }
        return nil
    }

    package struct Refusal: LocalizedError {
        package let item: URL
        package let volume: RemovalVolume

        package var errorDescription: String? {
            volume == .protectedSystem
                ? String(localized: "“\(item.lastPathComponent)” is protected by macOS.", comment: "File removal refused on the read-only system volume")
                : String(localized: "“\(item.lastPathComponent)” is on a read-only disk.", comment: "File removal refused on a read-only volume")
        }

        package var recoverySuggestion: String? {
            volume == .protectedSystem
                ? String(localized: "macOS does not allow this system item to be moved to Trash or deleted.")
                : String(localized: "Files on this disk can’t be moved to Trash or deleted while the disk is read-only.")
        }
    }
}
