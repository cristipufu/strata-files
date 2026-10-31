import Foundation
import Testing
@testable import Strata
@testable import StrataFiles

struct HistoryDecodingSafetyTests {
    @Test(arguments: ["pairs", "replaced"], [0, 1, 3])
    func malformedHistoryPairsAreRejectedBeforeUndo(_ key: String, _ count: Int) throws {
        let tree = try TestTree("a", "b")
        let entry = OperationLog.Entry(name: "Move", kind: .move, pairs: [[tree.url("a").path, tree.url("b").path]])
        let encoded = try JSONEncoder().encode(entry)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object[key] = [Array(repeating: tree.url("a").path, count: count)]
        let malformed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(OperationLog.Entry.self, from: malformed) }
        #expect(tree.snapshot() == ["a", "b"])
    }

    @Test func validAndOlderHistoryRecordsKeepTheirPairs() throws {
        let tree = try TestTree("a", "b")
        let entry = OperationLog.Entry(name: "Move", kind: .move, pairs: [[tree.url("a").path, tree.url("b").path]])
        let encoded = try JSONEncoder().encode(entry)
        var old = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["replaced", "containers", "identities", "changed", "undone"] { old[key] = nil }
        for data in [encoded, try JSONSerialization.data(withJSONObject: old)] {
            let decoded = try JSONDecoder().decode(OperationLog.Entry.self, from: data)
            #expect(decoded.pairs == entry.pairs)
            #expect(decoded.replaced.isEmpty)
            #expect(!decoded.undone)
        }
        #expect(tree.snapshot() == ["a", "b"])
    }

    @Test func invalidRecordsDoNotHideValidNeighborsOrRewriteHistory() throws {
        let tree = try TestTree("a", "b")
        var first = OperationLog.Entry(name: "Move", kind: .move,
                                       pairs: [[tree.url("a").path, tree.url("b").path]])
        first.date = Date(timeIntervalSince1970: 1000)
        first.undone = true
        first.changed = Date(timeIntervalSince1970: 1234)
        var last = OperationLog.Entry(name: "Copy", kind: .create, created: [tree.url("b").path],
                                      replaced: [[tree.url("a").path, tree.url("b").path]])
        last.date = Date(timeIntervalSince1970: 2000)
        let valid = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode([first, last])) as? [[String: Any]])
        var invalid = valid[0]
        invalid["pairs"] = [[tree.url("a").path]]
        var older = valid[1]
        for key in ["replaced", "containers", "identities", "changed", "undone"] { older[key] = nil }
        let olderID = UUID()
        older["id"] = olderID.uuidString
        let values: [Any] = [NSNull(), valid[0], invalid, "bad", [], 42, older, valid[1], invalid]
        let file = tree.url("history.sealed")
        try SecureStorage.write(JSONSerialization.data(withJSONObject: values), to: file)
        let original = try Data(contentsOf: file)
        let decoded = OperationLog.readEntries(from: file)
        #expect(decoded.count == 3)
        #expect(decoded.map(\.id) == [first.id, olderID, last.id])
        if decoded.count == 3 {
            // Compare all encoded fields, including identities and undo state, not just the names.
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            #expect(try encoder.encode(decoded[0]) == encoder.encode(first))
            #expect(try encoder.encode(decoded[2]) == encoder.encode(last))
            #expect(decoded[1].identities.isEmpty && !decoded[1].undone)
        }
        #expect(try Data(contentsOf: file) == original)
        #expect(tree.snapshot() == ["a", "b", "history.sealed"])
    }

    @Test func unreadableHistoryNeverFallsBackToUnauthenticatedRecords() throws {
        let tree = try TestTree()
        let file = tree.url("history.sealed")
        let valid = try JSONEncoder().encode([OperationLog.Entry(name: "Copy", kind: .create)])
        for malformed in [Data("{}".utf8), Data(valid.dropLast())] {
            try SecureStorage.write(malformed, to: file)
            let original = try Data(contentsOf: file)
            #expect(OperationLog.readEntries(from: file).isEmpty)
            #expect(try Data(contentsOf: file) == original)
        }
        try SecureStorage.write(valid, to: file)
        var damaged = try Data(contentsOf: file)
        damaged[damaged.count - 1] ^= 1
        try damaged.write(to: file)
        #expect(OperationLog.readEntries(from: file).isEmpty)
        #expect(try Data(contentsOf: file) == damaged)
        #expect(OperationLog.readEntries(from: tree.url("missing.sealed")).isEmpty)
        // Plain JSON is not authenticated History, even when it contains well-formed records.
        try valid.write(to: file)
        #expect(OperationLog.readEntries(from: file).isEmpty)
        #expect(try Data(contentsOf: file) == valid)
        #expect(tree.snapshot() == ["history.sealed"])
    }
}
