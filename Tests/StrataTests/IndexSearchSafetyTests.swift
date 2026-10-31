import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

struct IndexSearchSafetyTests {
    @Test(arguments: [1, 254, 255, 256, 300])
    func deepPathQueriesKeepMatchingWithoutOverflow(_ depth: Int) {
        let store = IndexStore()
        store.write { store in
            var parent = store.addRoot(path: "/synthetic", mtime: 0)
            for index in 0...depth {
                let name = Array((index == depth ? "target.txt" : "a").utf8)
                let item = ScannedItem(nameOffset: 0, nameLength: name.count, isDirectory: index < depth,
                                       isPackage: false, isSymlink: false, isHidden: false, isMountPoint: false,
                                       size: 0, mtime: 0)
                parent = name.withUnsafeBytes { store.appendChildren([item], nameBuffer: $0, of: parent).lowerBound }
            }
        }
        let path = String(repeating: "a/", count: depth)
        let result = IndexSearch.run(IndexQuery.parse(path + "target"), in: store, limit: 10)
        #expect(result.total == 1)
        #expect(result.hits.first?.path.hasSuffix("/target.txt") == true)
        #expect(IndexSearch.run(IndexQuery.parse(path + "a/target"), in: store, limit: 10).total == 0)
        #expect(IndexSearch.run(IndexQuery.parse("in:a target"), in: store, limit: 10).total == 1)
    }
}
