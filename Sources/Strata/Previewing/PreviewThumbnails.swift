import AppKit

/// A preview asks for visible thumbnails only, with a small generation allowance shared by its own cells.
@MainActor final class PreviewThumbnails {
    private final class Request {
        let entry: FileEntry
        let size: CGFloat
        let scale: CGFloat
        let image: (NSImage) -> Void
        var ticket: FileThumbnails.Ticket?

        init(entry: FileEntry, size: CGFloat, scale: CGFloat, image: @escaping (NSImage) -> Void) {
            self.entry = entry
            self.size = size
            self.scale = scale
            self.image = image
        }
    }

    private let thumbnails: FileThumbnails
    private let limit: Int
    private var pending: [(ObjectIdentifier, Request)] = []
    private var active: [ObjectIdentifier: Request] = [:]
    private var draining = false
    private var isClosed = false

    init(thumbnails: FileThumbnails, limit: Int = 8) {
        self.thumbnails = thumbnails
        self.limit = max(1, min(limit, 32))
    }

    isolated deinit { close() }

    func request(for owner: AnyObject, entry: FileEntry, size: CGFloat, scale: CGFloat, image: @escaping (NSImage) -> Void) {
        guard !isClosed else { return }
        cancel(for: owner)
        guard entry.isRegular else { return }
        let size = size.isFinite ? min(max(size, 32), 256) : 80
        let scale = scale.isFinite && scale > 0 ? min(scale, 4) : 1
        pending.append((ObjectIdentifier(owner), Request(entry: entry, size: size, scale: scale, image: image)))
        drain()
    }

    func cancel(for owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        pending.removeAll { $0.0 == key }
        if let request = active.removeValue(forKey: key) { thumbnails.cancel(request.ticket) }
        drain()
    }

    func cancelAll() {
        pending = []
        let requests = active.values
        active = [:]
        for request in requests { thumbnails.cancel(request.ticket) }
    }

    func close() {
        isClosed = true
        cancelAll()
    }

    private func drain() {
        guard !draining, !isClosed else { return }
        draining = true
        defer { draining = false }
        while active.count < limit, !pending.isEmpty {
            let (key, request) = pending.removeFirst()
            guard request.entry.isRegular else { continue }
            active[key] = request
            request.ticket = thumbnails.request(request.entry, size: request.size, scale: request.scale, finished: { [weak self, weak request] in
                guard let self, let request, active[key] === request else { return }
                active[key] = nil
                drain()
            }) { [weak self, weak request] image in
                guard let self, let request, active[key] === request else { return }
                request.image(image)
            }
        }
    }
}
