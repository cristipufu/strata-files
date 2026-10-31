import Foundation
import Testing
@testable import Strata
@testable import StrataFiles

struct BrowserLoadingTests {
    private final class CapacityReads {
        struct Request {
            let folder: URL
            let reply: CheckedContinuation<Int64?, Never>
        }
        var requests: [Request] = []
        var started: CheckedContinuation<Request, Never>?
        func read(_ folder: URL) async -> Int64? {
            await withCheckedContinuation { reply in
                let request = Request(folder: folder, reply: reply)
                if let waiting = started { started = nil; waiting.resume(returning: request) }
                else { requests.append(request) }
            }
        }
        func next() async -> Request {
            if !requests.isEmpty { return requests.removeFirst() }
            return await withCheckedContinuation { started = $0 }
        }
    }

    private func reload(_ loading: BrowserLoading, capacityChanged: @escaping () -> Void = {}, receive: @escaping (Result<BrowserLoading.Delivery, Error>) -> Void = { _ in }) {
        loading.reload(showHidden: false, applications: .standard, scrollToTop: false, sortedBy: nil, receive: receive,
                       capacityChanged: capacityChanged)
    }

    @Test func refreshedFirstLoadsStillStartAtTopAndApplyingBelongsToThePresentation() async throws {
        let tree = try TestTree("a/one.txt", "b/two.txt")
        let reads = ControlledDirectoryReads()
        defer { reads.stop() }
        let loading = BrowserLoading(reader: reads.reader, capacity: { _ in nil })
        let entry = try #require(FileEntry(url: tree.url("a/one.txt")))
        var delivered: [BrowserLoading.Delivery] = []
        loading.navigate(to: tree.url("a"), newFolder: true)
        #expect(loading.isLoadingFolder && !loading.isLoaded)
        reload(loading, receive: { if let value = try? $0.get() { delivered.append(value) } })
        let first = try #require(loading.reads.task)
        let old = try await reads.request(0)
        reload(loading, receive: { if let value = try? $0.get() { delivered.append(value) } })
        let refresh = try #require(loading.reads.task)
        try await reads.request(1).finish(.success([entry]))
        await refresh.value
        #expect(!loading.isLoadingFolder && !loading.isLoaded)
        #expect(delivered.count == 1 && delivered.first?.fromTop == true)
        #expect(delivered.first?.entries == [entry])
        old.finish(.failure(CocoaError(.fileReadNoPermission)))
        await first.value
        #expect(loading.error == nil && delivered.count == 1)
        loading.applied()
        #expect(loading.isLoaded)
        loading.navigate(to: tree.url("a"), newFolder: false)
        reload(loading, receive: { if let value = try? $0.get() { delivered.append(value) } })
        let same = try #require(loading.reads.task)
        try await reads.request(2).finish(.success([entry]))
        await same.value
        #expect(delivered.last?.fromTop == false)
        loading.navigate(to: tree.url("b"), newFolder: true)
        reload(loading)
        let failed = try #require(loading.reads.task)
        try await reads.request(3).finish(.failure(CocoaError(.fileReadNoPermission)))
        await failed.value
        #expect(loading.isLoaded && !loading.isLoadingFolder && loading.error != nil)
        loading.showResults(loaded: false)
        #expect(!loading.isLoaded && loading.error == nil && !loading.isLoadingFolder)
        loading.showResults()
        #expect(loading.isLoaded)
        #expect(tree.snapshot() == ["a/", "a/one.txt", "b/", "b/two.txt"])
    }

    @Test func freeSpaceBelongsToTheCurrentFolderAndLateReadsCannotClearNewWork() async throws {
        let tree = try TestTree("a/", "b/")
        for oldFirst in [false, true] {
            let reads = ControlledDirectoryReads(), capacity = CapacityReads()
            defer { reads.stop() }
            var changes = 0
            let loading = BrowserLoading(reader: reads.reader, capacity: { await capacity.read($0) })
            loading.navigate(to: tree.url("a"), newFolder: true)
            reload(loading, capacityChanged: { changes += 1 })
            let first = try #require(loading.reads.task)
            try await reads.request(0).finish(.success([]))
            await first.value
            let oldWork = try #require(loading.capacityTask), old = await capacity.next()
            #expect(old.folder == tree.url("a"))
            loading.navigate(to: tree.url("b"), newFolder: true)
            reload(loading, capacityChanged: { changes += 1 })
            let second = try #require(loading.reads.task)
            try await reads.request(1).finish(.success([]))
            await second.value
            let newWork = try #require(loading.capacityTask), current = await capacity.next()
            #expect(current.folder == tree.url("b"))
            if oldFirst {
                old.reply.resume(returning: 100)
                await oldWork.value
                #expect(loading.availableCapacity == nil && loading.capacityTask != nil)
            }
            current.reply.resume(returning: 200)
            await newWork.value
            if !oldFirst { old.reply.resume(returning: 100); await oldWork.value }
            #expect(loading.availableCapacity == 200 && loading.capacityTask == nil && changes == 1)
            loading.navigate(to: tree.url("a"), newFolder: true)
            #expect(loading.availableCapacity == nil)
        }
        #expect(tree.snapshot() == ["a/", "b/"])
    }

