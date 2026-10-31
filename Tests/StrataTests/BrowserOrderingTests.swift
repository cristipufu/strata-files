import AppKit
import Testing
@testable import Strata

struct BrowserOrderingTests {
    private final class Environment {
        let state: TestTree
        let preferences: Prefs
        let services: BrowserServices
        init(reader: DirectoryReader = .live) throws {
            state = try TestTree()
            preferences = try Prefs.isolated()
            preferences.showIconPreviews = false
            services = BrowserServices.configured(
                transfers: TransferQueue(preferences: preferences, history: OperationLog(storage: SecureStorage.Context(directory: state.root, caches: state.url("Caches"), key: nil), copies: .live), copies: .live),
                visits: Frecency(preferences: preferences.defaults),
                windows: .headless,
                remote: .shared,
                containers: .shared,
                containerStore: .shared,
                clipboard: .shared,
                directories: reader)
        }
    }

    private func entry(_ path: String, size: Int64? = 0, label: String? = nil, folder: Bool = false,
                       package: Bool = false, modified: Date? = nil, created: Date? = nil,
                       added: Date? = nil, kind: String = "Document") -> FileEntry {
        let url = URL(fileURLWithPath: "/strata-order-fixture/" + path, isDirectory: folder)
        return FileEntry(url: url, name: url.lastPathComponent, isDirectory: folder, isPackage: package,
                         isHidden: false, isSymlink: false, isVolume: false, size: size, modified: modified,
                         created: created, added: added, kind: kind, contentType: nil, displayName: label)
    }

