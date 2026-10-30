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
        /// The root's items have their places in the OneNote notebook they hold.
        case order
    }

    private let reader: DirectoryReader
    private let isPlaceholder: @Sendable (URL) -> Bool
    private let archiveReader: ArchiveReader?
    let archiveAccess: PreviewArchiveAccess
    private let rootRead: DirectoryReadSession
    private var childReads: [ObjectIdentifier: DirectoryReadSession] = [:]
    private var items: Set<ObjectIdentifier> = []
    private var archiveTask: Task<Void, Never>?
    private(set) var notebookTask: Task<Void, Never>?
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
                do {
                    let entries = try result.get()
                    roots = try makeItems(entries, in: entry.url)
                    if OneNoteContents.pick(entries.map(\.name)) != nil {
                        order { [isPlaceholder] in
                            try await Self.notebook(among: entries, isPlaceholder: isPlaceholder)
                        }
                    }
                } catch { self.error = error }
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
                    let files = listing.root.value.children.filter { !$0.isDirectory }
                        .map { (name: $0.name, size: $0.size) }
                    order { [source = access.source] in
                        guard let source else { return nil }
                        return try await Self.notebook(in: files, source: source)
                    }
                case .failure(let error): if !(error is CancellationError) { self.error = error }
                }
                onChange?(.root)
            }
        }
        onChange?(.root)
    }

    /// Once the root's items show, gives them their places in the OneNote notebook they hold, from the table of
    /// contents `read` finds among them. Until then, and without one, they keep their own order.
    private func order(_ read: @escaping @MainActor () async throws -> OneNoteContents?) {
        let revision = revision, items = roots
        notebookTask?.cancel()
        notebookTask = Task { [weak self] in
            let contents = try? await read()
            guard let self, !isClosed, self.revision == revision, !Task.isCancelled else { return }
            notebookTask = nil
            guard let contents else { return }
            let names = items.map { $0.entry?.name ?? $0.name }
            for (item, position) in zip(items, contents.positions(of: names)) { item.notebookPosition = position }
            onChange?(.order)
        }
    }

    /// An archive's, as OneNote exports a notebook: copied out no larger than one may be, by the size the worker sends
    /// before its contents, and without asking for a password, so an archive that needs one keeps its order.
    @concurrent private static func notebook(in files: [(name: String, size: Int64)], source: PreviewArchiveSource)
        async throws -> OneNoteContents? {
        guard let index = OneNoteContents.pick(files.map(\.name)), files[index].size <= OneNoteContents.byteLimit else {
            return nil
        }
        let copied = Copied()
        try await PreviewArchiveReader.stream(source, member: [files[index].name], password: nil) { size in
            guard size <= OneNoteContents.byteLimit else { throw OneStoreError.tooLarge }
            return { copied.data.append(contentsOf: $0) }
        }
        return try await OneNoteContents.read(copied.data)
    }

    /// What a copy of one file out of an archive brings, gathered on the thread reading it and read once it's done.
    nonisolated private final class Copied: @unchecked Sendable {
        var data = Data()
    }

    /// A notebook folder's, once it's here: a copy of a server's or a container's may not be fetched yet.
    @concurrent private static func notebook(among entries: [FileEntry], isPlaceholder: @Sendable (URL) -> Bool)
        async throws -> OneNoteContents? {
        let files = entries.filter { !$0.isDirectory }
        guard let index = OneNoteContents.pick(files.map(\.name)),
              (files[index].size ?? .max) <= OneNoteContents.byteLimit,
              !isPlaceholder(files[index].url) else { return nil }
        return try await OneNoteContents.open(PreviewArchiveSource(files[index].url))
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
        notebookTask?.cancel()
        notebookTask = nil
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
        // A notebook folder's table of contents, fetched since the folder showed, gives it its order now.
        let path = entry.url.path.utf8
        guard !entry.isDirectory, (entry.name as NSString).pathExtension.lowercased() == OneNoteContents.fileExtension,
              roots.contains(where: { $0.entry?.url.path.utf8.elementsEqual(path) == true }) else { return }
        let entries = roots.compactMap(\.entry).map { $0.url.path.utf8.elementsEqual(path) ? entry : $0 }
        order { [isPlaceholder] in try await Self.notebook(among: entries, isPlaceholder: isPlaceholder) }
    }

    func cancelLoading() {
        let wasLoading = isLoading
        archiveTask?.cancel()
        archiveTask = nil
        notebookTask?.cancel()
        notebookTask = nil
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
