import Darwin

/// The other volumes mounted inside the folders the index covers: a network share, a disk image, an external disk.
/// The index leaves each out like a folder you excluded. Its files are another disk's or another machine's, reading
/// them could wait on it for good, and a scan never did read into one: only file events from it did.
nonisolated package enum IndexMountedVolumes {
    package typealias Reader = @Sendable (_ roots: [String]) -> Set<String>

    private typealias Volume = statfs

    /// Where volumes are mounted inside `roots`, by the system's own table, which is read without asking any volume
    /// anything: one that stopped answering is listed like any other.
    package static func inside(_ roots: [String]) -> Set<String> {
        // Room for a few more than are mounted now, in case one is mounted meanwhile.
        var volumes = [Volume](repeating: Volume(), count: Int(max(0, getfsstat(nil, 0, MNT_NOWAIT))) + 8)
        let listed = getfsstat(&volumes, Int32(MemoryLayout<Volume>.stride * volumes.count), MNT_NOWAIT)
        guard listed > 0 else { return [] }
        var inside: Set<String> = []
        for volume in volumes.prefix(Int(listed)) {
            let mount = withUnsafeBytes(of: volume.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if roots.contains(where: { IndexRefresh.lies(mount, in: $0) }) { inside.insert(mount) }
        }
        return inside
    }
}
