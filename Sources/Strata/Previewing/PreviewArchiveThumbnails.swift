import AppKit

/// Virtual pages are decoded in memory; contact sheets never create export leases or ask for passwords.
@MainActor final class PreviewArchiveThumbnails {
    private struct Request {
        let id = UUID()
        let owner: ObjectIdentifier
        let path: [String]
        let pixels: Int
        let key: String
        let source: PreviewArchiveSource
        let finished: (() -> Void)?
        let completion: (NSImage) -> Void
    }
    private let cache = ThumbnailCache(costLimit: 32 << 20, countLimit: 128)
    private let access: PreviewArchiveAccess
    private var source: PreviewArchiveSource?
    private var waiting: [Request] = []
    private var active: [UUID: Task<Void, Never>] = [:]
    private var current: [ObjectIdentifier: UUID] = [:]
    init(access: PreviewArchiveAccess) { self.access = access }
    isolated deinit { cancelAll() }
    var pendingTasks: [Task<Void, Never>] { Array(active.values) }
    var sourceID: ObjectIdentifier? { access.source.map(ObjectIdentifier.init) }
    func canRequest(_ item: PreviewItem) -> Bool {
        guard case .member = item.source, !item.isDirectory, let size = item.size,
              (0...(8 << 20)).contains(size), access.source != nil else { return false }
        return BookFormat.images.contains((item.name as NSString).pathExtension.lowercased())
    }

    func cancel(_ owner: AnyObject) {
        guard let id = current.removeValue(forKey: ObjectIdentifier(owner)) else { return }
        waiting.removeAll { $0.id == id }
        active[id]?.cancel()
    }
    func cancelAll() {
        waiting = []; current = [:]
        active.values.forEach { $0.cancel() }
    }
    func request(_ owner: AnyObject, item: PreviewItem, pixels: Int, finished: (() -> Void)? = nil, completion: @escaping (NSImage) -> Void) {
        cancel(owner)
        guard case .member(_, let path) = item.source, !item.isDirectory,
              BookFormat.images.contains((item.name as NSString).pathExtension.lowercased()),
              let size = item.size, size >= 0, size <= 8 << 20, let source = access.source else { finished?(); return }
        if self.source !== source { cancelAll(); cache.removeAll(); self.source = source }
        let key = path.joined(separator: "/") + "|\(pixels)"
        if let image = cache.image(forKey: key) { completion(image); finished?(); return }
        let request = Request(owner: ObjectIdentifier(owner), path: path, pixels: pixels, key: key, source: source, finished: finished, completion: completion)
        current[request.owner] = request.id
        waiting.append(request)
        drain()
    }
    private func drain() {
        // Queue visible pages here, so a newly selected full-size preview isn't stuck behind every grid cell.
        while active.count < 2, !waiting.isEmpty {
            let request = waiting.removeFirst(), access = access
            active[request.id] = Task { [weak self] in
                let image: CGImage?
                do {
                    let records = try await access.read(member: request.path, prompt: false)
                    guard records.count == 1, let body = records[0].body else { throw PreviewError.unsupported }
                    image = try await Self.decode(body, pixels: request.pixels)
                } catch { image = nil }
                guard let self else { return }
                active[request.id] = nil
                defer { drain() }
                guard current[request.owner] == request.id else { return }
                current[request.owner] = nil
                defer { request.finished?() }
                guard !Task.isCancelled, access.source === request.source, let image else { return }
                let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                cache.insert(result, forKey: request.key, cost: image.bytesPerRow * image.height)
                request.completion(result)
            }
        }
    }
    @concurrent private static func decode(_ data: Data, pixels: Int) async throws -> CGImage {
        try Task.checkCancellation()
        return try PreviewPicture(data).thumbnail(pixels: pixels)
    }
}
