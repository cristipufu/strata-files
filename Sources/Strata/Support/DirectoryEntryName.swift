import Foundation

/// libc packs dirents to d_reclen bytes. Copying the imported fixed-size d_name tuple can read past that record
/// and the end of its buffer; inspect the header and copy only the actual name instead.
nonisolated package enum DirectoryEntryName {
    private static let nameOffset = MemoryLayout<dirent>.offset(of: \.d_name)!
    private static let nameCapacity = MemoryLayout.size(ofValue: dirent().d_name)

    package static func read(_ entry: UnsafePointer<dirent>) -> String? {
        let length = Int(entry.pointee.d_namlen), recordLength = Int(entry.pointee.d_reclen)
        guard length > 0, length < nameCapacity, recordLength > nameOffset,
              length < recordLength - nameOffset else { return nil }
        let start = UnsafeRawPointer(entry).advanced(by: nameOffset)
        guard start.load(fromByteOffset: length, as: UInt8.self) == 0 else { return nil }
        let bytes = UnsafeRawBufferPointer(start: start, count: length)
        guard !bytes.contains(0), !bytes.contains(47) else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// The names in the folder open at `fd` (without `.` and `..`), read from a copy of it, from the start whoever
    /// read it before. A name that isn't text is left out, and a folder that can't be read lists nothing: for
    /// cleanups that leave alone what they can't name.
    package static func names(inFolder fd: Int32) -> [String] {
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0, let dir = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            return []
        }
        defer { closedir(dir) }
        rewinddir(dir)
        var names: [String] = []
        while let entry = readdir(dir) {
            guard let name = read(entry) else { continue }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }
}
