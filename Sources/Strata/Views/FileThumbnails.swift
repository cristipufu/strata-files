import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Quick Look thumbnails for the file views and the column preview, generated on demand and cached by path,
/// modification date and size bucket. Requests for the same thumbnail are coalesced; cancelling the last
/// interested caller cancels the generation.
final class FileThumbnails {
    static let shared = FileThumbnails(copies: .live, containerStore: .shared)

    typealias Completion = @Sendable (CGImage?, Bool) -> Void
    typealias Generate = (QLThumbnailGenerator.Request, @escaping Completion) -> Void

    /// Point sizes thumbnails are generated at; a request uses the smallest bucket that covers it.
    private static let buckets: [CGFloat] = [32, 64, 128, 256, 512]

    final class Ticket {
        fileprivate let key: String
        fileprivate let id: Int
        fileprivate init(key: String, id: Int) {
            self.key = key
            self.id = id
        }
    }

    private struct Pending {
        var entry: FileEntry
        var request: QLThumbnailGenerator.Request
        var generation: Int
        var coverSource: PreviewArchiveSource?
        var callbacks: [Int: Observer]
    }

    private struct Observer {
        let image: (NSImage) -> Void
        let finished: (() -> Void)?
    }

    private let covers: BookCoverThumbnails
    private let cache: ThumbnailCache
    let copies: CopyProviders
    let containerStore: ContainerStore
    private let generate: Generate
    private let cancelGeneration: (QLThumbnailGenerator.Request) -> Void
    private var pending: [String: Pending] = [:]
    /// Keys Quick Look had nothing for, so they aren't asked for again.
    private var failed: Set<String> = []
    private var keysByPath: [String: Set<String>] = [:]
    private var nextID = 0

