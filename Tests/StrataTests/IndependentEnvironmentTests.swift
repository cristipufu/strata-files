import Foundation
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel

struct IndependentEnvironmentTests {
    @Test func trashCleanupUsesTheInjectedHistoryAndOnlyItsOwnTreeUnderEitherPathSpelling() async throws {
        let environment = try IndependentEnvironment()
        let history = environment.services.transfers.history
        let first = try TestTree("source/item", "destination/item", "destination/keep")
        let second = try TestTree("source/item", "destination/item", "destination/keep")
        var originals: [(url: URL, identity: String)] = []
        defer {
            for original in originals { TestTree.removeFromTrash(original.url, matching: original.identity) }
            withExtendedLifetime(environment) {}
        }
        for tree in [first, second] {
            let job = environment.services.transfers.enqueue([tree.url("source/item")], to: tree.url("destination"),
                mode: .copy, options: .init(verify: false, clone: false), undo: nil, conflicts: .replace)
            await job.finished()
            try #require(job.state == .finished && job.failures.isEmpty)
            let entry = try #require(history.entries.last)
            let pair = try #require(entry.replaced.first)
            let identity = try #require(entry.identities[pair[1]])
            originals.append((URL(fileURLWithPath: pair[1]), identity))
            #expect(FileIdentity.matchesHistory(identity, at: pair[1]))
        }
        first.removeFromTrash(history: history)
        #expect(FileIdentity.read(originals[0].url.path) == nil)
        #expect(FileIdentity.read(originals[1].url.path) != nil)
        second.removeFromTrash(history: history)
        #expect(FileIdentity.read(originals[1].url.path) == nil)
        #expect(first.snapshot() == ["destination/", "destination/item", "destination/keep", "source/", "source/item"])
        #expect(second.snapshot() == first.snapshot())
    }
}
