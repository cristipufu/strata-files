import AppKit
import Synchronization
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch
@testable import StrataPreviews

/// A notebook's table of contents (.onetoc2): read for the order of its sections, in a package Space shows and in a
/// preview of its own.
@Suite(.archiveWorkerApp)
struct OneNoteContentsTests {
    private static let entries: [(name: String, color: UInt32?)] = [
        ("Zebra.one", 0x0011_2233), ("Apple.one", nil), ("Group", nil), ("OneNote_RecycleBin", nil),
    ]

    /// A tar holding `files`, each name with its bytes.
    private func tar(_ files: [(String, Data)]) -> Data {
        Data(files.flatMap { ContainerTests.tarFile($0.0, Array($0.1)) } + [UInt8](repeating: 0, count: 1024))
    }

    /// A table of contents of one section saved twice: the second revision depends on the first, copies its table and
    /// gives its list new data; `change` makes it otherwise.
    private func savedTwice(_ change: (inout OneStoreFixture.Revision) -> Void = { _ in }) -> Data {
        typealias ID = OneStoreFixture.ID
        var store = OneStoreFixture()
        store.type = OneStoreFixture.contentsType
        store.oldestReader = 0x1B
        let root = ID(number: 2), section = ID(number: 100)
        func list() -> OneStoreFixture.Object {
            OneStoreFixture.Object(id: root, jcid: 0x0002_0001, content: .properties([(0x1CF6, .objects([section]))]))
        }
        let named = OneStoreFixture.Object(id: section, jcid: 0x0002_0001,
                                           content: .properties([(UInt32(0x1D6B), OneStoreFixture.text("A.one"))]))
        let first = OneStoreFixture.Revision(id: ID(number: 3), objects: [list(), named], roots: [(1, root)])
        var again = OneStoreFixture.Revision(id: ID(number: 4), objects: [list()], roots: [(1, root)])
        again.dependency = first.id
        again.copiesTable = true
        again.revised = [root]
        change(&again)
        store.spaces = [OneStoreFixture.Space(id: ID(number: 1), revisions: [first, again])]
        store.root = ID(number: 1)
        return store.data()
    }

