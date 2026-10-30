import AppKit
import Foundation
import Testing
@testable import Strata
@testable import StrataIndex
@testable import StrataModel
@testable import StrataPreviews
@testable import StrataSupport

struct EdgeCaseSafetyTests {
    @Test func extremeSpotlightAndNaturalQueriesNeverOverflowOrTrap() {
        for raw in [
            "width:99999999999999999999999",
            "height:>100000000000000000000000",
            "pages:<99999999999999999999999",
            "size:>1e308gb",
            "duration:>1e300h",
            "duration:99999999999999999999999s",
        ] {
            _ = SpotlightQuery.parse(raw)
        }

        for natural in [
            "modified 9999999999999999999 weeks ago",
            "created last 9999999999999999999 months",
            "from 9223372036854775807",
            "modified:>9999999999999999999w",
            "size:>1e308gb",
        ] {
            let interpreted = QueryInterpreter.parse(natural)
            #expect(interpreted.source == .rules)
        }
    }

    @Test func summarizerSectionsHandleZeroAndSingleSectionLimits() {
        let text = String(repeating: "abcdef", count: 1000)
        #expect(Summarizer.sections(text, size: 0, limit: 4).kept.isEmpty)
        #expect(Summarizer.sections(text, size: -10, limit: 4).kept.isEmpty)
        #expect(Summarizer.sections(text, size: 100, limit: 0).kept.isEmpty)
        let single = Summarizer.sections(text, size: 100, limit: 1)
        #expect(single.kept.count == 1 && single.kept[0].count == 100)
    }

    @Test func halfPrecisionEncodingHandlesEmptyVectors() {
        let encoded = Half.encode([])
        #expect(encoded.isEmpty)
        let roundTrip = Half.encode([1.5, -2.0])
        #expect(roundTrip.count == 2)
        var decoded = [Float](repeating: 0, count: 2)
        roundTrip.withUnsafeBufferPointer { buffer in
            decoded.withUnsafeMutableBufferPointer { out in
                Half.decode(buffer, into: out.baseAddress!)
            }
        }
        #expect(decoded == [1.5, -2.0])
    }

