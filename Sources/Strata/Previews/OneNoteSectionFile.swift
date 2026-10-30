import Foundation
import ImageIO

/// A section open for previewing, read only from the file it was chosen as: each read checks before and after that the
/// file is still that one, unchanged.
package actor OneNoteSectionFile {
    nonisolated package let pages: [OneNotePage]
    nonisolated package let damaged: Int
    private let source: PreviewArchiveSource
    private let file: FileHandle
    private let reader: OneNoteSectionReader
    /// What `isRaster` found, so a page shown again doesn't read its pictures' first bytes again.
    private var rasters: [OneNoteData: Bool] = [:]

    @concurrent package static func open(_ source: PreviewArchiveSource) async throws -> OneNoteSectionFile {
        try Task.checkCancellation()
        return try OneNoteSectionFile(source)
    }

    private init(_ source: PreviewArchiveSource) throws {
        let file = try source.open()
        let reader = try Self.section { try OneNoteSectionReader(file) }
        try source.verify(file)
        self.source = source
        self.file = file
        self.reader = reader
        pages = reader.pages
        damaged = reader.damaged
    }

    /// The page as HTML, naming no more than `pictureLimit` of its pictures for WebKit to ask for, each no larger than
    /// `pictureBytes`.
    package func markup(of page: OneNotePage, pictureLimit: Int, pictureBytes: Int) throws -> OneNotePageMarkup {
        try source.verify(file)
        let content = try reader.content(of: page)
        let markup = OneNotePageMarkup(content, pictureLimit: pictureLimit) { data in
            data.count <= UInt64(max(pictureBytes, 0)) && isRaster(data)
        }
        try source.verify(file)
        return markup
    }

    package func bytes(of data: OneNoteData, limit: Int) throws -> Data {
        guard limit >= 0, data.count <= UInt64(limit) else { throw PreviewError.unsupported }
        try source.verify(file)
        let bytes = try reader.bytes(of: data)
        try source.verify(file)
        return bytes
    }

    /// Whether ImageIO knows a picture by its first bytes, as one it can decode for WebKit, and not one too large to:
    /// a Windows metafile, as a printout is, isn't one. Every format it decodes says what it is, and its size, within
    /// 64 KB, a photo's EXIF block included; one whose size isn't there yet is taken at its word.
    private func isRaster(_ data: OneNoteData) -> Bool {
        if let known = rasters[data] { return known }
        let found = readsAsRaster(data)
        rasters[data] = found
        return found
    }

    private func readsAsRaster(_ data: OneNoteData) -> Bool {
        let prefix = OneNoteData(offset: data.offset, count: min(data.count, 64 << 10))
        guard let bytes = try? reader.bytes(of: prefix),
              let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetType(source) != nil
        else { return false }
        let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let width = info?[kCGImagePropertyPixelWidth] as? Int,
              let height = info?[kCGImagePropertyPixelHeight] as? Int, height > 0 else { return true }
        return width <= PreviewPicture.pixelLimit / height
    }

    /// Runs a read of the section, saying calmly why it can't be shown, or handing it to Quick Look.
    static func section<Value>(_ read: () throws -> Value) throws -> Value {
        do {
            return try read()
        } catch let error as OneStoreError {
            throw shown(error)
        }
    }

    static func shown(_ error: OneStoreError) -> PreviewError {
        switch error {
        case .notOneNote: .unsupported
        case .encrypted: .message(String(localized: "This section is protected with a password."), symbol: "lock")
        case .unsupportedVersion:
            .message(String(localized: "This section was saved by a version of OneNote this preview can’t read."))
        case .tooLarge: .message(String(localized: "This section is too large to preview."))
        case .malformed: .message(String(localized: "This file couldn’t be read."))
        }
    }
}
