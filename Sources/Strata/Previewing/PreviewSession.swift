import Foundation
import StrataPreviews

/// Owns reads for one Space preview. Its tree is independent of the browser, so exploring it never navigates a pane.
@MainActor final class PreviewSession {
    typealias ArchiveReader = @Sendable (URL, ArchiveKind) async throws -> ArchiveListing

    enum Change {
        case root
        case children(PreviewItem)
        case selection
        case content
    }

    private let reader: DirectoryReader
    private let isPlaceholder: @Sendable (URL) -> Bool
    private let archiveReader: ArchiveReader?
    let archiveAccess: PreviewArchiveAccess
    private let rootRead: DirectoryReadSession
    private var childReads: [ObjectIdentifier: DirectoryReadSession] = [:]
    private var items: Set<ObjectIdentifier> = []
    private var archiveTask: Task<Void, Never>?
    private var revision = 0
    private var showHidden = false
    private var applications = ApplicationsFolders.standard

    private(set) var root: FileEntry?
    private(set) var rootIdentity: FileIdentity?
    private(set) var roots: [PreviewItem] = []
    private(set) var selected: PreviewItem?
    private(set) var archive: ArchiveListing?
    private(set) var isLoading = false
    private(set) var isClosed = true
    private(set) var error: Error?
    var onChange: ((Change) -> Void)?

    var task: Task<Void, Never>? { archiveTask ?? rootRead.task }
    var generation: Int { revision }
    var isContainer: Bool {
        guard let root, !root.isSymlink else { return false }
        return root.isFolder || (!root.isDirectory && ArchiveKind(fileName: root.name) != nil)
    }

    init(reader: DirectoryReader, archiveReader: ArchiveReader? = nil, archiveAccess: PreviewArchiveAccess = PreviewArchiveAccess(),
         isPlaceholder: @escaping @Sendable (URL) -> Bool = { _ in false }) {
        let reader = reader.forPreview
        self.isPlaceholder = isPlaceholder
        self.reader = reader
        self.archiveReader = archiveReader
        self.archiveAccess = archiveAccess
        rootRead = DirectoryReadSession(reader: reader)
    }

    isolated deinit { close() }

    func show(_ entry: FileEntry, showHidden: Bool, applications: ApplicationsFolders) {
        close()
        isClosed = false
        root = entry
        rootIdentity = FileIdentity.read(entry.url.path)
        self.showHidden = showHidden
        self.applications = applications
        error = nil
        let revision = revision
        if entry.isFolder && !entry.isSymlink {
            isLoading = true
            rootRead.load(entry.url, showHidden: showHidden, applications: applications) { [weak self] result, _ in
                guard let self, !isClosed, self.revision == revision else { return }
                isLoading = false
                do { roots = try makeItems(result.get(), in: entry.url) }
                catch { self.error = error }
                onChange?(.root)
            }
        } else if !entry.isDirectory, !entry.isSymlink, !isPlaceholder(entry.url), let kind = ArchiveKind(fileName: entry.name) {
            isLoading = true
            let read = archiveReader
            let access = archiveAccess
            do { access.reset(try PreviewArchiveSource(entry.url)) }
            catch { self.error = error; isLoading = false; onChange?(.root); return }
            archiveTask = Task { [weak self] in
                let result: Result<ArchiveListing, Error>
                do {
                    try Task.checkCancellation()
                    if let read { result = .success(try await read(entry.url, kind)) }
                    else {
                        let listed = PreviewArchiveListing(records: try await access.read(), end: .complete)
                        result = .success(try ArchiveLister.tree(listed, compressed: nil, named: entry.url.lastPathComponent))
                    }
                } catch { result = .failure(error) }
                guard let self, !isClosed, self.revision == revision, !Task.isCancelled else { return }
                archiveTask = nil
                isLoading = false
                switch result {
                case .success(let listing):
                    archive = listing
                    roots = listing.root.value.children.map { PreviewItem(.member($0, path: [$0.name])) }
                    register(roots)
                case .failure(let error): if !(error is CancellationError) { self.error = error }
                }
                onChange?(.root)
            }
        }
        onChange?(.root)
    }

