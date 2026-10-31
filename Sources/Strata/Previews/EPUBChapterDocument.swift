import Foundation
import StrataSupport

/// An EPUB chapter uses the same offline WebKit boundary as an HTML file, without unpacking onto disk.
package actor EPUBChapterDocument {
    nonisolated package let url: URL
    private let book: EPUBBook
    private let path: [String]
    package typealias Reader = @Sendable (PreviewArchiveSource, [PreviewArchiveRecord], [String], Int) async throws -> Data
    nonisolated private struct Job: Sendable {
        let id = UUID()
        let task: Task<Data, Error>
        var waiters: Set<UUID>
    }
    private let reader: Reader
    private var jobs: [String: Job] = [:]
    package var pendingWaiterCount: Int { jobs.values.reduce(0) { $0 + $1.waiters.count } }
    private var readCount = 0
    private var cache: [String: HTMLPreviewResource] = [:]
    private var remaining = HTMLPreviewDocument.assetLimit
    private var pixels = 16_000_000

    package init(book: EPUBBook, chapter: Int, reader: @escaping Reader = { try await EPUBBook.bytes($0, records: $1, path: $2, limit: $3) }) throws {
        self.reader = reader
        guard book.chapters.indices.contains(chapter) else { throw PreviewError.unsupported }
        self.book = book
        path = book.chapters[chapter].path
        var origin = URL(string: "strata-html://\(UUID().uuidString.lowercased())/")!
        for part in path { origin.appendPathComponent(part) }
        url = origin
    }

    deinit { jobs.values.forEach { $0.task.cancel() } }

    private func release(_ key: String, jobID: UUID, waiter: UUID) {
        guard var job = jobs[key], job.id == jobID, job.waiters.remove(waiter) != nil else { return }
        if job.waiters.isEmpty { jobs[key] = nil; job.task.cancel() }
        else { jobs[key] = job }
    }

    private static let readingStyle = """
    <style>body { box-sizing: border-box; width: 100% !important; max-width: 48rem !important;
    margin: 0 auto !important; line-height: 1.55;
    padding: 24px clamp(16px, 5vw, 48px) 40px !important; overflow-wrap: anywhere; }
    img { max-width: 100% !important; height: auto !important; }
    pre { white-space: pre-wrap; overflow-wrap: anywhere; }</style>
    """

    package func read(_ request: URL) async throws -> HTMLPreviewResource {
        try Task.checkCancellation()
        let parts = try HTMLPreviewDocument.components(request, origin: url)
        let key = parts.joined(separator: "/")
        let file = try book.source.open(); defer { try? file.close() }
        try book.source.verify(file)
        if let cached = cache[key] { return cached }
        let chapter = parts == path
        guard chapter || book.assets.contains(key) else { throw PreviewError.unsupported }
        let css = (key as NSString).pathExtension.lowercased() == "css"
        let waiter = UUID(), job: Job
        if var existing = jobs[key] {
            existing.waiters.insert(waiter); jobs[key] = existing; job = existing
        } else {
            guard readCount < 32 else { throw PreviewError.unsupported }
            readCount += 1
            let limit = min(remaining, chapter ? TextFile.limit : css ? 256 << 10 : 4 << 20)
            guard let size = book.records.first(where: { $0.path == parts })?.size, size >= 0, size <= limit else { throw PreviewError.unsupported }
            // Reserve once, before suspending; duplicate URLs share the read and its allowance.
            remaining -= Int(size)
            let reader = reader, source = book.source, records = book.records
            job = Job(task: Task { try await reader(source, records, parts, limit) }, waiters: [waiter])
            jobs[key] = job
        }
        defer { release(key, jobID: job.id, waiter: waiter) }
        let data = try await withTaskCancellationHandler {
            let data = try await job.task.value
            try Task.checkCancellation()
            return data
        } onCancel: {
            Task { await self.release(key, jobID: job.id, waiter: waiter) }
        }
        try book.source.verify(file)
        if let cached = cache[key] { return cached }
        let resource: HTMLPreviewResource
        if chapter || css {
            guard let text = TextFile.decode(data) else { throw PreviewError.unsupported }
            let prefix = chapter ? HTMLPreviewDocument.head : ""
            let output = Data((prefix + (chapter ? HTMLPreviewMarkup.prepare(text) + Self.readingStyle : text)).utf8)
            guard output.count - data.count <= remaining else { throw PreviewError.unsupported }
            remaining -= max(0, output.count - data.count)
            resource = HTMLPreviewResource(data: output, mime: chapter ? "text/html; charset=utf-8" : "text/css; charset=utf-8")
        } else {
            resource = try HTMLPreviewResource.picture(data, pixels: &pixels, bytes: &remaining)
        }
        try Task.checkCancellation()
        try book.source.verify(file)
        cache[key] = resource
        return resource
    }
}
