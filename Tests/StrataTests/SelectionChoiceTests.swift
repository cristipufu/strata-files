import Foundation
import Testing
@testable import Strata
@testable import StrataModel

/// Which selected items Download Now and Quick Look take, decided from what the listing read, without the disk.
@MainActor struct SelectionChoiceTests {
    private func entries(_ tree: TestTree, _ names: [String]) throws -> [FileEntry] {
        try names.map { try #require(FileEntry(url: tree.url($0))) }
    }

    @Test func downloadNowTakesICloudItemsAndOtherProvidersFilesOnly() throws {
        let tree = try TestTree("file.txt", "folder/", "file link -> file.txt", "folder link -> folder", "local.txt")
        let selection = try entries(tree, ["file.txt", "folder", "file link", "folder link", "local.txt"])
        let provider = BrowserViewController.downloadable(selection) { $0.lastPathComponent == "local.txt" ? nil : .providerOnly }
        #expect(provider.map(\.lastPathComponent) == ["file.txt"])
        let iCloud = BrowserViewController.downloadable(selection) { $0.lastPathComponent == "local.txt" ? nil : .cloudOnly }
        #expect(iCloud.map(\.lastPathComponent) == ["file.txt", "folder", "file link", "folder link"])
        #expect(tree.snapshot() == ["file link -> file.txt", "file.txt", "folder link -> folder", "folder/", "local.txt"])
    }

    @Test func quickLookTakesFilesAndLinksButNotFolders() throws {
        let tree = try TestTree("file.txt", "folder/", "Tool.app/Contents/", "folder link -> folder")
        let chosen = BrowserViewController.quickLookItems(try entries(tree, ["file.txt", "folder", "Tool.app", "folder link"]))
        #expect(chosen.map(\.lastPathComponent) == ["file.txt", "folder link"])
        #expect(tree.snapshot() == ["Tool.app/", "Tool.app/Contents/", "file.txt", "folder link -> folder", "folder/"])
    }
}
