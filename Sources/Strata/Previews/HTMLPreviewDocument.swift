import Foundation
import ImageIO
import UniformTypeIdentifiers
import StrataModel

nonisolated package struct HTMLPreviewResource: Sendable {
    package let data: Data
    package let mime: String

    /// A picture a book or a page holds, no larger than 2048 pixels a side, within what's left of its document's
    /// `pixels` and `bytes`: a photo stays a JPEG, anything else becomes a PNG. One refused from its header costs
    /// nothing; one decoded costs its pixels whether it fits the bytes left or not, since decoding is the work they
    /// bound.
    package static func picture(_ data: Data, pixels: inout Int, bytes: inout Int) throws -> HTMLPreviewResource {
        let picture = try PreviewPicture(data)
        guard picture.width <= pixels / picture.height else { throw PreviewError.unsupported }
        pixels -= picture.width * picture.height
        let image = try picture.thumbnail(pixels: 2048)
        let type = picture.isJPEG ? UTType.jpeg : .png
        let output = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw PreviewError.unsupported
        }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(writer), output.length <= bytes else { throw PreviewError.unsupported }
        bytes -= output.length
        return HTMLPreviewResource(data: output as Data, mime: type.preferredMIMEType ?? "image/png")
    }
}

/// The document and its already-local assets. No provider fetches or file URL loads are handed to WebKit.
package actor HTMLPreviewDocument {
    package static let scheme = "strata-html"
    package static let assetLimit = 8 << 20
    package static let requestLimit = 32
    /// What every page Strata hands WebKit starts with: its policy, in the document too, and no DNS prefetching.
    package static let head = "<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" "
        + "content=\"\(policy)\"><meta http-equiv=\"x-dns-prefetch-control\" content=\"off\">"
    package static let policy = "default-src 'none'; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'; media-src 'none'; font-src 'none'; worker-src 'none'; manifest-src 'none'; style-src 'self' 'unsafe-inline'; img-src 'self'"
    nonisolated package let url: URL
    nonisolated package let sourceURL: URL
    private let chosen: ChosenFile
    private let folder: Int32
    private let stamp: Stamp
    private let document: Data
    private var cache: [Data: HTMLPreviewResource] = [:]
    private var attempts: Set<Data> = []
    private var remainingBytes = assetLimit
    private var remainingPixels = 16_000_000

    private struct Stamp: Equatable, Sendable {
        let identity: FileIdentity
        let size: Int64
        let modified: timespec
        let changed: timespec
        init(_ info: stat) { identity = .from(info); size = info.st_size; modified = info.st_mtimespec; changed = info.st_ctimespec }
        static func == (a: Self, b: Self) -> Bool {
            a.identity == b.identity && a.size == b.size && a.modified.tv_sec == b.modified.tv_sec
                && a.modified.tv_nsec == b.modified.tv_nsec && a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
        }
    }

    @concurrent package static func open(_ url: URL, chosen: ChosenFile? = nil) async throws -> HTMLPreviewDocument {
        try Task.checkCancellation()
        return try HTMLPreviewDocument(url, expected: chosen)
    }

    private init(_ source: URL, expected: ChosenFile?) throws {
        guard source.isFileURL else { throw PreviewError.unsupported }
        let chosen: ChosenFile
        if let expected {
            guard source.path.utf8.elementsEqual(expected.url.path.utf8) else { throw POSIXError(.ESTALE) }
            chosen = expected
        } else { chosen = try ChosenFile(source) }
        self.chosen = chosen
        let opened = try chosen.withParent { parent, name, _ -> (Int32, Stamp, Data) in
            let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(.EACCES) }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, FileIdentity.from(info) == chosen.identity,
                  info.st_size >= 0, info.st_size <= TextFile.limit else { throw PreviewError.unsupported }
            let bytes = try Self.bytes(fd, limit: TextFile.limit)
            guard let text = TextFile.decode(bytes), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PreviewError.unsupported
            }
            var after = stat()
            guard fstat(fd, &after) == 0, Stamp(info) == Stamp(after) else { throw POSIXError(.ESTALE) }
            let directory = openat(parent, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw POSIXError(.EACCES) }
            let prefix = Self.head
            return (directory, Stamp(after), Data((prefix + HTMLPreviewMarkup.prepare(text)).utf8))
        }
        folder = opened.0; stamp = opened.1; document = opened.2
        sourceURL = source
        url = URL(string: "\(Self.scheme)://\(UUID().uuidString.lowercased())/")!.appendingPathComponent(source.lastPathComponent)
    }

    /// Source uses the same captured choice, including when the document exceeds the rendered preview budget.
    @concurrent package static func source(_ chosen: ChosenFile) async throws -> TextFile {
        try Task.checkCancellation()
        return try chosen.withParent { parent, name, _ in
            let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(.EACCES) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, FileIdentity.from(info) == chosen.identity else {
                throw POSIXError(.ESTALE)
            }
            let data = try handle.read(upToCount: TextFile.limit + 1) ?? Data()
            let truncated = data.count > TextFile.limit
            var bytes = Data(data.prefix(TextFile.limit))
            if truncated, let newline = bytes.lastIndex(of: 10) { bytes = bytes.prefix(upTo: newline) }
            guard let text = TextFile.decode(bytes) else { throw PreviewError.unsupported }
            var after = stat()
            guard fstat(fd, &after) == 0, Stamp(info) == Stamp(after) else { throw POSIXError(.ESTALE) }
            try Task.checkCancellation()
            return TextFile(text: TextFile.normalizeNewlines(text), isTruncated: truncated)
        }
    }

    deinit { close(folder) }

    package func verify() throws {
        try Task.checkCancellation()
        try chosen.withParent { _, _, current in
            guard Stamp(current) == stamp else { throw POSIXError(.ESTALE) }
        }
    }

    package func read(_ request: URL) throws -> HTMLPreviewResource {
        try verify()
        let parts = try Self.components(request, origin: url)
        if parts.count == 1, parts[0].utf8.elementsEqual(sourceURL.lastPathComponent.utf8) { return HTMLPreviewResource(data: document, mime: "text/html; charset=utf-8") }
        let key = parts.joined(separator: "/")
        let raw = Data(key.utf8)
        if let cached = cache[raw] { return cached }
        guard attempts.count < Self.requestLimit, attempts.insert(raw).inserted else { throw PreviewError.unsupported }
        let ext = (key as NSString).pathExtension.lowercased()
        let css = ext == "css"
        guard css || ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "tif", "tiff", "ico", "bmp"].contains(ext) else {
            throw PreviewError.unsupported
        }
        var parent = dup(folder)
        guard parent >= 0 else { throw POSIXError(.EIO) }
        defer { close(parent) }
        for part in parts.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw POSIXError(.EACCES) }
            close(parent); parent = next
        }
        let fd = openat(parent, parts.last!, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        defer { close(fd) }
        var info = stat()
        let limit = min(remainingBytes, css ? 256 << 10 : 4 << 20)
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= limit else {
            throw PreviewError.unsupported
        }
        let bytes = try Self.bytes(fd, limit: limit)
        remainingBytes -= bytes.count
        let resource: HTMLPreviewResource
        if css {
            guard let text = TextFile.decode(bytes) else { throw PreviewError.unsupported }
            let data = Data(text.utf8)
            guard data.count <= bytes.count + remainingBytes else { throw PreviewError.unsupported }
            remainingBytes -= max(0, data.count - bytes.count)
            resource = HTMLPreviewResource(data: data, mime: "text/css; charset=utf-8")
        } else {
            guard let image = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(image) > 0, CGImageSourceGetCount(image) <= 32,
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= min(8_000_000, remainingPixels) / height else { throw PreviewError.unsupported }
            remainingPixels -= width * height
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: 2048,
            ] as CFDictionary) else { throw PreviewError.unsupported }
            let output = NSMutableData()
            guard let writer = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw PreviewError.unsupported }
            CGImageDestinationAddImage(writer, thumbnail, nil)
            guard CGImageDestinationFinalize(writer), output.length <= remainingBytes else { throw PreviewError.unsupported }
            remainingBytes -= output.length
            resource = HTMLPreviewResource(data: output as Data, mime: "image/png")
        }
        var after = stat()
        guard fstat(fd, &after) == 0, Stamp(info) == Stamp(after) else { throw POSIXError(.ESTALE) }
        try verify()
        cache[raw] = resource
        return resource
    }

    /// URLs never become filesystem paths until every decoded component has been checked.
    nonisolated package static func components(_ request: URL, origin: URL) throws -> [String] {
        guard request.scheme == scheme, request.host == origin.host, request.user == nil, request.password == nil,
              request.port == nil, request.absoluteString.utf8.count <= 4096,
              let encoded = URLComponents(url: request, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              encoded.hasPrefix("/") else { throw PreviewError.unsupported }
        let parts = encoded.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map { String($0).removingPercentEncoding }
        guard !parts.isEmpty, parts.count <= 16 else { throw PreviewError.unsupported }
        return try parts.map { part in
            guard let part, !part.isEmpty, part != ".", part != "..", part.utf8.count <= 255,
                  !part.unicodeScalars.contains(where: { $0 == "/" || $0 == "\\" || CharacterSet.controlCharacters.contains($0) }) else {
                throw PreviewError.unsupported
            }
            return part
        }
    }

    private nonisolated static func bytes(_ fd: Int32, limit: Int) throws -> Data {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw PreviewError.unsupported }
        try Task.checkCancellation()
        return data
    }
}

