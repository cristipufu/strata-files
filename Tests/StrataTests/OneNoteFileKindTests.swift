import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch
@testable import StrataIndex
@testable import StrataPreviews
@testable import StrataSupport

/// OneNote's files have no kind or icon in macOS, nor in OneNote for Mac: Strata names them and draws a page for them.
@MainActor struct OneNoteFileKindTests {
    private let section = String(localized: "OneNote section", comment: "Kind of file")

    /// Where an app declares a type for one of OneNote's extensions, it gives it its own name and icon instead.
    private nonisolated static let undeclared = ["one", "onepkg", "onetoc2"].allSatisfy {
        UTType(filenameExtension: $0)?.isDynamic == true
    }

    @Test func onlyAnItemOfATypeNoAppDeclaresHasTheirKind() throws {
        let undeclared = try #require(UTType(filenameExtension: "strata-undeclared-kind"))
        try #require(undeclared.isDynamic)
        #expect(KnownDocument.kind(extension: "ONE", type: undeclared)?.name == section)
        for declared in [UTType.plainText, .folder, .symbolicLink, .aliasFile] {
            #expect(KnownDocument.kind(extension: "one", type: declared) == nil, "\(declared.identifier)")
        }
        #expect(KnownDocument.kind(extension: "one", type: nil) == nil)
        #expect(KnownDocument.kind(extension: "txt", type: undeclared) == nil)
    }

    /// Views compare a type's icon to tell it from a thumbnail, so it's the same image each time.
    @Test func aTypesIconIsTheSameImageEachTime() throws {
        let undeclared = try #require(UTType(filenameExtension: "strata-undeclared-icon"))
        let icons = IconCache.shared
        #expect(icons.icon(forType: .plainText) === icons.icon(forType: .plainText))
        #expect(icons.icon(forType: undeclared) === icons.icon(forType: undeclared))
        #expect(icons.icon(forType: .plainText) !== icons.icon(forType: .data))
    }

