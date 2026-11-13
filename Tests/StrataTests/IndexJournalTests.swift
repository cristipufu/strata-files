import Foundation
import Testing
import os
@testable import StrataIndex

/// What changed while the index was not running can only be asked of the journal that recorded how far it had got.
struct IndexJournalTests {
    struct Launch: Sendable, CustomTestStringConvertible {
        var saved: [String]?
        var now: [String]?
        var scans: Bool
        var testDescription: String { "\(saved ?? ["none"]) then \(now ?? ["none"])" }
    }

    @Test(arguments: [
        Launch(saved: ["A"], now: ["A"], scans: false),
        Launch(saved: ["A"], now: ["B"], scans: true),
        Launch(saved: ["A"], now: nil, scans: true),
        Launch(saved: nil, now: nil, scans: true),
        Launch(saved: nil, now: ["A"], scans: true),
        Launch(saved: ["A", "B"], now: ["A"], scans: true),
    ])
    func aLaunchReplaysOnlyFromTheJournalItsIndexWasSavedWithAndScansOtherwise(_ launch: Launch) async throws {
        let tree = try TestTree(".state/", "docs/a.txt")
        let first = try await IndexWorkerFixture.start(tree, startEvents: { _, _ in true }, journal: { _ in launch.saved })
        // Added while the index was not running. No event names it here, so only a scan finds it.
        try tree.add(["docs/added.txt"])
        let relaunched = try await IndexWorkerFixture.start(tree, storage: first.config.storage,
                                                            startEvents: { _, _ in true }, journal: { _ in launch.now })
        let added = tree.url("docs/added.txt").path
        #expect((relaunched.currentStore.read { $0.lookup(added) } != nil) == launch.scans)
        #expect(relaunched.currentStore.read { $0.lookup(tree.url("docs/a.txt").path) } != nil)
        #expect(tree.text("docs/a.txt") == "docs/a.txt")
    }

    @Test func foldersOfAnOrdinaryDiskShareItsJournalAndOneWithoutAJournalOrAMissingFolderHasNone() throws {
        let tree = try TestTree("docs/a.txt")
        let journal = try #require(FSEventsStream.journal(for: [tree.root.path, tree.url("docs").path]))
        #expect(journal.count == 2 && journal[0] == journal[1] && UUID(uuidString: journal[0]) != nil)
        // Device files live on a volume of their own, which the system keeps no journal for.
        #expect(FSEventsStream.journal(for: ["/dev"]) == nil)
        #expect(FSEventsStream.journal(for: [tree.root.path, "/dev"]) == nil)
        #expect(FSEventsStream.journal(for: [tree.url("missing").path]) == nil)
        #expect(FSEventsStream.journal(for: []) == [])
        #expect(tree.text("docs/a.txt") == "docs/a.txt")
    }

    @Test func anIndexKeepsTheJournalItFollowsThroughAScanAndThroughLaterSaves() async throws {
        let tree = try TestTree(".state/", "docs/a.txt")
        let docs = tree.url("docs").path
        func launch(_ journal: String, over earlier: IndexWorkerFixture? = nil) async throws -> IndexWorkerFixture {
            try await IndexWorkerFixture.start(tree, storage: earlier?.config.storage, fastFlushInterval: 0.01,
                                               startEvents: { _, _ in true }, journal: { _ in [journal] })
        }
        let one = tree.url("docs/one.txt").path, two = tree.url("docs/two.txt").path
        let first = try await launch("A")
        // The journal was replaced: this launch scans, and saves its index with the new one.
        _ = try await launch("B", over: first)

        // So the next launch replays. A change it is told of is applied and saved.
        try tree.add(["docs/one.txt"])
        let replaying = try await launch("B", over: first)
        #expect(replaying.currentStore.read { $0.lookup(one) } == nil)
        replaying.worker.receive([.historyDone(id: replaying.eventID), .change(docs, id: replaying.eventID + 10)])
        try await replaying.poll { replaying.currentStore.read { $0.lookup(one) } != nil }
        await replaying.checkpoint()
        #expect(try replaying.savedEventID == replaying.eventID + 10)

        // That save kept the journal too, so the launch after it replays again.
        try tree.add(["docs/two.txt"])
        let again = try await launch("B", over: first)
        #expect(again.currentStore.read { $0.lookup(one) } != nil && again.currentStore.read { $0.lookup(two) } == nil)
        #expect(tree.text("docs/a.txt") == "docs/a.txt")
    }
}
