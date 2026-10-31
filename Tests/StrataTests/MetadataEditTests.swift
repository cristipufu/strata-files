import Foundation
import Testing
@testable import Strata

/// Compress, Get Info's edits (Locked, permissions, comments) and tags: each adds or changes exactly what it says on
/// the items chosen, never a link's target, never what's inside a folder, never the item's other metadata.
struct MetadataEditTests {
    private let keep = "dev.strata.test.keep"

    private func setKeep(_ path: String) {
        let value = Data("mine".utf8)
        _ = value.withUnsafeBytes { setxattr(path, keep, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
    }

    private func hasKeep(_ path: String) -> Bool { getxattr(path, keep, nil, 0, 0, XATTR_NOFOLLOW) == 4 }

    private func flags(_ path: String) -> UInt32 {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_flags : 0
    }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode & 0o7777 : 0
    }

    // MARK: - Compress

    @Test func compressingAddsOneArchiveAndNeverReplacesOne() async throws {
        let tree = try TestTree("a.txt", "b/", "b/inner.txt", "a.txt.zip", "Archive.zip")
        let before = tree.snapshot()
        let single = [tree.url("a.txt")]
        let one = try await TestWork.run { try Archiver.compress(single, copies: .live, control: Archiver.Control()) }
        #expect(one.lastPathComponent == "a.txt 2.zip")
        let selection = [tree.url("a.txt"), tree.url("b")]
        let several = try await TestWork.run { try Archiver.compress(selection, copies: .live, control: Archiver.Control()) }
        #expect(several.lastPathComponent == "Archive 2.zip")
        #expect(tree.snapshot() == (before + ["a.txt 2.zip", "Archive 2.zip"]).sorted())
        // What was there and what was compressed are as they were.
        #expect(tree.text("a.txt.zip") == "a.txt.zip" && tree.text("Archive.zip") == "Archive.zip")
        #expect(tree.text("b/inner.txt") == "b/inner.txt")
    }

    @Test func aLinkIsArchivedAsALink() async throws {
        let tree = try TestTree("target/", "target/big.txt", "link -> target", "out/")
        let links = [tree.url("link")], destination = tree.url("out")
        try await TestWork.run {
            let archive = try Archiver.compress(links, copies: .live, control: Archiver.Control())
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", archive.path, destination.path]
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        }
        // Inside the zip: the link, not the folder it points to.
        #expect(tree.snapshot() == ["link -> target", "link.zip", "out/", "out/link -> target", "target/", "target/big.txt"])
    }

    // MARK: - Get Info

    @Test func lockingTouchesOnlyThatItem() throws {
        let tree = try TestTree("a.txt", "b.txt", "link -> b.txt", "folder/", "folder/inner.txt")
        try FileInfoEditing.setLocked(true, of: ChosenFile(URL(fileURLWithPath: tree.url("a.txt").path)))
        try FileInfoEditing.setLocked(true, of: ChosenFile(URL(fileURLWithPath: tree.url("link").path)))
        try FileInfoEditing.setLocked(true, of: ChosenFile(URL(fileURLWithPath: tree.url("folder").path)))
        #expect(flags(tree.url("a.txt").path) & UInt32(UF_IMMUTABLE) != 0)
        #expect(flags(tree.url("link").path) & UInt32(UF_IMMUTABLE) != 0)
        #expect(flags(tree.url("b.txt").path) & UInt32(UF_IMMUTABLE) == 0)
        #expect(flags(tree.url("folder/inner.txt").path) & UInt32(UF_IMMUTABLE) == 0)
        try FileInfoEditing.setLocked(false, of: ChosenFile(URL(fileURLWithPath: tree.url("a.txt").path)))
        #expect(flags(tree.url("a.txt").path) & UInt32(UF_IMMUTABLE) == 0)
    }

    @Test func permissionsChangeOnlyThatAccessOnThatItem() throws {
        let tree = try TestTree("file.txt", "folder/", "folder/inner.txt", "link -> file.txt")
        chmod(tree.url("file.txt").path, 0o644)
        chmod(tree.url("folder/inner.txt").path, 0o644)
        try FileInfoEditing.setAccess(.readWrite, for: .group, of: ChosenFile(URL(fileURLWithPath: tree.url("file.txt").path)))
        #expect(mode(tree.url("file.txt").path) == 0o664)
        try FileInfoEditing.setAccess(.none, for: .everyone, of: ChosenFile(URL(fileURLWithPath: tree.url("folder").path)))
        #expect(mode(tree.url("folder").path) & 0o7 == 0)
        chmod(tree.url("file.txt").path, 0)
        try FileInfoEditing.setAccess(.readWrite, for: .owner, of: ChosenFile(URL(fileURLWithPath: tree.url("file.txt").path)))
        try FileInfoEditing.setAccess(.readWrite, for: .group, of: ChosenFile(URL(fileURLWithPath: tree.url("file.txt").path)))
        try FileInfoEditing.setAccess(.readOnly, for: .everyone, of: ChosenFile(URL(fileURLWithPath: tree.url("file.txt").path)))
        // Nothing inside the folder changes, and a link's target is never reached.
        #expect(mode(tree.url("folder/inner.txt").path) == 0o644)
        #expect(throws: (any Error).self) { try FileInfoEditing.setAccess(.none, for: .owner, of: ChosenFile(URL(fileURLWithPath: tree.url("link").path))) }
        #expect(mode(tree.url("file.txt").path) == 0o664)
    }

    /// Get Info shows the opened item's own settings, nothing once another has taken its place, and what's at the
    /// path for an item it can't open (the startup disk), which it refuses to change.
    @Test func getInfoShowsTheSettingsOfWhatItChanges() throws {
        let tree = try TestTree("folder/", "aside/")
        let shown = try ChosenFile(tree.url("folder"))
        #expect(InfoEditor.status(of: .success(shown), at: tree.url("folder").path) != nil)
        try FileManager.default.moveItem(at: tree.url("folder"), to: tree.url("aside/folder"))
        try FileManager.default.createDirectory(at: tree.url("folder"), withIntermediateDirectories: false)
        #expect(InfoEditor.status(of: .success(shown), at: tree.url("folder").path) == nil)
        let startupDisk = Result { try ChosenFile(URL(fileURLWithPath: "/")) }
        #expect(throws: (any Error).self) { try startupDisk.get() }
        #expect(InfoEditor.status(of: startupDisk, at: "/") != nil)
        #expect(tree.snapshot() == ["aside/", "aside/folder/", "folder/"])
    }

    /// A lock chosen for an item shown goes only to that item: a folder put in its place since stays as it is.
    @Test func lockingChangesOnlyTheItemShown() throws {
        let tree = try TestTree("folder/", "aside/")
        let shown = try ChosenFile(tree.url("folder"))
        try FileManager.default.moveItem(at: tree.url("folder"), to: tree.url("aside/folder"))
        try FileManager.default.createDirectory(at: tree.url("folder"), withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try FileInfoEditing.setLocked(true, of: shown) }
        #expect(flags(tree.url("folder").path) & UInt32(UF_IMMUTABLE) == 0)
        #expect(flags(tree.url("aside/folder").path) & UInt32(UF_IMMUTABLE) == 0)
        #expect(tree.snapshot() == ["aside/", "aside/folder/", "folder/"])
    }

    /// Access chosen for an item shown goes only to that item: a folder put in its place since keeps its own.
    @Test func accessChangesOnlyTheItemShown() throws {
        let tree = try TestTree("folder/", "aside/")
        let shown = try ChosenFile(tree.url("folder"))
        try FileManager.default.moveItem(at: tree.url("folder"), to: tree.url("aside/folder"))
        try FileManager.default.createDirectory(at: tree.url("folder"), withIntermediateDirectories: false)
        let before = try #require(FileInfoEditing.mode(at: tree.url("folder").path))
        #expect(throws: (any Error).self) { try FileInfoEditing.setAccess(.none, for: .owner, of: shown) }
        #expect(FileInfoEditing.mode(at: tree.url("folder").path) == before)
        #expect(tree.snapshot() == ["aside/", "aside/folder/", "folder/"])
    }

    @Test func aCommentChangesOnlyTheComment() throws {
        let tree = try TestTree("a.txt", "b.txt", "link -> b.txt")
        setKeep(tree.url("a.txt").path)
        try FileInfoEditing.setComment("Quarterly numbers", at: tree.url("a.txt").path)
        #expect(FileInfoEditing.comment(at: tree.url("a.txt").path) == "Quarterly numbers")
        #expect(hasKeep(tree.url("a.txt").path))
        try FileInfoEditing.setComment("On the link", at: tree.url("link").path)
        #expect(FileInfoEditing.comment(at: tree.url("b.txt").path).isEmpty)
        try FileInfoEditing.setComment("", at: tree.url("a.txt").path)
        #expect(FileInfoEditing.comment(at: tree.url("a.txt").path).isEmpty && hasKeep(tree.url("a.txt").path))
        #expect(tree.snapshot() == ["a.txt", "b.txt", "link -> b.txt"])
    }

    // MARK: - Tags

    @Test func tagsGoOnTheChosenFilesOnly() async throws {
        let tree = try TestTree("a.txt", "b.txt", "c.txt", "link -> b.txt")
        setKeep(tree.url("a.txt").path)
        let store = TagStore(preferences: try Prefs.isolated(), copies: .live)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        try store.update([tree.url("a.txt"), tree.url("link")], adding: ["Strata Test"], removing: [], undo: undo)
        undo.endUndoGrouping()
        func tags(_ path: String) -> [String] {
            (try? tree.url(path).resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        }
        #expect(tags("a.txt") == ["Strata Test"])
        // A link isn't tagged, and what it points to isn't either.
        #expect(tags("b.txt").isEmpty && tags("c.txt").isEmpty)
        #expect(getxattr(tree.url("link").path, "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, XATTR_NOFOLLOW) < 0)
        #expect(hasKeep(tree.url("a.txt").path))
        undo.undo()
        for _ in 0..<40 where !tags("a.txt").isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(tags("a.txt").isEmpty && hasKeep(tree.url("a.txt").path))
    }
}
