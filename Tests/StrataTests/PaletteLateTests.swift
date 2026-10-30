import AppKit
import Testing
@testable import Strata

/// ⌘K looks up a typed path, and `github/acme`-style paths, away from the main thread: they join the results when
/// they arrive, and the search ends once they have.
@MainActor struct PaletteLateTests {
    @Test func typedPathsAndPathLookupsArriveFromAwayFromTheMainThread() async throws {
        let tree = try TestTree("Projects/strata/", "note.txt")
        let ranker = PaletteRanker()
        ranker.goToPath = { _ in }
        ranker.lateItems = { query in
            guard PathQuery.isPathQuery(query) else { return [] }
            return await PathQuery.resolveOffMain(query, roots: [tree.root], visited: []).map { hit in
                PaletteItem(title: hit.url.lastPathComponent, subtitle: "", icon: NSImage(), kind: .folder,
                            fixedScore: hit.score, url: hit.url) {}
            }
        }
        var kept: String?
        ranker.lateArrived = { kept = $0 }
        ranker.rank(tree.url("note.txt").path)
        #expect(ranker.results.isEmpty && ranker.pathLookup != nil)
        await ranker.pathLookup?.value
        await ranker.late?.value
        #expect(ranker.results.first?.item.kind == .path)
        #expect(ranker.results.first?.item.url?.path == tree.url("note.txt").path)
        // The typed path arrives selected: Return goes there.
        #expect(kept == ranker.results.first?.item.title)
        #expect(!ranker.isSearching && ranker.pathLookup == nil)
        // A path that isn't there offers nothing to go to.
        ranker.rank(tree.url("missing").path)
        await ranker.pathLookup?.value
        #expect(!ranker.results.contains { $0.item.kind == .path })
        ranker.rank("proj/str")
        await ranker.late?.value
        #expect(ranker.results.contains { $0.item.url?.lastPathComponent == "strata" })
        #expect(!ranker.isSearching)
        #expect(tree.snapshot() == ["Projects/", "Projects/strata/", "note.txt"])
    }
}
