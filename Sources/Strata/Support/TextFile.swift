import Foundation

/// The start of a text file, decoded, with line endings normalized to `\n`.
nonisolated package struct TextFile: Sendable {
    package static let limit = 512 * 1024

    package let text: String
    /// True when the file is longer than what was read.
    package let isTruncated: Bool

    package init(text: String, isTruncated: Bool) {
        self.text = text
        self.isTruncated = isTruncated
    }

    /// Not a regular file of text: binary data, a device, a pipe (a preview leaves it to Quick Look).
    package struct NotText: Error {
        package init() {}
    }

    /// Reads at most `limit` bytes of `url`, cut at a line boundary. Throws `NotText` for binary data.
    package static func read(_ url: URL, limit: Int = TextFile.limit) throws -> TextFile {
        let (data, truncated) = try readPrefix(url, limit: limit)
        var bytes = data
        if truncated, let lastNewline = bytes.lastIndex(of: 0x0A) { bytes = bytes[..<lastNewline] }
        guard let text = decode(bytes) else { throw NotText() }
        return TextFile(text: normalizeNewlines(text), isTruncated: truncated)
    }

    /// Up to `limit` bytes from the start of `url`, and whether there was more.
    package static func readPrefix(_ url: URL, limit: Int) throws -> (Data, Bool) {
        guard limit >= 0, limit < Int.max else { throw NotText() }
        // A name ending in .txt can still be a FIFO or a device. Open without waiting for a writer and
        // inspect that descriptor, so a path replacement cannot bypass the regular-file check.
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { throw NotText() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        return data.count > limit ? (data.prefix(limit), true) : (data, false)
    }

    /// Decodes UTF-8 (with or without BOM), UTF-16 with a BOM, or falls back to Windows Latin 1. Nil for binary data.
    package static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        let sample = data.prefix(8192)
        // Text has no NULs and almost no other control characters (tab, newlines, form feed and escape aside).
        let controls = sample.count { $0 < 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0C && $0 != 0x0D && $0 != 0x1B }
        if sample.contains(0) || controls * 50 > sample.count { return nil }
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        if let text = String(data: body, encoding: .utf8) { return text }
        // A read limit can split a multi-byte character; drop up to three trailing bytes before giving up on UTF-8.
        for cut in 1...3 where body.count > cut {
            if let text = String(data: body.dropLast(cut), encoding: .utf8) { return text }
        }
        return String(data: body, encoding: .windowsCP1252)
    }

    package static func normalizeNewlines(_ text: String) -> String {
        guard text.contains("\r") else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// "512 KB" style size for truncation notes.
    package static var limitDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .binary)
    }
}
