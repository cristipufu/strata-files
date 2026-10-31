import AppKit
import Testing
@testable import Strata

/// The path bar reads the disk away from the main thread: what a typed path is, Tab completion, and a chevron's
/// subfolders. What it finds acts only if the field still shows the text it was found for.
@MainActor struct PathBarDiskTests {
    private func pathBar(_ environment: IndependentEnvironment, at url: URL) -> PathBar {
        let services = environment.services
        let bar = PathBar(preferences: services.preferences, places: services.places, index: services.index,
                          copies: services.copies, names: services.folderNames, clipboard: services.clipboard)
        bar.url = url
        bar.beginEditing()
        return bar
    }

    private func press(_ selector: Selector, in bar: PathBar) {
        _ = bar.control(bar.editorField, textView: NSTextView(), doCommandBy: selector)
    }

    @Test func aTypedPathIsAFolderAnotherItemOrNothing() async throws {
        let tree = try TestTree("folder/", "file.txt", "Tool.app/Contents/")
        #expect(await PathBar.kind(of: tree.url("folder").path) == .folder)
        #expect(await PathBar.kind(of: tree.url("file.txt").path) == .item)
        #expect(await PathBar.kind(of: tree.url("Tool.app").path) == .item)
        #expect(await PathBar.kind(of: tree.url("missing").path) == nil)
        #expect(tree.snapshot() == ["Tool.app/", "Tool.app/Contents/", "file.txt", "folder/"])
    }

    @Test func completionAndChevronsListOnlyTheFoldersTheyShow() async throws {
        let tree = try TestTree("Alpha/", "alps/", "Alpine.txt", ".alpha/", "beta/", "Tool.app/Contents/", ".hidden/")
        #expect(await PathBar.folders(in: tree.root.path, startingWith: "al") == ["Alpha", "alps"])
        #expect(await PathBar.folders(in: tree.root.path, startingWith: ".al") == [".alpha"])
        #expect(await PathBar.folders(in: tree.url("missing").path, startingWith: "") == nil)
        #expect(await ChevronButton.subfolders(of: tree.root).map(\.lastPathComponent) == ["Alpha", "alps", "beta"])
        #expect(tree.snapshot() == [".alpha/", ".hidden/", "Alpha/", "Alpine.txt", "Tool.app/", "Tool.app/Contents/",
                                    "alps/", "beta/"])
    }

    @Test func returnOpensAFolderOrShowsAFileAndANewerTextWins() async throws {
        let tree = try TestTree("start/", "folder/", "file.txt")
        let environment = try IndependentEnvironment()
        let bar = pathBar(environment, at: tree.url("start"))
        var navigated: [(String, String?)] = []
        bar.onNavigate = { navigated.append(($0.standardizedFileURL.path, $1?.standardizedFileURL.path)) }
        bar.editorField.stringValue = tree.url("folder").path
        press(#selector(NSResponder.insertNewline(_:)), in: bar)
        await bar.suggesting?.value
        #expect(navigated.count == 1 && navigated[0].0 == tree.url("folder").standardizedFileURL.path && navigated[0].1 == nil)
        bar.beginEditing()
        bar.editorField.stringValue = tree.url("file.txt").path
        press(#selector(NSResponder.insertNewline(_:)), in: bar)
        await bar.suggesting?.value
        #expect(navigated.count == 2 && navigated[1].0 == tree.root.standardizedFileURL.path
                && navigated[1].1 == tree.url("file.txt").standardizedFileURL.path)
        // Typed on while the disk was asked: the answer was for older text.
        bar.beginEditing()
        bar.editorField.stringValue = tree.url("folder").path
        press(#selector(NSResponder.insertNewline(_:)), in: bar)
        let pending = bar.suggesting
        bar.editorField.stringValue = tree.url("fold").path
        await pending?.value
        #expect(navigated.count == 2 && bar.isEditing)
        #expect(tree.snapshot() == ["file.txt", "folder/", "start/"])
    }

    @Test func tabCompletesToTheOnlyFolderThatMatches() async throws {
        let tree = try TestTree("start/", "Documents/", "Downloads/", "Desktop/")
        let environment = try IndependentEnvironment()
        let bar = pathBar(environment, at: tree.url("start"))
        bar.editorField.stringValue = tree.root.path + "/Doc"
        press(#selector(NSResponder.insertTab(_:)), in: bar)
        await bar.suggesting?.value
        #expect(bar.editorField.stringValue.hasSuffix("/Documents/"))
        #expect(tree.snapshot() == ["Desktop/", "Documents/", "Downloads/", "start/"])
    }
}
