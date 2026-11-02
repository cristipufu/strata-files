import Foundation
import Testing
@testable import StrataIndex

struct PathSearchRankingTests {
    private func store(includeUnicode: Bool = true) -> IndexStore {
        let index = IndexStore()
        index.write { store in
            let root = store.addRoot(path: "/synthetic", mtime: 0)
            func folder(_ name: String, in parent: Int32) -> Int32 {
                let bytes = Array(name.utf8)
                let item = ScannedItem(nameOffset: 0, nameLength: bytes.count, isDirectory: true, isPackage: false,
                    isSymlink: false, isHidden: false, isMountPoint: false, size: 0, mtime: 0)
                return bytes.withUnsafeBytes { store.appendChildren([item], nameBuffer: $0, of: parent).lowerBound }
            }
            let github = folder("GitHub", in: root)
            let other = folder("strata-other", in: github)
            _ = folder("Sources", in: other)
            let skipped = folder("unrelated", in: github)
            let gapped = folder("strata", in: skipped)
            _ = folder("Sources", in: gapped)
            let partial = folder("strata", in: github)
            _ = folder("Sources-backup", in: partial)
            let docs = folder("Documents", in: root)
            let exactGitHub = folder("GitHub", in: docs)
            let exactStrata = folder("strata", in: exactGitHub)
            _ = folder("Sources", in: exactStrata)
            _ = folder("sources", in: exactStrata)
            if includeUnicode {
                let accented = folder("GítHüb", in: root)
                let unicode = folder("stratá", in: accented)
                _ = folder("Sources", in: unicode)
            }
        }
        return index
    }

    @Test func anExactContiguousPathRanksAheadOfShallowerSubstringsAndGappedAncestors() {
        let result = IndexSearch.run(IndexQuery.parse("github/strata/sources"), in: store(includeUnicode: false), limit: 30)
        #expect(result.hits.first?.path == "/synthetic/Documents/GitHub/strata/Sources")
        #expect(Set(result.hits.prefix(2).map(\.path)) == ["/synthetic/Documents/GitHub/strata/Sources",
                                                          "/synthetic/Documents/GitHub/strata/sources"])
        #expect(result.total == 5)
    }

    @Test func exactPathRankingPreservesUnicodeFoldingAndTheFinalComponentsCaseRule() {
        let result = IndexSearch.run(IndexQuery.parse("github/strata/Sources case:"), in: store(), limit: 30)
        #expect(Set(result.hits.prefix(2).map(\.path)) == ["/synthetic/Documents/GitHub/strata/Sources", "/synthetic/GítHüb/stratá/Sources"])
        #expect(!result.hits.contains { $0.path == "/synthetic/Documents/GitHub/strata/sources" })
        #expect(result.total == 5)
    }
}
