import AppKit

/// What a file collection view's keys, focus and drags go to: its controller.
protocol FileCollectionHost: AnyObject {
    func handleKey(_ key: FileViewKey) -> Bool
    func focusChanged()
    func endDrop()
}

/// Icons' and Gallery's collection view: the file views' keys go to their controller, and focus, or the window
/// becoming key or not, redraws the selection's emphasis. Files are dragged out of it and dropped onto it; a drag out
/// of a read-only or server copy offers only what `FileDrop.sourceMask` allows. Each adds its own moves
/// (`move(for:plain:extend:)`), clicks and menus.
class FileCollectionView: NSCollectionView {
    weak var host: (any FileCollectionHost)?
    let copies: CopyProviders
    private var windowObservers: [NSObjectProtocol] = []

    init(copies: CopyProviders) {
        self.copies = copies
        super.init(frame: .zero)
        registerForDraggedTypes(FileDrop.types)
        setDraggingSourceOperationMask(FileDrop.sourceOperations(local: true), forLocal: true)
        setDraggingSourceOperationMask(FileDrop.sourceOperations(local: false), forLocal: false)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        host?.endDrop()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        host?.endDrop()
    }

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        FileDrop.sourceMask(super.draggingSession(session, sourceOperationMaskFor: context), session, copies: copies)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isEmphasized: Bool {
        guard let window else { return false }
        return window.isKeyWindow && window.firstResponder === self
    }

    /// Moves the selection for an arrow (without ⌘ or ⌃), Home or End: true when `keyCode` was one this view moves by.
    func move(for keyCode: UInt16, plain: Bool, extend: Bool) -> Bool { false }

    override func keyDown(with event: NSEvent) {
        guard let host else { return super.keyDown(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if move(for: event.keyCode, plain: mods.isDisjoint(with: [.command, .control]), extend: mods.contains(.shift)) { return }
        if let key = FileViewKey.from(event) {
            if case .type = key {
                if host.handleKey(key) { return }
            } else {
                if !host.handleKey(key) { super.keyDown(with: event) }
                return
            }
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        host?.focusChanged()
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.host?.focusChanged() } }
        return result
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.host?.focusChanged() }
            })
        }
    }
}

/// Tells a file view's delegate its selection: once after a run of changes made together, and only when it differs
/// from what was told last; or at once, when a menu is about to be built for it.
final class SelectionReports {
    private var pending = false
    private var last: [URL] = []
    private let selection: () -> [URL]
    private let tell: ([URL]) -> Void

    init(selection: @escaping () -> [URL], tell: @escaping ([URL]) -> Void) {
        self.selection = selection
        self.tell = tell
    }

    func soon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = false
                let urls = self.selection()
                guard urls != self.last else { return }
                self.last = urls
                self.tell(urls)
            }
        }
    }

    func now() {
        last = selection()
        tell(last)
    }
}

/// Icons and Gallery: their items, found by URL, dragged out through their copy providers and dropped onto (a folder
/// springs open) or between, into the folder shown; and renaming one.
protocol FileItemCollection: FileCollectionController {
    var entries: [FileEntry] { get }
    var directory: URL? { get }
    var copies: CopyProviders { get }
    var springLoader: SpringLoader { get }
    var dropHighlight: DropHighlightView { get }
    func index(of url: URL) -> Int?
    func entryIndex(at path: IndexPath) -> Int?
    var backgroundDropPath: IndexPath { get }
}

extension FileItemCollection {
    func entryIndex(at path: IndexPath) -> Int? {
        guard path.count == 2, path.section == 0, entries.indices.contains(path.item) else { return nil }
        return path.item
    }

    var backgroundDropPath: IndexPath { IndexPath(item: entries.count, section: 0) }

    func pasteboardWriter(at indexPath: IndexPath) -> NSPasteboardWriting? {
        guard let index = entryIndex(at: indexPath) else { return nil }
        return ContainerDragItem.writer(for: entries[index].url, copies: copies)
    }

    func validateDrop(_ info: NSDraggingInfo, proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                      dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let urls = FileDrop.urls(info, copies: copies)
        let proposed = proposedIndexPath.pointee as IndexPath
        guard entryIndex(at: proposed) != nil || proposed == backgroundDropPath else { endDrop(); return [] }
        let folder = dropFolder(at: proposed, operation: dropOperation.pointee).flatMap {
            !urls.isEmpty && !FileDrop.isInside(urls, $0, during: info) ? $0 : nil
        }
        let springs = folder.map { fileDelegate?.fileView(self, canSpringLoad: $0, during: info) == true } == true
        springLoader.hover(springs ? folder : nil, drag: info.draggingSequenceNumber)
        guard !urls.isEmpty else { return hideDropHighlight() }
        if let folder {
            let operation = FileDrop.operation(urls, into: folder, info: info, copies: copies)
            if !operation.isEmpty {
                dropHighlight.isHidden = true
                return operation
            }
        }
        // Anywhere else drops into the folder being shown.
        guard directory != nil else { return hideDropHighlight() }
        proposedIndexPath.pointee = backgroundDropPath as NSIndexPath
        dropOperation.pointee = .before
        return dropIntoFolderShown(urls, info: info)
    }

    func dropIntoFolderShown(_ urls: [URL], info: NSDraggingInfo) -> NSDragOperation {
        guard !urls.isEmpty, let directory else { return hideDropHighlight() }
        let operation = FileDrop.operation(urls, into: directory, info: info, copies: copies)
        dropHighlight.isHidden = operation.isEmpty
        return operation
    }

    func acceptDrop(_ info: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        endDrop()
        let urls = FileDrop.urls(info, copies: copies)
        guard !urls.isEmpty, entryIndex(at: indexPath) != nil || (dropOperation == .before && indexPath == backgroundDropPath) else { return false }
        let folder = dropFolder(at: indexPath, operation: dropOperation)
        return fileDelegate?.fileView(self, drop: urls, onto: folder, info: info) ?? false
    }

    private func dropFolder(at path: IndexPath, operation: NSCollectionView.DropOperation) -> URL? {
        guard operation == .on, let index = entryIndex(at: path), entries[index].isFolder else { return nil }
        return entries[index].url
    }

    /// The drag left or ended: nothing highlighted, and no folder waiting to spring open.
    func endDrop() {
        dropHighlight.isHidden = true
        springLoader.cancel()
    }

    @discardableResult
    func hideDropHighlight() -> NSDragOperation {
        dropHighlight.isHidden = true
        return []
    }

    /// The keyboard's lead once the selection is `selection`: it stays while it's selected, else it's the last item
    /// selected, so arrows never start from an item that isn't.
    static func lead(_ lead: Int?, keptIn selection: Set<IndexPath>, index: (IndexPath) -> Int? = { $0.item }) -> Int? {
        guard let lead else { return nil }
        let indexes = selection.compactMap(index)
        return indexes.contains(lead) ? lead : indexes.max()
    }

    /// Where renaming `url` starts: any rename under way cancelled, and the item, selected.
    func prepareRename(_ url: URL) -> (index: Int, entry: FileEntry)? {
        cancelRename()
        guard let index = index(of: url) else { return nil }
        select([url], scroll: true)
        return (index, entries[index])
    }
}