    init(cache: ThumbnailCache = ThumbnailCache(), coverReader: @escaping BookCoverThumbnails.Reader = { try await BookFormat.cover($0, pixels: $1) }, copies: CopyProviders, containerStore: ContainerStore, generate: @escaping Generate = { request, completion in
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
            let cancelled = (error as? CocoaError)?.code == .userCancelled || (error as NSError?)?.code == NSUserCancelledError
            completion(representation?.cgImage, cancelled)
        }
    }, cancel: @escaping (QLThumbnailGenerator.Request) -> Void = { QLThumbnailGenerator.shared.cancel($0) }) {
        covers = BookCoverThumbnails(reader: coverReader)
        self.cache = cache
        self.copies = copies
        self.containerStore = containerStore
        self.generate = generate
        cancelGeneration = cancel
    }

    func icon(for entry: FileEntry) -> NSImage {
        IconCache.shared.icon(for: entry, containerCopies: copies.containerCopies, containerStore: containerStore)
    }

    func canThumbnail(_ entry: FileEntry) -> Bool {
        guard Self.canThumbnail(entry, copies: copies) else {
            invalidate(entry)
            return false
        }
        return true
    }

    /// Whether to ask Quick Look for a thumbnail. Like Finder, every file is asked, so any type with a thumbnail
    /// (including ones an app adds) gets one, and Quick Look's "no thumbnail" keeps the icon. Folders, apps and other
    /// bundles, ordinary archives, disk images and executables are pictured by their icon, and links keep their arrow.
    static func canThumbnail(_ entry: FileEntry, copies: CopyProviders) -> Bool {
        // A container's file not fetched yet has nothing to show.
        guard !entry.isFolder, !entry.isSymlink, !copies.isPlaceholder(entry.url) else { return false }
        if BookFormat.hasCover(entry.url) { return !entry.isPackage }
        guard let type = entry.contentType else { return !entry.isPackage }
        return !(type.conforms(to: .bundle) || type.conforms(to: .application) || type.conforms(to: .archive)
            || type.conforms(to: .diskImage) || type.conforms(to: .unixExecutable) || type.conforms(to: .aliasFile)
            || type.conforms(to: .symbolicLink) || type.conforms(to: .volume))
    }

    static func bucket(for size: CGFloat) -> CGFloat {
        buckets.first(where: { $0 >= size }) ?? buckets.last ?? 512
    }

    private func key(_ entry: FileEntry, _ bucket: CGFloat, _ scale: CGFloat) -> String {
        let stamp = entry.modified?.timeIntervalSinceReferenceDate ?? 0
        let product = Double(bucket * scale)
        let pixels = product.isFinite ? (saturatingInt64(product).map(Int.init(clamping:)) ?? 0) : 0
        return "\(entry.url.path)|\(stamp)|\(entry.size ?? -1)|\(pixels)"
    }

    private func invalidate(_ entry: FileEntry) {
        guard let keys = keysByPath.removeValue(forKey: entry.url.path) else { return }
        for key in keys {
            cache.remove(forKey: key)
            failed.remove(key)
            if let item = pending.removeValue(forKey: key) {
                covers.cancel(item.generation)
                cancelGeneration(item.request)
                for observer in item.callbacks.values { observer.finished?() }
            }
        }
    }

    /// The best thumbnail already in memory for `size`: an exact or larger bucket, else a smaller one.
    /// `exact` tells whether it's sharp enough or a better one should still be requested.
    func cached(_ entry: FileEntry, size: CGFloat, scale: CGFloat) -> (image: NSImage, exact: Bool)? {
        guard canThumbnail(entry) else { return nil }
        let wanted = Self.bucket(for: size)
        for b in Self.buckets where b >= wanted {
            if let image = cache.image(forKey: key(entry, b, scale)) { return (image, true) }
        }
        for b in Self.buckets.reversed() where b < wanted {
            if let image = cache.image(forKey: key(entry, b, scale)) { return (image, false) }
        }
        return nil
    }

    /// Whether Quick Look already said it has no thumbnail for this file.
    func hasFailed(_ entry: FileEntry, size: CGFloat, scale: CGFloat) -> Bool {
        guard canThumbnail(entry) else { return false }
        return failed.contains(key(entry, Self.bucket(for: size), scale))
    }

    /// Generates a thumbnail; `completion` runs on the main actor, only on success and only if not cancelled.
    /// `finished` also reports failures and cache hits, so bounded consumers can release their allowance. Cancelling
    /// a ticket removes both callbacks; the caller already knows it cancelled that request.
    @discardableResult
    func request(_ entry: FileEntry, size: CGFloat, scale: CGFloat, finished: (() -> Void)? = nil,
                 completion: @escaping (NSImage) -> Void) -> Ticket? {
        guard canThumbnail(entry) else { finished?(); return nil }
        let bucket = Self.bucket(for: size)
        let key = key(entry, bucket, scale)
        if failed.contains(key) { finished?(); return nil }
        if let image = cache.image(forKey: key) {
            completion(image)
            finished?()
            return nil
        }
        nextID += 1
        let ticket = Ticket(key: key, id: nextID)
        if pending[key] != nil {
            pending[key]?.callbacks[ticket.id] = Observer(image: completion, finished: finished)
            return ticket
        }
        let request = QLThumbnailGenerator.Request(fileAt: entry.url, size: CGSize(width: bucket, height: bucket),
                                                   scale: scale, representationTypes: .thumbnail)
        request.iconMode = true
        let generation = ticket.id
        if keysByPath.count >= 50_000, keysByPath[entry.url.path] == nil {
            keysByPath.removeAll(keepingCapacity: true)
        }
        keysByPath[entry.url.path, default: []].insert(key)
        let coverSource = BookFormat.hasCover(entry.url) ? try? PreviewArchiveSource(entry.url) : nil
        pending[key] = Pending(entry: entry, request: request, generation: generation, coverSource: coverSource,
                               callbacks: [ticket.id: Observer(image: completion, finished: finished)])
        generate(request) { [weak self] original, cancelled in
            let original = original.flatMap { Self.bounded($0) ? $0 : nil }
            // Icon-mode thumbnails sit on a square transparent canvas; trim it so wide images can bottom-align.
            let image = original.map { FileThumbnails.trimmed($0) }
            // A cropped CGImage can retain the original backing, so charge its full decoded size.
            let cost = original.map { $0.bytesPerRow * $0.height } ?? 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.pending[key]?.generation == generation else { return }
                    if image == nil, !cancelled, let source = self.pending[key]?.coverSource, self.canThumbnail(entry) {
                        self.covers.request(id: generation, source: source, pixels: Int(min(2048, bucket * max(scale, 1)))) { [weak self] cover in
                            self?.finish(key, generation: generation, cover, cancelled: false, cost: cover.map { $0.bytesPerRow * $0.height } ?? 0)
                        }
                    } else {
                        self.finish(key, generation: generation, image, cancelled: cancelled, cost: cost)
                    }
                }
            }
        }
        return ticket
    }

    nonisolated private static func bounded(_ image: CGImage) -> Bool {
        guard image.width > 0, image.height > 0, image.width <= 4096, image.height <= 4096 else { return false }
        let (bytes, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        return !overflow && bytes <= 128 << 20
    }

    func cancel(_ ticket: Ticket?) {
        guard let ticket, var entry = pending[ticket.key] else { return }
        entry.callbacks[ticket.id] = nil
        if entry.callbacks.isEmpty {
            pending[ticket.key] = nil
            covers.cancel(entry.generation)
            cancelGeneration(entry.request)
        } else {
            pending[ticket.key] = entry
        }
    }

    /// Crops the transparent canvas around the thumbnail's opaque body, keeping a margin wide enough for the soft
    /// drop shadow to fade out (no hard edge). Runs on Quick Look's callback thread.
    nonisolated static func trimmed(_ image: CGImage) -> CGImage {
        let width = image.width, height = image.height
        guard width > 2, height > 2, width <= 4096, height <= 4096,
              image.alphaInfo != .none, image.alphaInfo != .noneSkipLast,
              image.alphaInfo != .noneSkipFirst else { return image }
        var alpha = [UInt8](repeating: 0, count: width * height)
        let drawn = alpha.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return image }
        let threshold: UInt8 = 128
        var top = height, bottom = -1, left = width, right = -1
        for y in 0..<height {
            let row = y * width
            var rowHasInk = false
            for x in 0..<width where alpha[row + x] > threshold {
                rowHasInk = true
                if x < left { left = x }
                break
            }
            guard rowHasInk else { continue }
            var x = width - 1
            while x > right, alpha[row + x] <= threshold { x -= 1 }
            if x > right { right = x }
            if y < top { top = y }
            bottom = y
        }
        guard bottom >= top, right >= left else { return image }
        // The shadow falls downward, so leave more room below than around.
        let side = Double(max(width, height))
        let margin = max(2, Int((side * 0.035).rounded()))
        let below = max(3, Int((side * 0.075).rounded()))
        let rect = CGRect(x: left - margin, y: top - margin, width: right - left + 1 + margin * 2,
                          height: bottom - top + 1 + margin + below)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width < CGFloat(width) - 2 || rect.height < CGFloat(height) - 2 else { return image }
        return image.cropping(to: rect) ?? image
    }

    private func finish(_ key: String, generation: Int, _ cgImage: CGImage?, cancelled: Bool, cost: Int) {
        // A cancelled request can still complete after a new one for the same key started; ignore it.
        guard let entry = pending[key], entry.generation == generation else { return }
        pending[key] = nil
        defer { for observer in entry.callbacks.values { observer.finished?() } }
        guard canThumbnail(entry.entry) else { return }
        guard let cgImage else {
            if !cancelled {
                // Every file is asked now, so most folders have some files without a thumbnail; keep this bounded.
                if failed.count >= 50_000 { failed.removeAll(keepingCapacity: true) }
                failed.insert(key)
            }
            return
        }
        // Point size: the pixel size at the request's scale (the canvas was bucket × scale pixels).
        let scale = max(CGFloat(entry.request.scale), 1)
        let factor = 1 / scale
        let image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) * factor,
                                                           height: CGFloat(cgImage.height) * factor))
        cache.insert(image, forKey: key, cost: cost)
        for observer in entry.callbacks.values { observer.image(image) }
    }
}

