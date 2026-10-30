import AppKit
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// A container's item dragged within Strata: its path in the copy (other apps get a file promise).
    nonisolated static let strataContainerItem = NSPasteboard.PasteboardType("dev.strata.container-item")
}

/// What dragging an item of a container's files puts on the pasteboard: a file promise, so the app it's dropped on
/// waits while Strata fetches all of it (a folder with everything in it), never a half-read copy. Strata's own views
/// read the item's path instead and copy it like any other file.
nonisolated final class ContainerDragItem: NSFilePromiseProvider {
    let source: URL
    let copies: CopyProviders

    init(source: URL, copies: CopyProviders) {
        self.source = source
        self.copies = copies
        super.init()
        let rawType = (try? source.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? .data
        let type = (rawType.conforms(to: .data) || rawType.conforms(to: .directory)) ? rawType : .data
        fileType = type.identifier
        delegate = ContainerPromises.shared
    }

    /// An item of a container's files gets a promise; anything else drags as itself.
    @MainActor
    static func writer(for url: URL, copies: CopyProviders) -> NSPasteboardWriting {
        copies.contains(url) ? ContainerDragItem(source: url, copies: copies) : url as NSURL
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.strataContainerItem]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .strataContainerItem ? source.path : super.pasteboardPropertyList(forType: type)
    }
}

/// Keeps file promises: fetches the item from its container, then copies it where it was dropped.
nonisolated final class ContainerPromises: NSObject, NSFilePromiseProviderDelegate, Sendable {
    static let shared = ContainerPromises()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider as? ContainerDragItem)?.source.lastPathComponent ?? "Item"
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let item = provider as? ContainerDragItem else { return completionHandler(CocoaError(.fileNoSuchFile)) }
        let source = item.source
        let copies = item.copies
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        Task {
            do {
                try await copies.prepareForCopying([source])
                guard !copies.containsPlaceholder(in: [source]) else { throw CocoaError(.fileReadUnknown) }
                // Dragged out, the copy belongs to the receiving app: Strata keeps no History of it.
                let result = await TransferWorker(label: "dev.strata.file-promise").run {
                    Result { _ = try TransferEngine.copyForExport(source, to: url) }
                }
                try result.get()
            } catch {
                failure = error
            }
            done.signal()
        }
        done.wait()
        completionHandler(failure)
    }
}

extension FileDrop {
    /// Items of containers' files dragged within Strata (see `ContainerDragItem`).
    static func containerItems(_ pasteboard: NSPasteboard, copies: CopyProviders) -> [URL] {
        (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .strataContainerItem) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }.filter { copies.contains($0) }
    }
}
