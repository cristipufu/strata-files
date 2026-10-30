import AppKit
import Testing
import os
@testable import Strata

struct FolderNamesTests {
    /// The path bar, the title and a pane's header name a folder by its own name until Finder's is read away from the
    /// main thread; only names other than the folders' own are announced; a folder being read isn't read again; and a
    /// read that hangs (a server that stopped answering) holds up only that server's folders, which wait for it rather
    /// than take another thread.
    @Test func foldersGoByTheirOwnNamesUntilFindersAreRead() async throws {
        let hold = DispatchSemaphore(value: 0), holding = CancelFlag()
        let asked = OSAllocatedUnfairLock(initialState: [[String]]())
        let gone = URL(fileURLWithPath: "/Volumes/Gone/x"), docs = URL(fileURLWithPath: "/Volumes/Share/Docs")
        let alsoGone = URL(fileURLWithPath: "/Volumes/Gone/y")
        let inside = docs.appending(path: "a")
        let names = FolderNames { paths in
            asked.withLock { $0.append(paths.sorted()) }
            if paths.contains(gone.path) {
                holding.set()
                hold.wait()
            }
            return [gone.path: "x", alsoGone.path: "y", docs.path: "Documents", inside.path: "a"]
                .filter { paths.contains($0.key) }
        }
        let announced = OSAllocatedUnfairLock(initialState: [Set<String>]())
        let observer = NotificationCenter.default.addObserver(forName: .folderNamesRead, object: names, queue: nil) {
            note in
            let paths = note.userInfo?["paths"] as? Set<String> ?? []
            announced.withLock { $0.append(paths) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        #expect(names.name(gone) == "x")
        for _ in 0..<1000 where !holding.isSet { try await Task.sleep(for: .milliseconds(5)) }
        #expect(names.name(gone) == "x" && names.name(alsoGone) == "y")
        #expect(names.name(docs) == "Docs" && names.name(inside) == "a")
        for _ in 0..<1000 where names.name(docs) != "Documents" { try await Task.sleep(for: .milliseconds(5)) }
        #expect(names.name(docs) == "Documents")
        #expect(announced.withLock { $0 } == [[docs.path]])
        #expect(asked.withLock { $0 } == [[gone.path], [docs.path, inside.path]])
        hold.signal()
        await names.settled()
        #expect(asked.withLock { $0 } == [[gone.path], [docs.path, inside.path], [alsoGone.path]])
    }

    /// A pane's folder, read for the Inspector away from the main thread, is the one on show: going elsewhere drops
    /// the read for the folder left.
    @Test func aPanesFolderIsTheOneOnShow() async throws {
        let tree = try TestTree("left/", "shown/")
        let environment = try PreviewEnvironment(tree)
        let pane = Pane(location: tree.url("left"), services: environment.services)
        var shown: [URL?] = []
        pane.readFolderEntry(tree.url("left")) { shown.append(pane.folderEntry?.url) }
        await withCheckedContinuation { continuation in
            pane.readFolderEntry(tree.url("shown")) {
                shown.append(pane.folderEntry?.url)
                continuation.resume()
            }
        }
        #expect(shown.map { $0?.lastPathComponent } == ["shown"])
        pane.stopBackgroundWork()
        #expect(tree.snapshot().filter { !$0.hasPrefix("environment/") } == ["left/", "shown/"])
        withExtendedLifetime(environment) {}
    }
}