    @Test func delayedMetadataCannotReorderRankedResultsOrUnsortedGroups() throws {
        let environment = try Environment()
        let browser = BrowserViewController(services: environment.services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let small = entry("small.txt", size: 1), large = entry("large.txt", size: 100)
        browser.applySort(.size, ascending: false, remember: false)
        browser.showResults([small, large], total: 2)
        browser.select([small.url], scroll: false)
        #expect(browser.outlineView.sortDescriptors.isEmpty)
        // Call the same completion used by the debounce after switching to results, without waiting for a timer.
        browser.resortAfterMetadata()
        #expect(browser.topLevelEntries.map(\.url) == [small.url, large.url])
        #expect(browser.selectedURLs == [small.url])
        browser.showGroups([(title: "First", detail: "", entries: [small]),
                            (title: "Second", detail: "", entries: [large])], summary: "Two groups")
        browser.resortAfterMetadata()
        #expect(browser.allRows.map(\.groupTitle) == ["First", "Second"])
        withExtendedLifetime(environment) {}
    }
    private final class Metadata {
        var foldersFirst = false
        var sizes: [String: Int64] = [:]
        var batches: [URL: [String: Int64]] = [:]
        var media: [URL: MediaInfo] = [:]
        var tags: [URL: [String]] = [:]
        var tagReads: [URL] = []
        var sizeReads: [URL] = []
        var batchReads: [URL] = []
        var requests: [URL] = []
        func ordering(_ key: SortKey = .name, ascending: Bool = true) -> BrowserOrdering {
            BrowserOrdering(choice: .init(key: key, ascending: ascending), foldersFirst: { self.foldersFirst },
                metadata: .init(folderSize: { self.sizeReads.append($0); return self.sizes[$0.standardizedFileURL.path] },
                    childFolderSizes: { self.batchReads.append($0); return self.batches[$0] ?? [:] },
                    media: { self.media[$0.url] }, requestMedia: { self.requests.append($0.url) },
                    tags: { self.tagReads.append($0); return self.tags[$0] ?? [] }))
        }
    }

    @Test func everySortKeyUsesItsValueAndDirection() {
        for key in SortKey.allCases {
            let metadata = Metadata(), order = metadata.ordering(key)
            let a = entry(key == .fileExtension ? "z.2" : "z.txt", size: key == .size ? nil : 0,
                          label: key == .name ? "Item 2" : "Z", kind: key == .kind ? "Type 2" : "Document")
            let date = Date(timeIntervalSince1970: 500)
            let b = entry(key == .fileExtension ? "a.10" : "a.txt", size: key == .size ? 10 : 0,
                          label: key == .name ? "Item 10" : "A", modified: key == .modified ? date : nil,
                          created: key == .created ? date : nil, added: key == .added ? date : nil,
                          kind: key == .kind ? "Type 10" : "Document")
            switch key {
            case .tags:
                metadata.tags[a.url] = ["Tag 2"]
                metadata.tags[b.url] = ["Tag 10"]
            case .dimensions:
                metadata.media[a.url] = MediaInfo(width: 25, height: 6)
                metadata.media[b.url] = MediaInfo(width: 9, height: 100)
            case .width:
                metadata.media[a.url] = MediaInfo(width: 9)
                metadata.media[b.url] = MediaInfo(width: 25)
            case .height:
                metadata.media[a.url] = MediaInfo(height: 6)
                metadata.media[b.url] = MediaInfo(height: 100)
            case .duration:
                metadata.media[a.url] = MediaInfo(duration: 5)
                metadata.media[b.url] = MediaInfo(duration: 10)
            default: break
            }
            #expect(order.ordered(a, b) && !order.ordered(b, a))
            var nodes = [FileNode(entry: b), FileNode(entry: a)]
            order.sort(&nodes)
            #expect(nodes.map(\.url) == [a.url, b.url])
            order.choose(.init(key: key, ascending: false))
            #expect(order.ordered(b, a) && !order.ordered(a, b))
            order.sort(&nodes)
            #expect(nodes.map(\.url) == [b.url, a.url])
            #expect(metadata.requests.isEmpty == !key.isMedia)
            #expect(metadata.sizeReads.isEmpty && metadata.batchReads.isEmpty)
        }
    }


    @Test func tagSortUsesEveryNameAndCachesEachItemOncePerPass() {
        let metadata = Metadata(), order = metadata.ordering(.tags)
        let a = entry("z"), b = entry("a"), c = entry("b"), empty = entry("empty")
        metadata.tags[a.url] = ["Zebra", "Alpha"]
        metadata.tags[b.url] = ["Beta", "Alpha"]
        metadata.tags[c.url] = ["Alpha"]
        var nodes = [a, b, c, empty].map { FileNode(entry: $0) }
        order.sort(&nodes)
        #expect(nodes.map(\.url) == [empty.url, c.url, b.url, a.url])
        #expect(Set(metadata.tagReads) == Set(nodes.map(\.url)))
        #expect(metadata.tagReads.count == nodes.count)
        metadata.tags[a.url] = ["Aardvark"]
        metadata.tagReads = []
        order.sort(&nodes)
        #expect(nodes.map(\.url) == [empty.url, a.url, c.url, b.url])
        #expect(metadata.tagReads.count == nodes.count)
        #expect(metadata.requests.isEmpty && metadata.sizeReads.isEmpty && metadata.batchReads.isEmpty)
    }

    @Test func equalValuesKeepAscendingNameAndPathTiesInBothDirections() {
        for key in SortKey.allCases {
            let metadata = Metadata()
            let a = entry("one/a.txt", label: "Alpha"), b = entry("one/b.txt", label: "Beta")
            let same = entry("two/a.txt", label: "Alpha")
            for ascending in [false, true] {
                let order = metadata.ordering(key, ascending: ascending)
                if key != .name { #expect(order.ordered(a, b) && !order.ordered(b, a)) }
                #expect(order.ordered(a, same) && !order.ordered(same, a))
                #expect(!order.ordered(a, a))
            }
        }
    }

    @Test func foldersFirstDoesNotReverseOrTreatPackagesAsNavigableFolders() {
        let metadata = Metadata(), order = metadata.ordering(.name, ascending: false)
        metadata.foldersFirst = true
        let folder = entry("A folder", folder: true), package = entry("Z.app", folder: true, package: true)
        let file = entry("M file")
        var nodes = [FileNode(entry: package), FileNode(entry: file), FileNode(entry: folder)]
        order.sort(&nodes)
        #expect(nodes.map(\.url) == [folder.url, package.url, file.url])
        metadata.foldersFirst = false
        order.sort(&nodes)
        #expect(nodes.map(\.url) == [package.url, file.url, folder.url])
    }

    @Test func missingMediaAndZeroSizedFilesRetainTheirExistingSentinels() {
        let metadata = Metadata()
        let missing = entry("missing", size: nil), empty = entry("empty", size: 0), known = entry("known", size: 1)
        metadata.media[empty.url] = MediaInfo()
        metadata.media[known.url] = MediaInfo(width: 2, height: 3, duration: 0)
        for key in [SortKey.dimensions, .width, .height, .duration] {
            let order = metadata.ordering(key)
            #expect(order.ordered(missing, known))
            #expect(key == .dimensions ? order.ordered(missing, empty) : order.ordered(empty, missing))
            order.choose(.init(key: key, ascending: false))
            #expect(order.ordered(known, missing))
        }
        let order = metadata.ordering(.size, ascending: false)
        #expect(order.ordered(empty, missing)) // Both zero: ascending label tie, even in a descending sort.
        #expect(order.ordered(known, empty))
    }

    @Test func aSizePassBatchesEachParentAndMemoizesMissingTotalsWithoutRetainingThem() throws {
        let metadata = Metadata(), order = metadata.ordering(.size, ascending: false)
        let parent = FileNode(entry: entry("folder", folder: true))
        let a = FileNode(entry: entry("folder/a", folder: true)), b = FileNode(entry: entry("folder/b", folder: true))
        let unknown = FileNode(entry: entry("folder/c", folder: true)), other = FileNode(entry: entry("other", folder: true))
        parent.children = [unknown, b, a]
        let file = FileNode(entry: entry("file", size: 50)), root = parent.url.deletingLastPathComponent()
        metadata.batches[root] = [parent.url.standardizedFileURL.path: 10]
        metadata.batches[parent.url] = [a.url.standardizedFileURL.path: 30]
        metadata.sizes[b.url.standardizedFileURL.path] = 20
        var nodes = [other, parent, file]
        order.sort(&nodes)
        #expect(nodes.map(\.url) == [file.url, parent.url, other.url])
        #expect(parent.children?.map(\.url) == [a.url, b.url, unknown.url])
        #expect(Set(metadata.batchReads) == [root, parent.url] && metadata.batchReads.count == 2)
        #expect(Set(metadata.sizeReads) == [b.url, unknown.url, other.url] && metadata.sizeReads.count == 3)
        metadata.batches[root] = [parent.url.standardizedFileURL.path: 70]
        metadata.sizes[b.url.standardizedFileURL.path] = 60
        metadata.sizes[unknown.url.standardizedFileURL.path] = 40
        metadata.batchReads = []; metadata.sizeReads = []
        order.sort(&nodes)
        #expect(nodes.map(\.url) == [parent.url, file.url, other.url])
        #expect(parent.children?.map(\.url) == [b.url, unknown.url, a.url])
        #expect(nodes.first === parent && parent.children?.first === b)
        #expect(metadata.batchReads.count == 2 && metadata.sizeReads.count == 3)
    }

    @Test func mediaRequestsIncludeLoadedDescendantsButOtherOrdersDoNotLoadMetadata() {
        let metadata = Metadata(), order = metadata.ordering(.width)
        let parent = FileNode(entry: entry("folder", folder: true)), child = FileNode(entry: entry("folder/photo.jpg"))
        parent.children = [child]
        var nodes = [parent]
        order.sort(&nodes)
        #expect(metadata.requests == [parent.url, child.url])
        metadata.requests = []
        for key in [SortKey.name, .modified, .created, .added, .kind, .fileExtension] {
            order.choose(.init(key: key, ascending: true))
            order.sort(&nodes)
        }
        #expect(metadata.requests.isEmpty && metadata.sizeReads.isEmpty && metadata.batchReads.isEmpty)
    }

    @Test func resultOrderBelongsToOneResultSessionAndRestoresTheFolderChoice() {
        let metadata = Metadata(), order = metadata.ordering(.size, ascending: false)
        let initial = BrowserOrdering.Choice(key: .size, ascending: false)
        var nodes = [FileNode(entry: entry("small", size: 1)), FileNode(entry: entry("large", size: 10))]
        order.enterResults()
        #expect(order.isShowingResults && order.choice == nil)
        order.sort(&nodes)
        #expect(nodes.map(\.entry.name) == ["small", "large"])
        order.choose(.init(key: .name, ascending: true))
        order.enterResults()
        #expect(order.choice == .init(key: .name, ascending: true))
        order.sort(&nodes)
        #expect(nodes.map(\.entry.name) == ["large", "small"])
        #expect(order.leaveResults() == initial)
        #expect(!order.isShowingResults && order.choice == initial)
        order.enterResults()
        #expect(order.choice == nil)
        order.leaveResults()
        order.choose(.init(key: .modified, ascending: true), remember: false)
        order.enterResults()
        #expect(order.leaveResults() == nil)
        #expect(order.choice == .init(key: .modified, ascending: true))
    }

    @Test func nativeHeadersSelectionsAndSavedChoicesFollowResultAndFolderTransitions() async throws {
        let tree = try TestTree("a", "z")
        let entries = [entry("a", size: 1), entry("z", size: 10)]
        let environment = try Environment(reader: DirectoryReader { _, _, _ in entries })
        for remember in [false, true] {
            environment.preferences.sortColumn = "name"; environment.preferences.sortAscending = true
            let browser = BrowserViewController(services: environment.services)
            browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
            browser.load(tree.root)
            await browser.directoryReads.task?.value
            browser.applySort(.size, ascending: false, remember: remember)
            #expect(browser.outlineView.sortDescriptors.first?.key == "size")
            #expect(browser.outlineView.sortDescriptors.first?.ascending == false)
            #expect(environment.preferences.sortColumn == (remember ? "size" : "name"))
            browser.showResults(entries, total: 2)
            browser.select([entries[0].url], scroll: false)
            browser.outlineView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
            #expect(browser.topLevelEntries.map(\.url) == entries.map(\.url))
            #expect(browser.selectedURLs == [entries[0].url])
            browser.load(tree.root)
            await browser.directoryReads.task?.value
            #expect(browser.outlineView.sortDescriptors.first?.key == "size")
            #expect(browser.outlineView.sortDescriptors.first?.ascending == false)
            #expect(browser.topLevelEntries.map(\.url) == entries.reversed().map(\.url))
            #expect(environment.preferences.sortColumn == (remember ? "size" : "name"))
            #expect(environment.preferences.sortAscending == !remember)
        }
        #expect(tree.snapshot() == ["a", "z"])
        withExtendedLifetime(environment) {}
    }

    @Test func metadataResortUpdatesNativeDescendantRowsAndKeepsSelection() throws {
        let environment = try Environment(), browser = BrowserViewController(services: environment.services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let a = entry("a", size: 1), z = entry("z", size: 10)
        browser.showGroups([(title: "Group", detail: "", entries: [a, z])], summary: "Group")
        browser.outlineView.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        let parent = try #require(browser.allRows.first)
        browser.outlineView.expandItem(parent)
        browser.select([z.url], scroll: false)
        let child = try #require(parent.children?.first { $0.url == a.url })
        child.entry = entry("a", size: 20)
        browser.resortAfterMetadata()
        #expect(parent.children?.map(\.url) == [a.url, z.url])
        #expect((browser.outlineView.item(atRow: 1) as? FileNode)?.url == a.url)
        #expect((browser.outlineView.item(atRow: 2) as? FileNode)?.url == z.url)
        #expect(browser.selectedURLs == [z.url])
        #expect(browser.outlineView.isItemExpanded(parent))
        withExtendedLifetime(environment) {}
    }

    @Test func metadataResortWaitsForTheNativeInlineEditorToFinish() throws {
        _ = NSApplication.shared
        let tree = try TestTree("a", "z"), environment = try Environment()
        let browser = BrowserViewController(services: environment.services)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = browser
        defer { window.contentViewController = nil }
        let a = try #require(FileEntry(url: tree.url("a"))), z = try #require(FileEntry(url: tree.url("z")))
        browser.showGroups([(title: "Group", detail: "", entries: [a, z])], summary: "Group")
        browser.outlineView.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        let parent = try #require(browser.allRows.first)
        browser.outlineView.expandItem(parent)
        browser.select([a.url], scroll: false)
        browser.renameSelection(nil)
        let row = browser.outlineView.selectedRow
        let column = browser.outlineView.column(withIdentifier: .init("name"))
        let cell = try #require(browser.outlineView.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)
        let field = try #require(cell.textField), editor = try #require(field.currentEditor())
        let changed = try #require(parent.children?.first { $0.url == z.url })
        changed.entry = FileEntry(url: z.url, name: z.name, isDirectory: false, isPackage: false, isHidden: false,
                                 isSymlink: false, isVolume: false, size: 20, modified: z.modified, created: z.created,
                                 added: z.added, kind: z.kind, contentType: z.contentType)
        browser.resortAfterMetadata()
        #expect(field.currentEditor() === editor)
        #expect(parent.children?.map(\.url) == [a.url, z.url])
        window.makeFirstResponder(browser.outlineView)
        #expect(parent.children?.map(\.url) == [z.url, a.url])
        #expect(browser.selectedURLs == [a.url])
        #expect(!window.isVisible && tree.snapshot() == ["a", "z"])
        withExtendedLifetime(environment) {}
    }


    /// A folder's entries are sorted away from the main thread as they're read, in exactly the order the list sorts
    /// them in; an order by sizes, tags or media, known only on the main thread, stays there.
    @Test func entriesSortedAsTheyreReadTakeTheListsOrder() async throws {
        let day = { (n: Double) in Date(timeIntervalSince1970: n * 86_400) }
        let entries = [
            entry("Item 10.txt", modified: day(3), created: day(1), added: day(2), kind: "Text"),
            entry("item 2.md", modified: day(1), created: day(3), added: day(1), kind: "Markdown"),
            entry("Folder", folder: true, modified: day(2), created: day(2), added: day(3), kind: "Folder"),
            entry("b.zip", modified: day(2), created: day(2), added: day(2), kind: "Archive"),
            entry("a.zip", modified: day(2), created: day(2), added: day(2), kind: "Archive"),
        ]
        for key in [SortKey.name, .modified, .created, .added, .kind, .fileExtension] {
            for ascending in [true, false] {
                for foldersFirst in [true, false] {
                    let metadata = Metadata()
                    metadata.foldersFirst = foldersFirst
                    let ordering = metadata.ordering(key, ascending: ascending)
                    var nodes = entries.map { FileNode(entry: $0) }
                    ordering.sort(&nodes)
                    let snapshot = try #require(ordering.snapshot)
                    let sorted = await BrowserOrdering.sorted(entries, by: snapshot)
                    #expect(sorted.map(\.url) == nodes.map(\.url), "\(key) \(ascending) \(foldersFirst)")
                }
            }
        }
        for key in [SortKey.size, .tags, .dimensions, .width, .height, .duration] {
            #expect(Metadata().ordering(key).snapshot == nil, "\(key)")
        }
    }

    /// Entries read in the order chosen are shown as they come; read in an order since changed, they're sorted again.
    @Test func aFolderReadInAnOrderSinceChangedIsSortedAgain() throws {
        let environment = try Environment()
        let browser = BrowserViewController(services: environment.services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let entries = ["c.txt", "a.txt", "b.txt"].map { entry($0) }
        browser.ordering.choose(.init(key: .name, ascending: true), remember: false)
        let current = try #require(browser.ordering.snapshot)
        browser.apply(entries, preservingState: false, sortedBy: current)
        #expect(browser.rows.map(\.entry.name) == ["c.txt", "a.txt", "b.txt"])
        let earlier = BrowserOrdering.Snapshot(choice: .init(key: .name, ascending: false), foldersFirst: current.foldersFirst)
        browser.apply(entries, preservingState: false, sortedBy: earlier)
        #expect(browser.rows.map(\.entry.name) == ["a.txt", "b.txt", "c.txt"])
        browser.apply(entries, preservingState: false)
        #expect(browser.rows.map(\.entry.name) == ["a.txt", "b.txt", "c.txt"])
    }
}