/// Small facts shown under icons, read off the main thread: a folder's item count, an image's pixel size.
@MainActor final class ItemInfoLoader {
    static let shared = ItemInfoLoader(copies: .live, containerStore: .shared)

    private var cache: [String: String] = [:]
    private(set) var tasks: [String: Task<Void, Never>] = [:]
    private var waiters: [String: [Int: (String) -> Void]] = [:]
    private var generations: [String: Int] = [:]
    private var nextID = 0
    let copies: CopyProviders
    let containerStore: ContainerStore
    private let mediaReader: MediaInfoLoader.Reader

    init(copies: CopyProviders, containerStore: ContainerStore, mediaReader: @escaping MediaInfoLoader.Reader = MediaInfoLoader.read) {
        self.copies = copies
        self.containerStore = containerStore
        self.mediaReader = mediaReader
    }

    isolated deinit { tasks.values.forEach { $0.cancel() } }

    final class Ticket {
        fileprivate let key: String
        fileprivate let id: Int
        fileprivate init(key: String, id: Int) {
            self.key = key
            self.id = id
        }
    }

    /// The text to show right away: a file's size, or a cached count/dimension. Nil means "ask `request`".
    func immediate(_ entry: FileEntry, showHidden: Bool) -> String? {
        // A container says whether it runs (its folder only holds what's been browsed, so no count).
        if entry.isDirectory, let (source, top) = copies.containerCopies.copy(containing: entry.url),
           top.standardizedFileURL == entry.url.standardizedFileURL {
            return switch containerStore.container(id: source.id)?.state {
            case .running?: String(localized: "Running", comment: "Container state")
            case .paused?: String(localized: "Paused", comment: "Container state")
            case .restarting?: String(localized: "Restarting", comment: "Container state")
            default: String(localized: "Not Running", comment: "Container state: stopped, exited or created")
            }
        }
        guard needsLoading(entry) else {
            return entry.isDirectory ? nil : entry.size.map(Format.bytes)
        }
        return cache[key(entry, showHidden)]
    }