    func close() {
        revision += 1
        isClosed = true
        rootRead.invalidate()
        childReads.values.forEach { $0.invalidate() }
        childReads = [:]
        archiveAccess.reset()
        archiveTask?.cancel()
        archiveTask = nil
        roots = []
        items = []
        selected = nil
        archive = nil
        root = nil
        rootIdentity = nil
        error = nil
        isLoading = false
    }

    func fetched(_ entry: FileEntry) {
        guard !isClosed else { return }
        if selected == nil, root?.url.path.utf8.elementsEqual(entry.url.path.utf8) == true {
            show(entry, showHidden: showHidden, applications: applications)
        } else if let selected, selected.entry?.url.path.utf8.elementsEqual(entry.url.path.utf8) == true {
            selected.fetched(entry)
            onChange?(.content)
        }
    }

    func cancelLoading() {
        let wasLoading = isLoading
        archiveTask?.cancel()
        archiveTask = nil
        rootRead.invalidate()
        archiveAccess.cancelPassword?()
        isLoading = false
        if wasLoading { onChange?(.root) }
    }

    func select(_ item: PreviewItem?) {
        guard !isClosed, item.map({ items.contains(ObjectIdentifier($0)) }) ?? true else { return }
        guard selected !== item else { return }
        selected = item
        onChange?(.selection)
    }

    @discardableResult
    func expand(_ item: PreviewItem) -> Task<Void, Never>? {
        let key = ObjectIdentifier(item)
        guard !isClosed, items.contains(key), item.isDirectory, item.children == nil else { return nil }
        if let children = item.archiveChildren() {
            item.children = children
            register(children)
            return nil
        }
        guard let entry = item.entry, childReads[key] == nil else { return childReads[key]?.task }
        let read = DirectoryReadSession(reader: reader)
        childReads[key] = read
        let revision = revision
        return read.load(entry.url, showHidden: showHidden, applications: applications) { [weak self, weak item, weak read] result, _ in
            guard let self, let item, let read, !isClosed, self.revision == revision, childReads[key] === read else { return }
            childReads[key] = nil
            do { item.children = try makeItems(result.get(), in: entry.url, parent: item) }
            catch { self.error = error }
            onChange?(.children(item))
        }
    }

    func collapse(_ item: PreviewItem) {
        let key = ObjectIdentifier(item)
        childReads.removeValue(forKey: key)?.invalidate()
    }

    /// Reject a malformed provider batch before adding any rows. Only immediate children belong to this folder.
    private func makeItems(_ entries: [FileEntry], in folder: URL, parent: PreviewItem? = nil) throws -> [PreviewItem] {
        guard entries.count <= DirectoryReader.previewLimit - items.count else { throw CocoaError(.fileReadTooLarge) }
        let bases = Set(applications.directories(for: folder).map { $0.standardizedFileURL.path })
        var seen: Set<String> = []
        for entry in entries {
            let url = entry.url.standardizedFileURL
            guard url.isFileURL, bases.contains(url.deletingLastPathComponent().path),
                  !entry.name.isEmpty, entry.name != ".", entry.name != "..", !entry.name.contains("/"),
                  !entry.name.utf8.contains(0), entry.name.utf8.elementsEqual(entry.url.lastPathComponent.utf8),
                  seen.insert(url.path).inserted else { throw CocoaError(.fileReadCorruptFile) }
        }
        let result = entries.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }.map { PreviewItem(.file($0), parent: parent) }
        register(result)
        return result
    }

    private func register(_ nodes: [PreviewItem]) {
        items.formUnion(nodes.map(ObjectIdentifier.init))
    }
}