    @Test(.enabled(if: undeclared)) func oneNotesFilesHaveTheirKinds() async throws {
        let tree = try TestTree("Notes.one", "Notebook.ONEPKG", "Open Notebook.onetoc2", "folder.one/",
                                "link.one -> Notes.one")
        try alias(in: tree)
        func kind(_ name: String) throws -> String { try #require(FileEntry(url: tree.url(name))).kind }
        #expect(try kind("Notes.one") == section)
        #expect(try kind("Notebook.ONEPKG") == String(localized: "OneNote notebook package", comment: "Kind of file"))
        #expect(try kind("Open Notebook.onetoc2")
                == String(localized: "OneNote table of contents", comment: "Kind of file"))
        // A folder, a link and an alias named so aren't one.
        for name in ["folder.one", "link.one", "alias.one"] {
            #expect(try kind(name) != section, "\(name)")
            #expect(await ItemFacts.load(tree.url(name)).kind != section, "\(name)")
            #expect(InfoEditor.typeName(of: tree.url(name)) != section, "\(name)")
        }
        #expect(await ItemFacts.load(tree.url("Notes.one")).kind == section)
        #expect(InfoEditor.typeName(of: tree.url("Notes.one")) == section)
        let hit = IndexHit(path: tree.url("Notes.one").path, isDirectory: false, isPackage: false, size: 0, files: 0,
                           mtime: 0, score: 0)
        #expect(FileEntry(hit: hit).kind == section)
        let node = ArchiveNode(name: "Notes.one", isDirectory: false, size: 9)
        let member = PreviewItem(.member(node, path: ["Notes.one"]))
        #expect(member.kind == section)
        #expect(tree.snapshot() == ["Notebook.ONEPKG", "Notes.one", "Open Notebook.onetoc2", "alias.one", "folder.one/",
                                    "link.one -> Notes.one"])
    }

    /// An item's icon as read away from the main thread.
    private func loaded(_ url: URL) async -> NSImage {
        _ = IconCache.shared.icon(forPath: url.path, folder: true)
        await IconCache.shared.loaded()
        return IconCache.shared.icon(forPath: url.path, folder: true)
    }

    @Test(.enabled(if: undeclared)) func oneNotesFilesHaveAPageDrawnForThem() async throws {
        let tree = try TestTree("Notes.one", "Custom.one", "folder.one/", "link.one -> Notes.one")
        try alias(in: tree)
        let star = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
        #expect(NSWorkspace.shared.setIcon(star, forFile: tree.url("Custom.one").path))
        let icons = IconCache.shared
        let page = try self.page("one"), packagePage = try self.page("onepkg")
        #expect(page !== packagePage)
        let notes = try #require(FileEntry(url: tree.url("Notes.one")))
        #expect(icons.icon(for: notes, containerStore: .shared) === page)
        #expect(await loaded(tree.url("Notes.one")) === page)
        #expect(icons.currentIcon(forPath: tree.url("Notes.one").path) === page)
        #expect(icons.icon(forType: try #require(UTType(filenameExtension: "ONEPKG"))) === packagePage)
        // A folder named so isn't one, and a link or an alias keeps its own icon.
        for name in ["folder.one", "link.one", "alias.one"] {
            let entry = try #require(FileEntry(url: tree.url(name)))
            #expect(icons.icon(for: entry, containerStore: .shared) !== page, "\(name)")
            #expect(await loaded(tree.url(name)) !== page, "\(name)")
            #expect(icons.currentIcon(forPath: tree.url(name).path) !== page, "\(name)")
        }
        // An icon pasted onto a section in Finder shows wherever its path's icon does.
        #expect(icons.currentIcon(forPath: tree.url("Custom.one").path) !== page)
        #expect(await loaded(tree.url("Custom.one")) !== page)
        #expect(try marked(page))
        #expect(tree.snapshot() == ["Custom.one", "Notes.one", "alias.one", "folder.one/", "link.one -> Notes.one"])
    }

    @Test(.enabled(if: undeclared)) func spaceShowsAnArchivesSectionByItsKindAndPage() async throws {
        let tree = try TestTree("pack.tar")
        let environment = try PreviewEnvironment(tree)
        let record = PreviewArchiveRecord(path: ["Notes.one"], kind: 1, size: 7, modified: .distantPast,
                                          body: Data("section".utf8))
        let access = PreviewArchiveAccess(copying: { _, _, _, _ in [record] })
        let session = PreviewSession(reader: environment.services.directories, archiveAccess: access)
        let content = PreviewBrowserController(session: session, preferences: environment.preferences,
                                               thumbnails: environment.services.thumbnails,
                                               copies: environment.services.copies)
        _ = content.view
        session.show(try #require(FileEntry(url: tree.url("pack.tar"))), showHidden: true, applications: .standard)
        await session.task?.value
        let member = try #require(session.roots.first { $0.name == "Notes.one" })
        let page = try page("one")
        #expect(member.kind == section && member.icon(environment.services.thumbnails) === page)
        let column = try #require(content.outline.tableColumns.first { $0.identifier.rawValue == "previewName" })
        let cell = try #require(content.outlineView(content.outline, viewFor: column, item: member) as? NameCellView)
        #expect(cell.imageView?.image === page)
        content.close()
        #expect(tree.snapshot().filter { !$0.hasPrefix("environment/") } == ["pack.tar"])
        withExtendedLifetime(environment) {}
    }

    /// The conflict sheet and the Shelf show what's there now, not an icon remembered from before.
    @Test(.enabled(if: undeclared)) func aChoiceShowsTheItemsIconNow() throws {
        let tree = try TestTree("Later.one/")
        let url = tree.url("Later.one")
        let page = try page("one")
        #expect(IconCache.shared.icon(forPath: url.path, folder: true) !== page)
        try FileManager.default.removeItem(at: url)
        try Data("section".utf8).write(to: url)
        #expect(ItemCard(caption: "Existing", url: url).imageView.image === page)
        let shelf = ShelfWell(frame: .zero)
        shelf.add([url])
        #expect(shelf.iconView.image === page)
        #expect(tree.text("Later.one") == "section")
    }

    private func page(_ ext: String) throws -> NSImage {
        let kind = KnownDocument.kind(extension: ext, type: UTType(filenameExtension: ext))
        return IconCache.shared.documentIcon(try #require(kind))
    }

    private func alias(in tree: TestTree) throws {
        let bookmark = try tree.url("Notes.one").bookmarkData(options: .suitableForBookmarkFile)
        try URL.writeBookmarkData(bookmark, to: tree.url("alias.one"))
    }

    /// The page carries its mark in its own color.
    private func marked(_ image: NSImage) throws -> Bool {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                                   bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        let indigo = try #require(NSColor.systemIndigo.usingColorSpace(.deviceRGB)).hueComponent
        return (28..<46).contains { y in (24..<40).contains { x in
            guard let color = bitmap.colorAt(x: x, y: y) else { return false }
            return color.saturationComponent > 0.3 && abs(color.hueComponent - indigo) < 0.05
        } }
    }
}