/// WebKit still parses the document. Remove network hints and competing base/refresh metadata before it does so.
/// Scanning every tag-like sequence also removes hints hidden in malformed comments, without guessing HTML's repair rules.
nonisolated package enum HTMLPreviewMarkup {
    /// Text as HTML shows it, in an element or a quoted attribute.
    package static func escaped(_ text: String) -> String {
        var escaped = ""
        for character in text.unicodeScalars {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.unicodeScalars.append(character)
            }
        }
        return escaped
    }

    package static func prepare(_ html: String) -> String {
        let bytes = Array(html.utf8)
        var output: [UInt8] = [], i = 0
        output.reserveCapacity(bytes.count)
        while i < bytes.count {
            guard bytes[i] == 60 else { output.append(bytes[i]); i += 1; continue }
            let start = i
            var nameEnd = i + 1
            while nameEnd < bytes.count, (65...90).contains(bytes[nameEnd]) || (97...122).contains(bytes[nameEnd]) { nameEnd += 1 }
            let name = String(decoding: bytes[(i+1)..<nameEnd], as: UTF8.self).lowercased()
            guard ["meta", "base", "link"].contains(name), nameEnd < bytes.count,
                  [9, 10, 12, 13, 32, 47, 62].contains(bytes[nameEnd]) else { output.append(bytes[i]); i += 1; continue }
            var end = nameEnd, quote: UInt8?
            while end < bytes.count {
                let byte = bytes[end]
                if let active = quote { if byte == active { quote = nil } }
                else if byte == 34 || byte == 39 { quote = byte }
                else if byte == 62 { break }
                end += 1
            }
            guard end < bytes.count else { break }
            if name == "link", let sheet = stylesheet(Array(bytes[nameEnd..<end])) {
                let media = sheet.media.map { " media=\"\(escaped($0))\"" } ?? ""
                let href = escaped(sheet.href)
                output.append(contentsOf: "<link rel=\"stylesheet\" href=\"\(href)\"\(media)>".utf8)
            }
            i = max(start + 1, end + 1)
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func stylesheet(_ bytes: [UInt8]) -> (href: String, media: String?)? {
        guard bytes.count <= 8192 else { return nil }
        var values: [String: String] = [:], i = 0
        func space(_ byte: UInt8) -> Bool { [9, 10, 12, 13, 32].contains(byte) }
        while i < bytes.count {
            while i < bytes.count, space(bytes[i]) { i += 1 }
            if i == bytes.count || bytes[i] == 47 { break }
            let start = i
            while i < bytes.count, !space(bytes[i]), bytes[i] != 61 { i += 1 }
            let name = String(decoding: bytes[start..<i], as: UTF8.self).lowercased()
            guard !name.isEmpty, values[name] == nil, values.count < 32 else { return nil }
            while i < bytes.count, space(bytes[i]) { i += 1 }
            guard i < bytes.count, bytes[i] == 61 else { return nil }
            i += 1
            while i < bytes.count, space(bytes[i]) { i += 1 }
            guard i < bytes.count else { return nil }
            let value: String
            if bytes[i] == 34 || bytes[i] == 39 {
                let quote = bytes[i]; i += 1
                let start = i
                while i < bytes.count, bytes[i] != quote { i += 1 }
                guard i < bytes.count else { return nil }
                value = String(decoding: bytes[start..<i], as: UTF8.self); i += 1
            } else {
                let start = i
                while i < bytes.count, !space(bytes[i]) { i += 1 }
                value = String(decoding: bytes[start..<i], as: UTF8.self)
            }
            values[name] = value
        }
        guard values["rel"]?.lowercased() == "stylesheet", let href = values["href"] else { return nil }
        return (href, values["media"])
    }
}
