import Foundation
import StrataModel
import StrataSupport

nonisolated package final class PDFPreviewDocument: Sendable {
    package static let byteLimit: Int64 = 512 << 20
    package static let chunkSize = 1 << 20
    private static let headerSize = 1024
    private static let requestLimit = 2
    package let url: URL
    private let source: FileReadSource

    private init(source: FileReadSource) {
        self.source = source
        url = URL(string: "\(HTMLPreviewDocument.scheme)://\(UUID().uuidString.lowercased())/document.pdf")!
    }

    @concurrent package static func open(_ url: URL) async throws -> PDFPreviewDocument {
        try Task.checkCancellation()
        let source = try (await OwnThread.run { Result { try FileReadSource(url) } }).get()
        try Task.checkCancellation()
        guard source.size > 0 else { throw PreviewError.empty }
        guard source.size <= byteLimit else {
            throw PreviewError.message(String(localized: "This file is too large to preview."))
        }
        let isPDF = try await source.read { file in
            try (await OwnThread.run { Result {
                var currentURL = source.chosen.url
                currentURL.removeAllCachedResourceValues()
                if try currentURL.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true { return false }
                let header = try FileRead.chunk(file, upToCount: headerSize) ?? Data()
                guard header.range(of: Data("%PDF-".utf8)) != nil else {
                    throw PreviewError.message(String(localized: "No Preview Available"))
                }
                return true
            } }).get()
        }
        guard isPDF else { throw PreviewError.unsupported }
        return PDFPreviewDocument(source: source)
    }

    package func page() -> PreviewWebPage.Document {
        PreviewWebPage.Document(url: url, stream: { requested in
            guard requested == self.url else { throw URLError(.noPermissionsToReadFile) }
            return WebPreviewStream(mime: "application/pdf", byteCount: Int(self.source.size)) { yield in
                try await Self.deliver(self.source, to: yield)
            }
        }, limits: .init(requests: Self.requestLimit, bytes: Int(source.size) * Self.requestLimit))
    }

    @concurrent private static func deliver(_ source: FileReadSource, to yield: @escaping WebPreviewStream.Yield) async throws {
        try await source.read { file in
            var remaining = source.size
            while remaining > 0 {
                try Task.checkCancellation()
                let count = Int(min(Int64(chunkSize), remaining))
                let data = try (await OwnThread.run { Result { try FileRead.chunk(file, upToCount: count) ?? Data() } }).get()
                guard !data.isEmpty, data.count <= count else { throw POSIXError(.EIO) }
                try Task.checkCancellation()
                guard await yield(data) else { throw CancellationError() }
                remaining -= Int64(data.count)
            }
        }
    }
}