    @Test func streamDemuxRejectsOversizeFrameHeaderBeforeBufferingPayload() {
        var demux = StreamDemux(outputLimit: 1024, errorLimit: 1024)
        let hugeHeader = Data([1, 0, 0, 0, 0x7F, 0xFF, 0xFF, 0xFF])
        #expect(throws: UnixHTTP.Failure.tooLarge) {
            _ = try demux.feed(hugeHeader)
        }
        #expect(demux.output.isEmpty)
    }

    @Test func treemapProducesFiniteRectsForExtremeRatiosAndDetachesDisplayLink() throws {
        let frames = Treemap.squarify([1e16, 1, 1], in: CGRect(x: 0, y: 0, width: 300, height: 200))
        #expect(frames.count == 3)
        for frame in frames {
            #expect(frame.origin.x.isFinite && frame.origin.y.isFinite)
            #expect(frame.width.isFinite && frame.height.isFinite)
            #expect(frame.width >= 0 && frame.height >= 0)
        }
        #expect(Treemap.squarify([10, 5], in: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100)) == [.zero, .zero])

        let tree = try TestTree("a.txt", "b.txt")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        weak var weakController: TreemapViewController?
        do {
            let controller = TreemapViewController(copies: .live)
            weakController = controller
            window.contentView = controller.view
            controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            controller.view.layoutSubtreeIfNeeded()
            let first = [TreemapItem(url: tree.url("a.txt"), name: "a.txt", bytes: 1000, isFolder: false)]
            let second = [TreemapItem(url: tree.url("a.txt"), name: "a.txt", bytes: 500, isFolder: false),
                          TreemapItem(url: tree.url("b.txt"), name: "b.txt", bytes: 500, isFolder: false)]
            controller.setItems(first, animated: false)
            controller.setItems(second, animated: true)
            window.contentView = nil
        }
        #expect(weakController == nil)
        #expect(tree.snapshot() == ["a.txt", "b.txt"])
    }

    @Test func namedPipesDoNotBlockInspectorGitProjectOrDelimitedReaders() async throws {
        let tree = try TestTree("kept.txt")
        let fifo = tree.url("compose.yaml")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        let writer = open(fifo.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        try #require(writer >= 0)
        defer { close(writer) }
        let payload = "services:\n  web:\n    image: nginx\n"
        let written = payload.withCString { write(writer, $0, payload.utf8.count) }
        try #require(written == payload.utf8.count)

        #expect(ComposeInspectorView.serviceNames(in: fifo).isEmpty)
        #expect(ProjectDetector.makeTargets(fifo, directory: tree.root, source: "Makefile").isEmpty)
        #expect(ProjectDetector.justRecipes(fifo, directory: tree.root, source: "justfile").isEmpty)
        #expect(await TextExtractor.extract(fifo) == nil)
        await #expect(throws: (any Error).self) {
            _ = try await DelimitedLoader.load(fifo, separator: 0x2C)
        }

        // None of the readers consumed the pipe's bytes.
        var remaining = [UInt8](repeating: 0, count: payload.utf8.count)
        let readCount = remaining.withUnsafeMutableBytes { read(writer, $0.baseAddress, $0.count) }
        #expect(readCount == payload.utf8.count)
        #expect(tree.snapshot() == ["compose.yaml", "kept.txt"])
    }

    @Test func previewPanelAndPreviewPaneHandleBoundaryInputsSafely() throws {
        let tree = try TestTree("a.txt")
        let entry = try #require(FileEntry(url: tree.url("a.txt")))
        let browser = BrowserViewController(services: .shared)
        _ = browser.view
        #expect(browser.previewPanel(nil, previewItemAt: -1) == nil)
        #expect(browser.previewPanel(nil, previewItemAt: 0) == nil)
        browser.showResults([entry], total: 1)
        browser.select([entry.url])
        #expect((browser.previewPanel(nil, previewItemAt: 0) as? URL) == entry.url)
        #expect(browser.previewPanel(nil, previewItemAt: 1) == nil)

        let pane = ColumnPreviewPane()
        pane.frame = NSRect(x: 0, y: 0, width: 10, height: 200)
        pane.show(entry)
        pane.layoutSubtreeIfNeeded()
        #expect(pane.frame.width == 10)
        #expect(tree.snapshot() == ["a.txt"])
    }

    @Test func indexStoreAndDuplicateFinderSaturateInsteadOfOverflowing() {
        let group = DuplicateGroup(size: Int64.max, paths: ["/a", "/b", "/c"])
        #expect(group.reclaimable == Int64.max)

        let store = IndexStore()
        store.write { store in
            let root = store.addRoot(path: "/synthetic", mtime: 0)
            let names = Array("a\0b".utf8)
            let items = [
                ScannedItem(nameOffset: 0, nameLength: 1, isDirectory: false, isPackage: false, isSymlink: false,
                            isHidden: false, isMountPoint: false, size: Int64.max - 10, mtime: 0),
                ScannedItem(nameOffset: 2, nameLength: 1, isDirectory: false, isPackage: false, isSymlink: false,
                            isHidden: false, isMountPoint: false, size: 100, mtime: 0),
            ]
            _ = names.withUnsafeBytes { store.appendChildren(items, nameBuffer: $0, of: root) }
            store.aggregate()
            #expect(store.size[Int(root)] == Int64.max)
            #expect(store.fileCount[Int(root)] == 2)
            let emptyRoot = store.addRoot(path: "", mtime: 0)
            let emptyMatch = store.nameEquals(emptyRoot, [])
            let nonEmptyMatch = store.nameEquals(root, [])
            #expect(emptyMatch)
            #expect(!nonEmptyMatch)
        }

        var emptyTermQuery = IndexQuery()
        emptyTermQuery.terms = [[]]
        let result = IndexSearch.run(emptyTermQuery, in: store, limit: 10)
        #expect(result.hits.isEmpty)
        #expect(result.total == 0)
    }

    @Test func planExpanderRenderHandlesCombiningMarkExtensionsAndNonPositiveTextLimits() {
        let combiningItem = PlanItem(
            url: URL(fileURLWithPath: "/tmp/a.\u{0301}"),
            name: "a.\u{0301}",
            isFolder: false,
            kind: "Document",
            contentType: nil,
            size: 1,
            created: nil,
            modified: nil,
            captureDate: nil,
            cameraModel: nil
        )
        let rendered = PlanExpander.render("{name}.\u{0301}", item: combiningItem, index: 1, width: 2, source: .modified)
        #expect(rendered == "a")

        #expect(TextChunker.chunks("hello world", target: 0, overlap: 0).isEmpty)
        #expect(!TextChunker.chunks("hello world", target: 5, overlap: 5).isEmpty)
        #expect(Summarizer.shorten("hello world", to: 0).isEmpty)
        #expect(Summarizer.shorten("hello world", to: -5).isEmpty)
        let markdown = MarkdownRenderer(baseURL: URL(fileURLWithPath: "/tmp")).render(MarkdownParser.parse("![](missing.png)"))
        #expect(markdown.length >= 0)
        #expect(!TransferFormat.rate(.infinity).isEmpty)
        #expect(!TransferFormat.rate(.nan).isEmpty)
        #expect(!TransferFormat.remaining(.infinity).isEmpty)
        #expect(!TransferFormat.remaining(.nan).isEmpty)
        _ = TransferRing.Key(progress: .nan, hasFailures: false)
        _ = TransferRing.Key(progress: .infinity, hasFailures: false)
    }

    @Test func duplicateFinderAndArchiveListerSkipNamedPipesAndOversizeExtensionsSafely() async throws {
        let tree = try TestTree("regular.txt")
        let fifoA = tree.url("pipe-a.tar")
        let fifoB = tree.url("pipe-b.tar")
        try #require(mkfifo(fifoA.path, 0o600) == 0)
        try #require(mkfifo(fifoB.path, 0o600) == 0)

        let groups = DuplicateFinder.find([
            [],
            [
                (path: fifoA.path, size: 8192),
                (path: fifoB.path, size: 8192),
            ],
        ], progress: { _, _ in }, isCancelled: { false })
        #expect(groups.isEmpty)

        await #expect(throws: (any Error).self) {
            _ = try await ArchiveLister.list(fifoA, kind: .tar)
        }

        let longExtName = "prefix." + String(repeating: "e", count: 245)
        let longExtURL = tree.url(longExtName)
        try Data("x".utf8).write(to: longExtURL)
        let available = FileOps.available(longExtURL, copyStyle: false)
        #expect(available.lastPathComponent.utf8.count <= 255)
        #expect(available != longExtURL)
        #expect(tree.snapshot().contains("regular.txt"))
    }

    @Test func emptyPathDecodeGuardsNeverAbortOnEmptyStrings() throws {
        let prefs = try Prefs.isolated()
        prefs.defaults.set("", forKey: "lastLocation")
        #expect(prefs.lastLocation == nil)

        let ws = Workspace(name: "Empty", tabs: [[""]])
        let plan = WorkspacePlan(ws, exists: { _ in true })
        #expect(plan.tabs.isEmpty)

        let badEntryJSON = Data(#"{"id":"00000000-0000-0000-0000-000000000000","date":0,"name":"Rename","kind":"move","pairs":[["",""]]}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(OperationLog.Entry.self, from: badEntryJSON)
        }
    }

    @Test func containerSubfolderLinkTargetsStayInsideSubfolderWhenCopiedOut() throws {
        let targetInSameSubtree = ContainerCopies.copyLinkTarget("/app/sub/b.txt", at: "/app/sub/a")
        #expect(targetInSameSubtree == "b.txt")
        let targetInSiblingSubtree = ContainerCopies.copyLinkTarget("/app/lib/c.txt", at: "/app/sub/a")
        #expect(targetInSiblingSubtree == "../lib/c.txt")

        let tree = try TestTree("copied/", "copied/sub/", "copied/sub/b.txt", "copied/lib/", "copied/lib/c.txt")
        try FileManager.default.createSymbolicLink(atPath: tree.url("copied/sub/a").path, withDestinationPath: try #require(targetInSameSubtree))
        try FileManager.default.createSymbolicLink(atPath: tree.url("copied/sub/escape").path, withDestinationPath: "../../outside.txt")
        try ContainerCopies.finishCopyingOut(tree.url("copied/sub"), owned: TransferEngine.snapshotIdentities(tree.url("copied/sub")))
        #expect(tree.snapshot() == ["copied/", "copied/lib/", "copied/lib/c.txt", "copied/sub/", "copied/sub/a -> b.txt", "copied/sub/b.txt"])
    }

    @Test func planValidatorExcludesNestedTrashInsideChangedFolderAndToggleDisablesVacatedDependents() async throws {
        let tree = try TestTree("dir/", "dir/inner.txt", "a.txt", "b.txt")
        let items = await PlanItem.load([tree.url("dir"), tree.url("dir/inner.txt"), tree.url("a.txt"), tree.url("b.txt")])
        let nestedTrashPlan = PlanValidator.validate(
            [.trash(tree.url("dir")), .trash(tree.url("dir/inner.txt"))],
            request: .init(instruction: "trash", items: items, baseFolder: tree.root),
            source: .model,
            interpretation: ""
        )
        #expect(nestedTrashPlan.steps.count == 1)
        #expect(nestedTrashPlan.steps.first?.source?.lastPathComponent == "dir")
        #expect(nestedTrashPlan.excluded.count == 1)

        let chainPlan = PlanValidator.validate(
            [.rename(tree.url("a.txt"), to: "c.txt"), .rename(tree.url("b.txt"), to: "a.txt")],
            request: .init(instruction: "rename", items: items, baseFolder: tree.root),
            source: .model,
            interpretation: ""
        )
        #expect(chainPlan.steps.count == 2)
        let sheet = PlanSheetController(urls: [tree.url("a.txt"), tree.url("b.txt")], baseFolder: tree.root, undoManager: nil, files: BrowserFileCommands(transfers: .shared))
        _ = sheet.view
        sheet.phase = .review(chainPlan)
        sheet.toggle(chainPlan.steps[0].id, on: false)
        guard case let .review(updatedPlan) = sheet.phase else {
            Issue.record("Expected review phase")
            return
        }
        #expect(updatedPlan.steps.allSatisfy { !$0.isEnabled })
        #expect(tree.snapshot() == ["a.txt", "b.txt", "dir/", "dir/inner.txt"])
    }

    @Test func inlineRenameFieldCancelDiscardsEditsWithoutCommitting() {
        var committed: String?
        var ended = false
        let field = InlineRenameField(name: "original.txt", isFolder: false, centered: false, font: .systemFont(ofSize: 13))
        field.onCommit = { committed = $0 }
        field.onEnd = { ended = true }
        field.stringValue = "half-typed.txt"
        field.cancel()
        #expect(committed == nil)
        #expect(ended)
    }

    @Test func tagStoreUndoDoesNotRestoreTagsOntoReplacementFile() async throws {
        let tree = try TestTree("doc.txt", "replacement.txt")
        let doc = tree.url("doc.txt")
        let replacement = tree.url("replacement.txt")
        let store = TagStore()
        defer { store.forget("Strata Edge Test") }
        // Tags are read in the background: what's there once that read is done.
        func current(_ url: URL) async -> [String] {
            _ = store.tags(for: url)
            while let reading = store.requests { await reading.value }
            return store.tags(for: url).map(\.name)
        }
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        try store.update([doc], adding: ["Strata Edge Test"], removing: [], undo: undo)
        undo.endUndoGrouping()
        #expect(await current(doc) == ["Strata Edge Test"])

        try FileManager.default.removeItem(at: doc)
        try FileManager.default.moveItem(at: replacement, to: doc)
        store.invalidate(tree.root)
        #expect(await current(doc).isEmpty)

        undo.undo()
        store.invalidate(tree.root)
        #expect(await current(doc).isEmpty)
        #expect(tree.snapshot() == ["doc.txt"])
    }

    @Test func codeLoaderShortensLongUTF16LinesAndGridRejectsMalformedNumbers() async throws {
        let tree = try TestTree()
        let codeURL = tree.root.appending(path: "long.json")
        // 1,100 astral emoji characters = 2,200 UTF-16 code units (> maxLineLength 2,000), but < 2,000 Character count.
        let longLine = "\"" + String(repeating: "😀", count: 1_100) + "\""
        try Data(longLine.utf8).write(to: codeURL)
        let doc = try await CodeLoader.load(codeURL, mode: .json)
        #expect(doc.note != nil)
        #expect(doc.storage.value.length <= CodeLoader.maxLineLength + 4)

        var grid = GridData(
            columns: [GridColumn(title: "version"), GridColumn(title: "badExp"), GridColumn(title: "good")],
            rows: [
                [.text("1.2.3"), .text("1e+"), .text("1.25e+3")],
                [.text("2.0.1"), .text("1e1-2"), .text("-42.5%")],
            ]
        )
        grid.detectNumericColumns()
        #expect(!grid.columns[0].isNumeric)
        #expect(!grid.columns[1].isNumeric)
        #expect(grid.columns[2].isNumeric)
        #expect(tree.snapshot() == ["long.json"])
    }

    @Test func duplicateFinderAndFolderCompareVerifyOnDiskRegularFilesAndSizes() throws {
        let tree = try TestTree("a.txt", "b.txt", "link -> a.txt")
        let a = tree.url("a.txt")
        let b = tree.url("b.txt")
        let link = tree.url("link")
        try Data("same-prefix-0123456789".utf8).write(to: a)
        try Data("same-prefix-0123456789-appended-later".utf8).write(to: b)

        // If `b.txt` grew after indexing, DuplicateFinder must not group it with `a.txt` under the stale 22-byte size.
        let staleCandidates: [[(path: String, size: Int64)]] = [[(a.path, 22), (b.path, 22)]]
        let groups = DuplicateFinder.find(staleCandidates, progress: { _, _ in }, isCancelled: { false })
        #expect(groups.isEmpty)

        let control = FolderCompare.Control()
        #expect(!FolderCompare.sameBytes(a, b, control: control))
        #expect(!FolderCompare.sameBytes(a, link, control: control))
        try Data("same-prefix-0123456789".utf8).write(to: b)
        #expect(FolderCompare.sameBytes(a, b, control: control))

        let q1 = IndexQuery.parse("size:<nanmb modified:<nand size:>-5mb")
        #expect(q1.maxSize == nil)
        #expect(q1.minSize == nil)
        #expect(q1.modifiedAfter == nil)
        #expect(q1.modifiedBefore == nil)
        #expect(tree.snapshot() == ["a.txt", "b.txt", "link -> a.txt"])
    }

    @Test func outermostPreservesURLSpellingsAndArchiverChecksQuarantinedReadOnlyAndChainedLinks() throws {
        let tree = try TestTree("dir/", "dir/inner.txt", "sub/", "sub/back -> ..", "escape -> sub/back/../outside")
        let dirURL = tree.url("dir")
        let innerURL = tree.url("dir/inner.txt")
        let outer = FileOps.outermost([dirURL, innerURL, dirURL])
        #expect(outer == [dirURL])
        #expect(outer.first?.path == dirURL.path)

        var budget = 4096
        let escaped = Archiver.resolve("sub/back/../outside", from: [], in: tree.root.path, hops: 0, budget: &budget)
        #expect(escaped == nil)

        let extracted = tree.url("extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let readOnly = extracted.appending(path: "readonly.txt")
        try Data("hello".utf8).write(to: readOnly)
        chmod(readOnly.path, 0o444)
        let fifo = extracted.appending(path: "pipe.fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)

        let quarantine = Data("0081;00000000;StrataTest;".utf8)
        try Archiver.check(extracted, quarantine: quarantine)
        #expect(TestTree.listing(of: extracted) == ["readonly.txt"])
        chmod(readOnly.path, 0o644)
        try FileManager.default.removeItem(at: extracted)
        #expect(tree.snapshot() == ["dir/", "dir/inner.txt", "escape -> sub/back/../outside", "sub/", "sub/back -> .."])
    }

    @Test func nonExclusiveRenameFallbacksNeverOverwriteExistingFilesOrFolders() throws {
        let tree = try TestTree("out/a.txt", "out/folder/", "out/dangling -> missing", "staging/f1.txt", "staging/f2.txt", "staging/d1/", "staging/d1/inside.txt")
        #expect(TransferEngine.rename(tree.url("staging/f1.txt"), to: tree.url("out/a.txt"), supportsExclusiveRename: false) == EEXIST)
        #expect(TransferEngine.rename(tree.url("staging/f1.txt"), to: tree.url("out/dangling"), supportsExclusiveRename: false) == EEXIST)
        #expect(tree.text("out/a.txt") == "out/a.txt")
        #expect(TransferEngine.rename(tree.url("staging/f1.txt"), to: tree.url("out/free.txt"), supportsExclusiveRename: false) == 0)
        #expect(tree.text("out/free.txt") == "staging/f1.txt")

        let placedFile = try Archiver.place(tree.url("staging/f2.txt"), in: tree.url("out"), as: "a.txt", supportsExclusiveRename: false)
        #expect(placedFile.lastPathComponent == "a 2.txt")
        #expect(tree.text("out/a.txt") == "out/a.txt")
        #expect(tree.text("out/a 2.txt") == "staging/f2.txt")

        let placedDir = try Archiver.place(tree.url("staging/d1"), in: tree.url("out"), as: "folder", supportsExclusiveRename: false)
        #expect(placedDir.lastPathComponent == "folder 2")
        #expect(tree.text("out/folder 2/inside.txt") == "staging/d1/inside.txt")
        #expect(tree.snapshot() == [
            "out/", "out/a 2.txt", "out/a.txt", "out/dangling -> missing", "out/folder 2/", "out/folder 2/inside.txt",
            "out/folder/", "out/free.txt", "staging/",
        ])
    }

    @Test func wideDelimitedRowsFIFOPreviewsExtremePlanDaysAndTreemapBoundsRemainSafe() async throws {
        let tree = try TestTree("wide.csv")
        let wide = (0..<600).map { "c\($0)" }.joined(separator: ",") + "\n" + (0..<600).map(String.init).joined(separator: ",")
        try Data(wide.utf8).write(to: tree.url("wide.csv"))
        let table = try await DelimitedLoader.load(tree.url("wide.csv"), separator: UInt8(ascii: ","))
        #expect(table.data.columns.count == DelimitedLoader.columnLimit)
        #expect(table.data.rows.first?.count == DelimitedLoader.columnLimit)

        let fifo = tree.url("pipe.pdf")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let media = await MediaInfo.read(fifo, contentType: nil)
        #expect(media.dimensions == nil && media.duration == nil)
        let exif = PlanItem.exif(fifo)
        #expect(exif.0 == nil && exif.1 == nil)
        #expect(await TextExtractor.extract(fifo) == nil)
        try FileManager.default.removeItem(at: fifo)

        #expect(PlanRules.recipe(for: "trash files older than 999999999999999 days") != nil)
        #expect(PlanRules.recipe(for: "trash files newer than 999999999999999 days") != nil)

        let badRects = Treemap.squarify([.nan, .infinity, -5, 0, 10], in: NSRect(x: 0, y: 0, width: 100, height: 100))
        #expect(badRects == Array(repeating: .zero, count: 5))
        #expect(tree.snapshot() == ["wide.csv"])
    }
}
