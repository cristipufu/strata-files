import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct CopyProvidersTests {
    private nonisolated struct Event: Equatable, Sendable {
        let provider: String
        let action: String
        let urls: [URL]
        var limit: Int64? = nil
    }

    private actor Calls {
        var events: [Event] = []
        func add(_ event: Event) { events.append(event) }
    }

    private nonisolated enum Failure: Error { case unavailable }

    /// A third provider with a different namespace, without any server or container implementation behind it.
    private nonisolated struct Provider: CopyProvider {
        let name: String
        let calls: Calls
        var fails: String? = nil
        var folder: URL? = nil
        var root: URL { folder ?? URL(fileURLWithPath: "/strata-provider-fixture/" + name) }
        func contains(_ url: URL) -> Bool { url.path == root.path || url.path.hasPrefix(root.path + "/") }
        func isPlaceholder(_ url: URL) -> Bool { url.pathExtension == "pending" }
        func refresh(_ folder: URL) async { await record("refresh", [folder]) }
        func invalidate(_ folder: URL) async { await record("invalidate", [folder]) }
        func reveal(_ url: URL) async -> Bool { await record("reveal", [url]); return true }
        func fetch(_ urls: [URL]) async throws {
            await record("fetch", urls)
            if fails == "fetch" { throw Failure.unavailable }
        }
        func fetchSelection(_ urls: [URL], limit: Int64) async {
            await calls.add(Event(provider: name, action: "selection", urls: urls, limit: limit))
        }
        func prepareForCopying(_ urls: [URL]) async throws {
            await record("copy", urls)
            if fails == "copy" { throw Failure.unavailable }
        }
        func message(for error: Error, about url: URL) -> String { "\(name): unavailable" }
        func displayPath(_ url: URL) -> String? { "\(name):\(url.lastPathComponent)" }
        func sourceName(_ url: URL) -> String? { name }
        private func record(_ action: String, _ urls: [URL]) async {
            await calls.add(Event(provider: name, action: action, urls: urls))
        }
    }

    @Test func theLiveFacadeRecognizesBothCopyFamiliesWithoutClaimingTheirNeighbors() {
        for root in [RemoteCopies.root, ContainerCopies.root] {
            for url in [root, root.appending(path: "unregistered-copy/file")] {
                #expect(CopyProviders.live.contains(url))
            }
            let neighbor = root.deletingLastPathComponent().appending(path: root.lastPathComponent + "-other/file")
            #expect(!CopyProviders.live.contains(neighbor))
        }
    }

    /// A folder copied out of a server or a container is searched for items not fetched yet away from the main
    /// thread, as deep as it goes and only inside the provider's copies.
    @Test func placeholdersAreFoundAnywhereInsideACopy() async throws {
        let tree = try TestTree("copy/", "copy/sub/", "copy/sub/deep.pending", "copy/plain/", "copy/plain/file.txt",
                                "outside.pending")
        let providers = CopyProviders([Provider(name: "tree", calls: Calls(), folder: tree.url("copy"))])
        #expect(await providers.containsPlaceholderOffMain(in: [tree.url("copy")]))
        #expect(!(await providers.containsPlaceholderOffMain(in: [tree.url("copy/plain")])))
        #expect(!(await providers.containsPlaceholderOffMain(in: [tree.url("outside.pending")])))
        #expect(providers.containsPlaceholder(in: [tree.url("copy/sub")]))
        #expect(tree.snapshot() == ["copy/", "copy/plain/", "copy/plain/file.txt", "copy/sub/", "copy/sub/deep.pending",
                                    "outside.pending"])
    }

    @Test func everyReadCapabilityRoutesToAnAdditionalProvider() async throws {
        let calls = Calls()
        let third = Provider(name: "third", calls: calls)
        let providers = CopyProviders([Provider(name: "server", calls: calls), Provider(name: "container", calls: calls), third])
        let item = third.root.appending(path: "file.pending")
        #expect(providers.contains(item) && providers.isPlaceholder(item))
        #expect(!providers.isPlaceholder(third.root.appending(path: "file.txt")))
        #expect(providers.sourceName(item) == "third")
        #expect(providers.displayPath(item) == "third:file.pending")
        #expect(providers.message(for: Failure.unavailable, about: item) == "third: unavailable")
        await providers.refresh(third.root)
        await providers.invalidate(third.root)
        #expect(await providers.reveal(item))
        try await providers.fetch([item])
        try await providers.prepareForCopying([item])
        await providers.fetchSelection([item], limit: 73)
        #expect(await calls.events == [
            Event(provider: "third", action: "refresh", urls: [third.root]),
            Event(provider: "third", action: "invalidate", urls: [third.root]),
            Event(provider: "third", action: "reveal", urls: [item]),
            Event(provider: "third", action: "fetch", urls: [item]),
            Event(provider: "third", action: "copy", urls: [item]),
            Event(provider: "third", action: "selection", urls: [item], limit: 73),
        ])
    }

    @Test func mixedReadsKeepExactURLsAndOnlyOneOwnerPerItem() async throws {
        let calls = Calls()
        let first = Provider(name: "first", calls: calls), second = Provider(name: "second", calls: calls)
        // A later provider claiming an overlapping namespace must not fetch the same item twice.
        let providers = CopyProviders([first, second, first])
        let a = first.root.appending(path: "a"), b = first.root.appending(path: "a/b"), c = second.root.appending(path: "a")
        let local = URL(fileURLWithPath: "/strata-provider-fixture/first-lookalike/a")
        let input = [c, a, local, b]
        try await providers.fetch(input)
        try await providers.prepareForCopying(input)
        #expect(await calls.events == [
            Event(provider: "first", action: "fetch", urls: [a, b]),
            Event(provider: "second", action: "fetch", urls: [c]),
            Event(provider: "first", action: "copy", urls: [a, b]),
            Event(provider: "second", action: "copy", urls: [c]),
        ])
    }

    @Test func failedFetchesAndCopyPreparationPropagateBeforeStartingAnotherProvider() async throws {
        for action in ["fetch", "copy"] {
            let calls = Calls()
            let first = Provider(name: "first", calls: calls, fails: action), second = Provider(name: "second", calls: calls)
            let providers = CopyProviders([first, second])
            let a = first.root.appending(path: "a"), b = second.root.appending(path: "b")
            if action == "fetch" {
                await #expect(throws: Failure.self) { try await providers.fetch([b, a]) }
            } else {
                await #expect(throws: Failure.self) { try await providers.prepareForCopying([b, a]) }
            }
            #expect(await calls.events == [Event(provider: "first", action: action, urls: [a])])
        }
    }

    @Test func selectionPrefetchKeepsItsSingleProviderBudget() async {
        let calls = Calls()
        let first = Provider(name: "first", calls: calls), second = Provider(name: "second", calls: calls)
        let providers = CopyProviders([first, second])
        let a = first.root.appending(path: "a"), b = second.root.appending(path: "b")
        await providers.fetchSelection([b, a], limit: 123)
        await providers.fetchSelection([b], limit: 456)
        #expect(await calls.events == [
            Event(provider: "first", action: "selection", urls: [a], limit: 123),
            Event(provider: "second", action: "selection", urls: [b], limit: 456),
        ])
    }

    @Test func ordinaryURLsAndIndependentProviderSetsStaySeparate() async throws {
        let calls = Calls()
        let provider = Provider(name: "known", calls: calls)
        let configured = CopyProviders([provider]), empty = CopyProviders([])
        let local = URL(fileURLWithPath: "/strata-provider-fixture/unknown/file.pending")
        let owned = provider.root.appending(path: "file.pending")
        #expect(configured.contains(owned) && !empty.contains(owned))
        for (providers, url) in [(configured, local), (empty, owned)] {
            #expect(!providers.contains(url) && !providers.isPlaceholder(url))
            #expect(providers.displayPath(url) == nil && providers.sourceName(url) == nil)
            #expect(providers.message(for: Failure.unavailable, about: url) == Failure.unavailable.localizedDescription)
            await providers.refresh(url)
            await providers.invalidate(url)
            #expect(await providers.reveal(url) == false)
            try await providers.fetch([url])
            try await providers.prepareForCopying([url])
            await providers.fetchSelection([url], limit: 100)
            try await providers.fetch([])
            try await providers.prepareForCopying([])
            await providers.fetchSelection([], limit: 100)
        }
        #expect(await calls.events.isEmpty)
    }
}