    func needsLoading(_ entry: FileEntry) -> Bool {
        guard Self.canLoad(entry, copies: copies) else {
            invalidate(entry)
            return false
        }
        return true
    }

    nonisolated static func canLoad(_ entry: FileEntry, copies: CopyProviders) -> Bool {
        if entry.isFolder { return !entry.isSymlink && !entry.isVolume && !copies.contains(entry.url) }
        // A container's image not fetched yet: its size for now, its dimensions once it's here (not cached meanwhile).
        if copies.isPlaceholder(entry.url) { return false }
        return entry.contentType?.conforms(to: .audio) != true && MediaInfoLoader.canRead(entry, copies: copies)
    }

    private func key(_ entry: FileEntry, _ showHidden: Bool) -> String {
        "\(entry.url.path)|\(entry.modified?.timeIntervalSinceReferenceDate ?? 0)|\(showHidden)"
    }

    private func invalidate(_ entry: FileEntry) {
        for hidden in [false, true] {
            let key = key(entry, hidden)
            cache[key] = nil
            waiters[key] = nil
            generations[key] = nil
            if let task = tasks.removeValue(forKey: key) {
                task.cancel()
            }
        }
    }

    func request(_ entry: FileEntry, showHidden: Bool, completion: @escaping (String) -> Void) -> Ticket? {
        guard needsLoading(entry) else { return nil }
        let key = key(entry, showHidden)
        if let cached = cache[key] {
            completion(cached)
            return nil
        }
        nextID += 1
        let ticket = Ticket(key: key, id: nextID)
        waiters[key, default: [:]][ticket.id] = completion
        if tasks[key] == nil {
            let isFolder = entry.isFolder
            let fallback = entry.size.map(Format.bytes)
            let generation = ticket.id
            generations[key] = generation
            let copies = copies, mediaReader = mediaReader
            tasks[key] = Task { [weak self] in
                guard !Task.isCancelled else { return }
                guard Self.canLoad(entry, copies: copies) else {
                    guard let self else { return }
                    _ = needsLoading(entry)
                    drop(key, generation: generation)
                    return
                }
                let text = await Self.load(entry, isFolder: isFolder, showHidden: showHidden, mediaReader: mediaReader)
                guard let self, !Task.isCancelled, generations[key] == generation else { return }
                guard needsLoading(entry) else {
                    drop(key, generation: generation)
                    return
                }
                finish(key, generation: generation, text ?? fallback ?? "")
            }
        }
        return ticket
    }

