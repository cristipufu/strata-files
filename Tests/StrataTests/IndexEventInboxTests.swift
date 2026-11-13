import CoreServices
import Foundation
import Testing
import os
@testable import StrataIndex

struct IndexEventInboxTests {
    @Test func aLossOutsideTheLaunchReplayIsReportedForALaterRecoveryNotRescanned() throws {
        let inbox = IndexEventInbox(), generation = UUID()
        let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped)
        let historyDone = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
        inbox.reset(generation: generation, roots: ["/home", "/Applications"])
        #expect(inbox.append([.init(path: "/home", flags: lost, id: 10), .init(path: "/home/docs", flags: 0, id: 11)],
                             generation: generation))
        let live = try #require(inbox.take())
        #expect(live.loss != nil && live.invalidation == nil && Set(live.folders.keys) == ["/home/docs"])
        #expect(inbox.append([.init(path: "/home/docs", flags: 0, id: 12)], generation: generation))
        #expect(try #require(inbox.take()).loss == nil)

        inbox.reset(generation: generation, roots: ["/home", "/Applications"], waitingForHistory: true, replay: .scan)
        #expect(!inbox.append([.init(path: "/home", flags: lost, id: 20)], generation: generation))
        #expect(inbox.append([.init(path: "", flags: historyDone, id: 21)], generation: generation))
        let afterRebuild = try #require(inbox.take())
        #expect(afterRebuild.loss != nil && afterRebuild.historyDone)
        #expect(afterRebuild.invalidation == nil && afterRebuild.folders.isEmpty)
    }

    @Test func aLossSaysWhenItsFirstReportArrivedAndWhetherTheJournalHoldsTheEvents() throws {
        let clock = OSAllocatedUnfairLock<UInt64>(initialState: 500)
        let inbox = IndexEventInbox(now: { clock.withLock { $0 } }), generation = UUID()
        inbox.reset(generation: generation, roots: ["/home"])
        #expect(inbox.append([.lostEvents(under: "/home", id: 10)], generation: generation))
        clock.withLock { $0 = 900 }
        #expect(!inbox.append([.lostEvents(under: "/home", id: 11)], generation: generation))
        #expect(try #require(inbox.take()).loss == .init(arrived: 500))
        #expect(inbox.append([.lostEvents(under: "/home", id: 12), .lostEvents(under: "/home", id: 13, byKernel: true)],
                             generation: generation))
        #expect(try #require(inbox.take()).loss == .init(arrived: 900, journalIsIncomplete: true))
    }

    @Test func aRecoveryReplayReportsAnotherLossAndStillRebuildsPastItsEventLimit() throws {
        let inbox = IndexEventInbox(replayEventLimit: 3), generation = UUID()
        inbox.reset(generation: generation, roots: ["/fixture"], waitingForHistory: true, replay: .afterLoss)
        #expect(!inbox.append([.lostEvents(under: "/fixture", id: 1), .change("/fixture/docs", id: 2)], generation: generation))
        #expect(inbox.append([.historyDone(id: 3)], generation: generation))
        let replay = try #require(inbox.take())
        #expect(replay.loss != nil && replay.invalidation == nil && replay.historyDone)
        #expect(Set(replay.folders.keys) == ["/fixture/docs"])

        inbox.reset(generation: generation, roots: ["/fixture"], waitingForHistory: true, replay: .afterLoss)
        for index in 1...3 {
            #expect(!inbox.append([.change("/fixture/f-\(index)", id: UInt64(20 + index))], generation: generation))
        }
        #expect(inbox.append([.change("/fixture/f-4", id: 24)], generation: generation))
        #expect(try #require(inbox.take()).invalidation?.id == 24)
    }

    @Test func replayStaysBoundedUntilHistoryEndsAndLiveChangesThenFlowNormally() throws {
        let inbox = IndexEventInbox(folderLimit: 2), generation = UUID()
        inbox.reset(generation: generation, roots: ["/fixture"], waitingForHistory: true)
        for index in 0..<1000 {
            #expect(!inbox.append([.init(path: "/fixture/folder-\(index)", flags: 0, id: UInt64(index))], generation: generation))
            #expect(inbox.take() == nil)
        }
        #expect(inbox.append([.init(path: "", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone), id: 1000)], generation: generation))
        let replay = try #require(inbox.take())
        #expect(replay.historyDone && replay.lastID == 1000)
        #expect(replay.folders.count == 1 && replay.folders["/fixture"]?.isDeep == true)
        #expect(inbox.append([.init(path: "/fixture/next", flags: 0, id: 1001)], generation: generation))
        let live = try #require(inbox.take())
        #expect(!live.historyDone && live.folders.count == 1 && live.folders["/fixture/next"]?.isDeep == false)
    }

    @Test func anInvalidatedRootDoesNotWaitForAReplayThatMayNeverFinish() throws {
        let inbox = IndexEventInbox(), generation = UUID()
        inbox.reset(generation: generation, roots: ["/fixture"], waitingForHistory: true)
        #expect(inbox.append([.init(path: "/fixture", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged), id: 0)], generation: generation))
        #expect(try #require(inbox.take()).invalidation?.invalidatesIndex == true)

        inbox.reset(generation: generation, roots: ["/fixture"], waitingForHistory: true, replay: .launch)
        let dropFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped)
        #expect(inbox.append([.init(path: "/fixture", flags: dropFlags, id: 10)], generation: generation))
        #expect(try #require(inbox.take()).invalidation?.droppedEvents == true)

        inbox.reset(generation: generation, roots: ["/fixture"], waitingForHistory: true, replay: .scan)
        #expect(!inbox.append([.init(path: "/fixture", flags: dropFlags, id: 11)], generation: generation))
        #expect(inbox.take() == nil)
        #expect(inbox.append([.init(path: "", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone), id: 12)], generation: generation))
        let postRebuild = try #require(inbox.take())
        #expect(postRebuild.invalidation == nil && postRebuild.loss != nil && postRebuild.folders.isEmpty)
        #expect(inbox.append([.init(path: "/fixture", flags: dropFlags, id: 13)], generation: generation))
        let live = try #require(inbox.take())
        #expect(live.invalidation == nil && live.loss != nil)

        let budgeted = IndexEventInbox(replayEventLimit: 3)
        budgeted.reset(generation: generation, roots: ["/fixture"], waitingForHistory: true, replay: .launch)
        for index in 1...3 {
            #expect(!budgeted.append([.init(path: "/fixture/f-\(index)", flags: 0, id: UInt64(20 + index))], generation: generation))
        }
        #expect(budgeted.append([.init(path: "/fixture/f-4", flags: 0, id: 24)], generation: generation))
        #expect(try #require(budgeted.take()).invalidation?.id == 24)
    }

    @Test func aWideFolderBurstNeedsOnlyOneShallowListing() throws {
        let inbox = IndexEventInbox(folderLimit: 2), generation = UUID()
        inbox.reset(generation: generation, roots: ["/fixture"])
        for index in 0..<10_000 {
            _ = inbox.append([.init(path: "/fixture/wide/file-\(index)",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile), id: UInt64(index))], generation: generation)
        }
        let delivery = try #require(inbox.take())
        #expect(delivery.folders.count == 1)
        let refresh = try #require(delivery.folders["/fixture/wide"])
        #expect(!refresh.isDeep && refresh.names == nil)
        #expect(delivery.lastID == 9999)
    }

    @Test func excludedItemEventsNeverRefreshTheirParentOrHideLookalikes() throws {
        let inbox = IndexEventInbox(), generation = UUID()
        inbox.reset(generation: generation, roots: ["/fixture"], excluded: ["/fixture/private"])
        _ = inbox.append([
            .init(path: "/fixture/private/", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir), id: 1),
            .init(path: "/fixture/private/cache", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile), id: 2),
            .init(path: "/fixture/private-copy/file", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile), id: 3)
        ], generation: generation)
        let delivery = try #require(inbox.take())
        #expect(Set(delivery.folders.keys) == ["/fixture/private-copy"])
        #expect(delivery.lastID == 3)
        inbox.exclude([])
        _ = inbox.append([.init(path: "/fixture/private/cache", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile), id: 4)], generation: generation)
        #expect(try #require(inbox.take()).folders["/fixture/private"]?.names == ["cache"])
    }

    @Test func repeatedCallbacksShareOneDeliveryAndPreserveRecoveryFlags() throws {
        let inbox = IndexEventInbox(folderLimit: 2), generation = UUID()
        inbox.reset(generation: generation, roots: ["/fixture"])
        for index in 0..<1000 {
            let flags = index == 0 ? FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) : 0
            #expect(inbox.append([.init(path: "/fixture/folder", flags: flags, id: UInt64(index))], generation: generation) == (index == 0))
        }
        let delivery = try #require(inbox.take())
        #expect(delivery.generation == generation && delivery.folders.count == 1)
        #expect(delivery.folders["/fixture/folder"]?.isDeep == true && delivery.lastID == 999)
        #expect(inbox.take() == nil)
        #expect(inbox.append([.init(path: "/fixture/folder", flags: 0, id: 1000)], generation: generation))
    }

    @Test func anOverflowKeepsBoundedRootRecoveryAndHistoryCompletion() throws {
        let inbox = IndexEventInbox(folderLimit: 2), generation = UUID()
        inbox.reset(generation: generation, roots: ["/fixture", "/other"])
        _ = inbox.append([.init(path: "/fixture/deep/chain/notes/note.txt",
                                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile), id: 1)],
                         generation: generation)
        for index in 0..<1000 {
            _ = inbox.append([.init(path: "/fixture/work/run-\(index)/leaf", flags: 0, id: UInt64(index + 2))],
                             generation: generation)
        }
        _ = inbox.append([.init(path: "", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone), id: 1002)],
                         generation: generation)
        let delivery = try #require(inbox.take())
        #expect(delivery.folders.count == 2)
        #expect(delivery.folders["/fixture/work"]?.isDeep == true)
        #expect(delivery.folders["/fixture/deep/chain/notes"]?.names == ["note.txt"])
        #expect(delivery.folders["/fixture"] == nil && delivery.folders["/other"] == nil)
        #expect(delivery.folderEventIDs["/fixture/deep/chain/notes"] == 1)
        #expect(delivery.folderEventIDs["/fixture/work"] == 2)
        #expect(delivery.historyDone)
        #expect(delivery.lastID == 1002)

        for index in 0..<10 {
            _ = inbox.append([.init(path: "/fixture/top-\(index)", flags: 0, id: UInt64(index + 2000))],
                             generation: generation)
        }
        let rootDelivery = try #require(inbox.take())
        #expect(rootDelivery.folders.count == 1)
        #expect(rootDelivery.folders["/fixture"]?.isDeep == true && rootDelivery.folders["/other"] == nil)

        var tree = IndexRefreshTree()
        tree.insert("/fixture/deep/chain/notes", .files(["note.txt"]), eventID: 50)
        tree.insert("/fixture/work/run-1", .directory(deep: false), eventID: 30)
        tree.insert("/fixture/work/run-2", .directory(deep: false), eventID: 20)
        tree.collapse(roots: ["/fixture"], limit: 2)
        tree.insert("/fixture/work/run-3/leaf", .directory(deep: false), eventID: 10)
        #expect(tree.count == 2 && tree.folders["/fixture/work/run-3/leaf"] == nil)
        #expect(tree.folderEventIDs["/fixture/work"] == 10 && tree.minEventID == 10)
        tree.insert("/fixture", .directory(deep: true), eventID: 40)
        tree.insert("/fixture/extra", .directory(deep: false), eventID: 45)
        tree.collapse(roots: ["/fixture"], limit: 1)
        tree.insert("/fixture/work/run-4/leaf", .directory(deep: false), eventID: 5)
        #expect(tree.count == 1 && tree.folderEventIDs["/fixture"] == 5 && tree.minEventID == 5)
    }

    @Test func replacingAStreamRejectsOldCallbacksAndAnOverflowNeverLosesInvalidation() throws {
        let inbox = IndexEventInbox(folderLimit: 1), old = UUID(), current = UUID()
        inbox.reset(generation: old, roots: ["/old"])
        _ = inbox.append([.init(path: "/old/first", flags: 0, id: 1)], generation: old)
        inbox.reset(generation: current, roots: ["/new"])
        #expect(!inbox.append([.init(path: "/old/late", flags: 0, id: 2)], generation: old))
        #expect(inbox.take() == nil)
        #expect(inbox.append([.init(path: "/new/a", flags: 0, id: 3), .init(path: "/new/b", flags: 0, id: 4),
            .init(path: "/new", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged), id: 0)], generation: current))
        let delivery = try #require(inbox.take())
        #expect(delivery.invalidation?.invalidatesIndex == true)
        #expect(delivery.folders["/new"]?.isDeep == true)
        #expect(!delivery.folders.keys.contains { $0.hasPrefix("/old") })
    }
}
