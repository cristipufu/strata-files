import Foundation

nonisolated package enum WebPreviewContent: Sendable {
    case buffered(HTMLWebSession.Reader), streamed(HTMLWebSession.StreamReader)

    enum Resource: Sendable {
        case buffered(HTMLPreviewResource), streamed(WebPreviewStream)
        var mime: String {
            switch self { case .buffered(let value): value.mime; case .streamed(let value): value.mime }
        }
        var byteCount: Int {
            switch self { case .buffered(let value): value.data.count; case .streamed(let value): value.byteCount }
        }
    }

    func resource(_ url: URL) async throws -> Resource {
        switch self {
        case .buffered(let read): .buffered(try await read(url))
        case .streamed(let read): .streamed(try await read(url))
        }
    }
}

nonisolated package struct WebPreviewStream: Sendable {
    package typealias Yield = @MainActor @Sendable (Data) -> Bool
    package typealias Producer = @Sendable (@escaping Yield) async throws -> Void
    package let mime: String
    package let byteCount: Int
    package let produce: Producer

    package init(mime: String, byteCount: Int, produce: @escaping Producer) {
        self.mime = mime
        self.byteCount = byteCount
        self.produce = produce
    }
}