    @Test func replacingTheFolderFromItsCompletionDoesNotLaunchObsoleteCapacityWork() async throws {
        let tree = try TestTree("folder/")
        let reads = ControlledDirectoryReads()
        defer { reads.stop() }
        let capacity = CapacityReads()
        let loading = BrowserLoading(reader: reads.reader, capacity: { await capacity.read($0) })
        loading.navigate(to: tree.root, newFolder: true)
        reload(loading, receive: { _ in loading.showResults() })
        let task = try #require(loading.reads.task)
        try await reads.request(0).finish(.success([]))
        await task.value
        let obsolete = loading.capacityTask
        #expect(obsolete == nil && loading.reads.task == nil)
        if let obsolete {
            let request = await capacity.next()
            request.reply.resume(returning: nil)
            await obsolete.value
        }
        #expect(tree.snapshot() == ["folder/"])
    }

    @Test func childReadsCoalesceByNodeAndRootRefreshCancelsTheirOwnership() async throws {
        let tree = try TestTree("folder/old.txt", "folder/new.txt")
        let reads = ControlledDirectoryReads()
        defer { reads.stop() }
        let loading = BrowserLoading(reader: reads.reader, capacity: { _ in nil })
        loading.navigate(to: tree.root, newFolder: true)
        let node = FileNode(entry: try #require(FileEntry(url: tree.url("folder"))))
        let entry = try #require(FileEntry(url: tree.url("folder/new.txt")))
        var deliveries: [[FileEntry]] = []
        let old = loading.loadChildren(of: node, showHidden: true, applications: .standard) { deliveries.append($0) }
        let oldRequest = try await reads.request(0)
        let duplicate = loading.loadChildren(of: node, showHidden: true, applications: .standard) { _ in Issue.record("Duplicate callback") }
        try #require(old == duplicate && oldRequest.showHidden)
        reload(loading)
        let root = try #require(loading.reads.task)
        try await reads.request(1).finish(.success([]))
        await root.value
        try #require(old.isCancelled)
        let new = loading.loadChildren(of: node, showHidden: false, applications: .standard) { deliveries.append($0) }
        let newRequest = try await reads.request(2)
        oldRequest.finish(.success([]))
        await old.value
        let repeated = loading.loadChildren(of: node, showHidden: false, applications: .standard) { _ in Issue.record("Old response cleared new work") }
        #expect(repeated == new && deliveries.isEmpty && !newRequest.showHidden)
        newRequest.finish(.success([entry]))
        await new.value
        #expect(deliveries == [[entry]])
        let replacement = FileNode(entry: node.entry)
        let a = loading.loadChildren(of: node, showHidden: false, applications: .standard) { deliveries.append($0) }
        let b = loading.loadChildren(of: replacement, showHidden: false, applications: .standard) { deliveries.append($0) }
        let ar = try await reads.request(3), br = try await reads.request(4)
        #expect(a != b)
        ar.finish(.failure(CocoaError(.fileReadNoPermission)))
        await a.value
        br.finish(.success([entry]))
        await b.value
        #expect(deliveries == [[entry], [], [entry]])
        #expect(tree.snapshot() == ["folder/", "folder/new.txt", "folder/old.txt"])
    }

    @Test func outstandingCapacityAndChildWorkDoNotRetainTheOwner() async throws {
        let tree = try TestTree("folder/")
        let reads = ControlledDirectoryReads(), capacity = CapacityReads()
        defer { reads.stop() }
        var loading: BrowserLoading? = BrowserLoading(reader: reads.reader, capacity: { await capacity.read($0) })
        weak let owner = loading
        loading?.navigate(to: tree.root, newFolder: true)
        var changes = 0
        reload(try #require(loading), capacityChanged: { changes += 1 })
        let root = try #require(loading?.reads.task)
        try await reads.request(0).finish(.success([]))
        await root.value
        let capacityWork = try #require(loading?.capacityTask)
        let capacityRequest = await capacity.next()
        let node = FileNode(entry: try #require(FileEntry(url: tree.url("folder"))))
        let child = try #require(loading).loadChildren(of: node, showHidden: false, applications: .standard) { _ in changes += 1 }
        let childRequest = try await reads.request(1)
        loading = nil
        #expect(owner == nil && capacityWork.isCancelled && child.isCancelled)
        capacityRequest.reply.resume(returning: 456)
        childRequest.finish(.success([]))
        await capacityWork.value
        await child.value
        #expect(changes == 0)
        #expect(tree.snapshot() == ["folder/"])
    }

    @Test func applyingResultsOrReleasingTheOwnerCancelsExpandedReads() async throws {
        let tree = try TestTree("folder/item.txt")
        for action in 0..<4 {
            let reads = ControlledDirectoryReads()
            defer { reads.stop() }
            var loading: BrowserLoading? = BrowserLoading(reader: reads.reader, capacity: { _ in nil })
            weak let owner = loading
            let node = FileNode(entry: try #require(FileEntry(url: tree.url("folder"))))
            var completions = 0
            let work = try #require(loading).loadChildren(of: node, showHidden: false, applications: .standard) { _ in completions += 1 }
            let request = try await reads.request(0)
            switch action {
            case 0: loading?.applied()
            case 1: loading?.showResults()
            case 2: loading?.showResults(loaded: false)
            default: loading = nil
            }
            request.finish(.success([try #require(FileEntry(url: tree.url("folder/item.txt")))]))
            await work.value
            #expect(completions == 0 && work.isCancelled)
            if action == 3 { #expect(owner == nil) }
        }
        #expect(tree.snapshot() == ["folder/", "folder/item.txt"])
    }
}
