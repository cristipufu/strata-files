import AppKit
import Testing
import os
@testable import Strata

struct FolderNamesTests {
    /// The path bar, the title and a pane's header name a folder by its own name until Finder's is read away from the
    /// main thread; only names other than the folders' own are announced, and folders asked about meanwhile are read
    /// next.
    @Test func foldersGoByTheirOwnNamesUntilFindersAreRead() async throws {
        let gate = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
        let asked = OSAllocatedUnfairLock(initialState: [[String]]())
        let names = FolderNames { paths in
            asked.withLock { $0.append(paths.sorted()) }
            await withCheckedContinuation { continuation in gate.withLock { $0 = continuation } }
            return ["/Volumes/Share/Docs": "Documents", "/Volumes/Share/Docs/a": "a"]
        }
        let announced = OSAllocatedUnfairLock(initialState: [Set<String>]())
        let observer = NotificationCenter.default.addObserver(forName: .folderNamesRead, object: names, queue: nil) {
            note in
            let paths = note.userInfo?["paths"] as? Set<String> ?? []
            announced.withLock { $0.append(paths) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        #expect(names.name(URL(fileURLWithPath: "/Volumes/Share/Docs")) == "Docs")
        #expect(names.name(URL(fileURLWithPath: "/Volumes/Share/Docs/a")) == "a")
        while gate.withLock({ $0 == nil }) { await Task.yield() }
        #expect(names.name(URL(fileURLWithPath: "/Volumes/Share/Later")) == "Later")
        gate.withLock { $0?.resume(); $0 = nil }
        while gate.withLock({ $0 == nil }) { await Task.yield() }
        #expect(names.name(URL(fileURLWithPath: "/Volumes/Share/Docs")) == "Documents")
        gate.withLock { $0?.resume(); $0 = nil }
        await names.task?.value
        #expect(asked.withLock { $0 } == [["/Volumes/Share/Docs", "/Volumes/Share/Docs/a"], ["/Volumes/Share/Later"]])
        #expect(announced.withLock { $0 } == [["/Volumes/Share/Docs"]])
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