    @Test func aTableOfContentsListsItsSectionsInOneNotesOrderWithTheirColors() async throws {
        let tree = try TestTree("Notebook/", "outside")
        let data = OneNoteFixture.contents(Self.entries)
        try data.write(to: tree.url("Notebook/Open Notebook.onetoc2"))
        let read = try await OneNoteContents.read(data)
        // The recycle bin OneNote lists is left out.
        #expect(read.entries == [.init(name: "Zebra.one", color: 0x0011_2233), .init(name: "Apple.one", color: nil),
                                 .init(name: "Group", color: nil)])
        #expect(read.entries.map(\.isSection) == [true, true, false])
        #expect(read.positions(of: ["Apple.one", "Other.one", "Zebra.one", "Group"]) == [1, nil, 0, 2])
        // Of a folder's files, OneNote's own table of contents, or else the first by name.
        #expect(OneNoteContents.pick(["b.onetoc2", "Open Notebook (old).onetoc2", "a.ONETOC2", "Open Notebook.onetoc2",
                                      "c.one"]) == 3)
        #expect(OneNoteContents.pick(["b.onetoc2", "c.one", "a.ONETOC2"]) == 2)
        #expect(OneNoteContents.pick(["c.one", "notes.onetoc"]) == nil)
        // A name matches however its accents are composed and its letters capitalized.
        let accented = try await OneNoteContents.read(OneNoteFixture.contents([("Caf\u{E9}.one", nil)]))
        #expect(accented.positions(of: ["CAFE\u{301}.ONE"]) == [0])
        let source = try PreviewArchiveSource(tree.url("Notebook/Open Notebook.onetoc2"))
        #expect(try await OneNoteContents.open(source).entries == read.entries)
        // A file larger than one read out of a package is refused whatever it holds.
        try (data + Data(count: OneNoteContents.byteLimit)).write(to: tree.url("Notebook/Large.onetoc2"))
        await #expect(throws: OneStoreError.tooLarge) {
            try await OneNoteContents.open(PreviewArchiveSource(tree.url("Notebook/Large.onetoc2")))
        }
        #expect(tree.text("outside") == "outside")
    }

    @Test func onlyATableOfContentsReadsAsOneAndOnlyAsOneOfItsVersion() async throws {
        let tree = try TestTree("folder/", "outside")
        var section = OneNoteFixture()
        let page = section.page("Page")
        let sectionData = section.section([[page]])
        await #expect(throws: OneStoreError.notOneNote) { try await OneNoteContents.read(sectionData) }
        // Nor does a section's preview take one: it goes to Quick Look.
        try OneNoteFixture.contents(Self.entries).write(to: tree.url("folder/Notes.one"))
        await #expect(throws: PreviewError.self) {
            try await OneNoteSectionFile.open(PreviewArchiveSource(tree.url("folder/Notes.one")))
        }
        // A table of contents that says OneNote 2010's sections' version, not its own.
        var older = OneNoteFixture.contents(Self.entries)
        older[76] = 0x2A
        await #expect(throws: OneStoreError.unsupportedVersion) { try await OneNoteContents.read(older) }
        await #expect(throws: OneStoreError.malformed) {
            try await OneNoteContents.read(OneNoteFixture.contents(Self.entries, missing: true))
        }
        // Its objects' data is stored plainly, as it must be.
        await #expect(throws: OneStoreError.malformed) {
            try await OneNoteContents.read(OneNoteFixture.contents(Self.entries, encoding: 1))
        }
        // Cut short, whatever it says runs past its end.
        let whole = OneNoteFixture.contents(Self.entries)
        await #expect(throws: OneStoreError.malformed) { try await OneNoteContents.read(whole.prefix(whole.count - 64)) }
        // As large as one may be, it's read; a byte more, it's not.
        await #expect(throws: OneStoreError.notOneNote) {
            try await OneNoteContents.read(Data(count: OneNoteContents.byteLimit))
        }
        await #expect(throws: OneStoreError.tooLarge) {
            try await OneNoteContents.read(Data(count: OneNoteContents.byteLimit + 1))
        }
        #expect(tree.text("outside") == "outside")
    }

    @Test func aTableOfContentsSavedAgainCopiesWhatItKeepsFromBefore() async throws {
        let first: [(name: String, color: UInt32?)] = [("Zebra.one", 0x0011_2233), ("Apple.one", nil)]
        // Its list given new data in a revision that copies the table it names them by.
        let data = OneNoteFixture.contents(first, revised: ["Apple.one", "Zebra.one", "Group"])
        #expect(try await OneNoteContents.read(data).entries == [.init(name: "Zebra.one", color: 0x0011_2233),
                                                                 .init(name: "Apple.one", color: nil),
                                                                 .init(name: "Group", color: nil)])
        // Its sections come by their ordering numbers, whatever order its list holds them in.
        let numbered = OneNoteFixture.contents(first, ordering: [2, 1])
        #expect(try await OneNoteContents.read(numbered).entries.map(\.name) == ["Apple.one", "Zebra.one"])
        // A color with its high byte set is none.
        let none = try await OneNoteContents.read(OneNoteFixture.contents([("Blank.one", 0xFFFF_FFFF)]))
        #expect(none.entries == [.init(name: "Blank.one", color: nil)])
    }

    @Test func copiedEntriesMustBeThereToCopyAndAreCountedBeforeTheyAre() async throws {
        let le = { (value: UInt32) in OneStoreFixture.ID.le(value) }
        #expect(try await OneNoteContents.read(savedTwice()).entries.map(\.name) == ["A.one"])
        let crafted: [[(id: UInt16, data: [UInt8])]] = [
            [(0x025, le(99) + le(7))],                    // From an entry its dependency doesn't have.
            [(0x026, le(0) + le(3) + le(10))],            // More entries than its dependency has.
            [(0x026, le(0) + le(1) + le(0xFF_FFFF))],     // To past the last index there may be.
        ]
        for nodes in crafted {
            await #expect(throws: OneStoreError.malformed) {
                try await OneNoteContents.read(savedTwice { $0.tableNodes = nodes })
            }
        }
        // New data for an object nothing declared.
        let stray = OneStoreFixture.ID(number: 777)
        await #expect(throws: OneStoreError.malformed) {
            try await OneNoteContents.read(savedTwice {
                $0.objects.append(OneStoreFixture.Object(id: stray, jcid: 0x0002_0001, content: .properties([])))
                $0.revised.insert(stray)
            })
        }
        // It copies two entries: as many as it may, it's read; one fewer, it's too large.
        func live(copying limit: Int) throws {
            var limits = OneStore.Limits()
            limits.copiedEntries = limit
            let store = try OneStore(savedTwice(), limits: limits, type: .contents)
            let layout = try store.layout()
            _ = try store.liveRevision(of: try #require(layout.spaces[layout.root]))
        }
        try live(copying: 2)
        #expect(throws: OneStoreError.tooLarge) { try live(copying: 1) }
    }

    @MainActor @Test func sortedByNameAPackagesItemsComeInItsNotebooksOrderBeforeTheRest() {
        func item(_ name: String, folder: Bool = false) -> PreviewItem {
            PreviewItem(.member(ArchiveNode(name: name, isDirectory: folder, size: Int64(name.count)), path: [name]))
        }
        let zebra = item("Zebra.one"), apple = item("Apple.one"), group = item("Group", folder: true)
        let other = item("Other.one"), contents = item("Open Notebook.onetoc2"), folder = item("Assets", folder: true)
        let listing = PreviewListing()
        (zebra.notebookPosition, apple.notebookPosition, group.notebookPosition) = (0, 1, 2)
        let items = [apple, other, contents, folder, zebra, group]
        // Its section group among its sections, as OneNote shows it, whatever comes first otherwise.
        listing.rebuild(items)
        #expect(listing.roots.map(\.name) == ["Zebra.one", "Apple.one", "Group", "Assets", "Open Notebook.onetoc2",
                                              "Other.one"])
        listing.order = PreviewListing.Order(key: .name, ascending: false)
        listing.rebuild(items)
        #expect(listing.roots.map(\.name) == ["Group", "Apple.one", "Zebra.one", "Assets", "Other.one",
                                              "Open Notebook.onetoc2"])
        // Another column sorts as it always does.
        listing.order = PreviewListing.Order(key: .size, ascending: true)
        listing.foldersFirst = false
        listing.rebuild(items)
        #expect(listing.roots.map(\.name) == ["Assets", "Group", "Apple.one", "Other.one", "Zebra.one",
                                              "Open Notebook.onetoc2"])
    }

    @MainActor @Test func aPackageWithATableOfContentsIsListedInItsNotebooksOrder() async throws {
        let tree = try TestTree("outside")
        let files: [(String, Data)] = [("Apple.one", Data("a".utf8)), ("Other.one", Data("o".utf8)),
                                       ("Zebra.one", Data("z".utf8)),
                                       ("Open Notebook.onetoc2", OneNoteFixture.contents(Self.entries))]
        try tar(files).write(to: tree.url("Notebook.tar"))
        let environment = try PreviewEnvironment(tree)
        let session = PreviewSession(reader: environment.services.directories)
        defer { session.close() }
        session.show(try #require(FileEntry(url: tree.url("Notebook.tar"))), showHidden: false, applications: .standard)
        await session.task?.value
        await session.notebookTask?.value
        let placed = session.roots.compactMap { item in item.notebookPosition.map { (item.name, $0) } }
        #expect(placed.sorted { $0.1 < $1.1 }.map(\.0) == ["Zebra.one", "Apple.one"])
        // Without one, nothing is ordered.
        try tar(Array(files.prefix(3))).write(to: tree.url("Plain.tar"))
        session.show(try #require(FileEntry(url: tree.url("Plain.tar"))), showHidden: false, applications: .standard)
        await session.task?.value
        await session.notebookTask?.value
        #expect(session.roots.count == 3 && session.roots.allSatisfy { $0.notebookPosition == nil })
        // A notebook folder is ordered the same way, its names however capitalized, once its table of contents is
        // here: a copy not fetched yet orders nothing until it is.
        let arrived = Mutex(false)
        let unfetched = PreviewSession(reader: environment.services.directories,
                                       isPlaceholder: { $0.pathExtension == "onetoc2" && !arrived.withLock { $0 } })
        defer { unfetched.close() }
        let folder = tree.url("Notebook")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for (name, data) in files { try data.write(to: folder.appending(path: name == "Apple.one" ? "APPLE.one" : name)) }
        session.show(try #require(FileEntry(url: folder)), showHidden: false, applications: .standard)
        await session.task?.value
        await session.notebookTask?.value
        let inFolder = session.roots.compactMap { item in item.notebookPosition.map { (item.name, $0) } }
        #expect(inFolder.sorted { $0.1 < $1.1 }.map(\.0) == ["Zebra.one", "APPLE.one"])
        unfetched.show(try #require(FileEntry(url: folder)), showHidden: false, applications: .standard)
        await unfetched.task?.value
        await unfetched.notebookTask?.value
        #expect(unfetched.roots.count == 4 && unfetched.roots.allSatisfy { $0.notebookPosition == nil })
        arrived.withLock { $0 = true }
        unfetched.fetched(try #require(FileEntry(url: folder.appending(path: "Open Notebook.onetoc2"))))
        await unfetched.notebookTask?.value
        let fetched = unfetched.roots.compactMap { item in item.notebookPosition.map { (item.name, $0) } }
        #expect(fetched.sorted { $0.1 < $1.1 }.map(\.0) == ["Zebra.one", "APPLE.one"])
        #expect(tree.text("outside") == "outside")
        withExtendedLifetime(environment) {}
    }

    @MainActor @Test func itsPreviewListsTheNotebooksSectionsByTheirColors() async throws {
        let tree = try TestTree("folder/", "outside")
        try OneNoteFixture.contents(Self.entries).write(to: tree.url("folder/Open Notebook.onetoc2"))
        try OneNoteFixture.contents([("OneNote_RecycleBin", nil)]).write(to: tree.url("folder/Empty.onetoc2"))
        try Data(repeating: 0x41, count: 4096).write(to: tree.url("folder/Not.onetoc2"))
        guard case .onenoteContents? = PreviewFormat(url: tree.url("folder/Open Notebook.onetoc2"), contentType: nil) else {
            Issue.record("A table of contents isn't previewed as one")
            return
        }
        let view = try #require(RichPreview.makeView(for: tree.url("folder/Open Notebook.onetoc2"),
                                                     contentType: nil) as? OneNoteContentsView)
        await view.loadingTask?.value
        let rows = view.list.arrangedSubviews.compactMap { $0 as? NSStackView }
        #expect(rows.compactMap { ($0.arrangedSubviews.last as? NSTextField)?.stringValue } == ["Zebra", "Apple", "Group"])
        let swatches = rows.compactMap { $0.arrangedSubviews.first as? OneNoteContentsView.Swatch }
        #expect(swatches.count == 2 && swatches[1].color == nil)
        let zebra = try #require(swatches.first?.color?.usingColorSpace(.sRGB))
        #expect([zebra.redComponent, zebra.greenComponent, zebra.blueComponent].map { Int(($0 * 255).rounded()) }
                == [0x33, 0x22, 0x11])
        let count = String(localized: "\(2) sections", comment: "plural")
        #expect(view.footer.subviews.contains { ($0 as? NSTextField)?.stringValue.contains(count) == true })
        let empty = try #require(RichPreview.makeView(for: tree.url("folder/Empty.onetoc2"), contentType: nil) as? PreviewView)
        await empty.loadingTask?.value
        let said = String(localized: "This notebook lists no sections.")
        let messages = empty.subviews.compactMap { $0 as? PreviewMessageView }
        #expect(messages.flatMap { $0.subviews.flatMap(\.subviews) }.compactMap { ($0 as? NSTextField)?.stringValue } == [said])
        // A file named so that isn't one goes to Quick Look.
        var fellBack = false
        let other = try #require(RichPreview.makeView(for: tree.url("folder/Not.onetoc2"), contentType: nil) {
            fellBack = true
        } as? PreviewView)
        await other.loadingTask?.value
        #expect(fellBack && tree.text("outside") == "outside")
    }
}