    func cancel(_ ticket: Ticket?) {
        guard let ticket else { return }
        waiters[ticket.key]?[ticket.id] = nil
        if waiters[ticket.key]?.isEmpty == true {
            waiters[ticket.key] = nil
            generations[ticket.key] = nil
            tasks.removeValue(forKey: ticket.key)?.cancel()
        }
    }

    private func drop(_ key: String, generation: Int) {
        guard generations[key] == generation else { return }
        generations[key] = nil
        tasks[key] = nil
        waiters[key] = nil
    }

    private func finish(_ key: String, generation: Int, _ text: String) {
        guard generations[key] == generation else { return }
        generations[key] = nil
        tasks[key] = nil
        cache[key] = text
        if cache.count > 20000 { cache.removeAll(keepingCapacity: true) }
        for callback in (waiters.removeValue(forKey: key) ?? [:]).values { callback(text) }
    }

    @concurrent
    private nonisolated static func load(_ entry: FileEntry, isFolder: Bool, showHidden: Bool,
                                         mediaReader: @escaping MediaInfoLoader.Reader) async -> String? {
        if isFolder {
            guard let dir = opendir(entry.url.path) else { return nil }
            defer { closedir(dir) }
            var count = 0
            while let entry = readdir(dir) {
                if Task.isCancelled { return nil }
                guard let name = DirectoryEntryName.read(entry) else { return nil }
                if name == "." || name == ".." { continue }
                if !showHidden, name.hasPrefix(".") { continue }
                count += 1
            }
            return String(localized: "\(count) items", comment: "plural")
        }
        return await mediaReader(entry).dimensions
    }
}

extension IconCache {
    func icon(for entry: FileEntry, containerCopies: ContainerCopyStore = ContainerCopies.store, containerStore: ContainerStore) -> NSImage {
        // A container is a box, a Compose stack is a stack of boxes. Filled and green while it runs, an outline in
        // grey while it's stopped, orange while it's paused or only partly running.
        if entry.isDirectory, let (source, top) = containerCopies.copy(containing: entry.url),
           top.standardizedFileURL == entry.url.standardizedFileURL {
            let mark = ContainerIconMark.container(state: containerStore.container(id: source.id)?.state, busy: containerStore.busy[source.id] != nil)
            return markedIcon(mark.containerSymbol, mark)
        }
        if entry.isDirectory, containerCopies.isStack(entry.url) {
            let name = entry.url.lastPathComponent
            let members = containerStore.containers.filter {
                $0.compose?.project.compare(name, options: [.caseInsensitive]) == .orderedSame
            }
            let mark = ContainerIconMark.stack(states: members.map(\.state), anyBusy: members.contains { containerStore.busy[$0.id] != nil })
            return markedIcon(mark.stackSymbol, mark)
        }
        if !entry.isDirectory, !entry.isSymlink, let type = entry.contentType {
            return icon(forType: type)
        }
        return icon(forPath: entry.url.path, folder: entry.isDirectory, link: entry.isSymlink)
    }
}

extension ContainerIconMark {
    static func container(state: ContainerInfo.State?, busy: Bool) -> ContainerIconMark {
        if busy || state == .paused || state == .restarting { return .changing }
        return state == .running ? .running : .stopped
    }

    /// Green only when every container is running and none is being changed. Grey when nothing is running.
    static func stack(states: [ContainerInfo.State], anyBusy: Bool) -> ContainerIconMark {
        let running = states.filter { $0 == .running }.count
        if running == states.count && running > 0 && !anyBusy { return .running }
        if running == 0 && !anyBusy && !states.contains(where: { $0 == .paused || $0 == .restarting }) { return .stopped }
        return .changing
    }
}
