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

struct HistoryDecodingSafetyTests {
    @Test(arguments: ["moves", "replacements"])
    func malformedHistoryMovesAreRejectedBeforeUndo(_ key: String) throws {
        let tree = try TestTree("a", "b")
        let entry = OperationLog.Entry(name: "Move", kind: .move,
            moves: [HistoryMove(from: tree.url("a"), to: tree.url("b"))])
        let encoded = try JSONEncoder().encode(entry)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let invalid: [Any] = [[], ["source"], ["from": tree.url("a").path], ["to": tree.url("b").path],
                              ["from": 7, "to": tree.url("b").path]]
        for value in invalid {
            object[key] = [value]
            let malformed = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(OperationLog.Entry.self, from: malformed) }
        }
        #expect(tree.snapshot() == ["a", "b"])
    }

    @Test func historyRequiresEveryCurrentRecordField() throws {
        let tree = try TestTree("a", "b")
        let entry = OperationLog.Entry(name: "Move", kind: .move,
            moves: [HistoryMove(from: tree.url("a"), to: tree.url("b"))])
        let encoded = try JSONEncoder().encode(entry)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let decoded = try JSONDecoder().decode(OperationLog.Entry.self, from: encoded)
        #expect(decoded.sameItems(as: entry) && !decoded.undone)
        for key in ["id", "date", "name", "kind", "moves", "created", "replacements", "containers", "ownership", "undone"] {
            var missing = object
            missing[key] = nil
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(OperationLog.Entry.self, from: JSONSerialization.data(withJSONObject: missing))
            }
        }
        #expect(tree.snapshot() == ["a", "b"])
    }

    @Test func invalidRecordsDoNotHideValidNeighborsOrRewriteHistory() throws {
        let tree = try TestTree("a", "b")
        var first = OperationLog.Entry(name: "Move", kind: .move,
                                       moves: [HistoryMove(from: tree.url("a"), to: tree.url("b"))])
        first.date = Date(timeIntervalSince1970: 1000)
        first.undone = true
        first.changed = Date(timeIntervalSince1970: 1234)
        var last = OperationLog.Entry(name: "Copy", kind: .create, created: [tree.url("b").path],
                                      replacements: [HistoryMove(from: tree.url("a"), to: tree.url("b"))])
        last.date = Date(timeIntervalSince1970: 2000)
        let valid = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode([first, last])) as? [[String: Any]])
        var invalid = valid[0]
        invalid["moves"] = [["from": tree.url("a").path]]
        var missingOwnership = valid[1]
        missingOwnership["ownership"] = nil
        let values: [Any] = [NSNull(), valid[0], invalid, "bad", [], 42, missingOwnership, valid[1], invalid]
        let file = tree.url("history.sealed")
        try SecureStorage.Context.shared.write(JSONSerialization.data(withJSONObject: values), to: file)
        let original = try Data(contentsOf: file)
        let decoded = OperationLog.readEntries(from: file, storage: .shared)
        #expect(decoded.count == 2)
        #expect(decoded.map(\.id) == [first.id, last.id])
        if decoded.count == 2 {
            // Compare all encoded fields, including identities and undo state, not just the names.
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            #expect(try encoder.encode(decoded[0]) == encoder.encode(first))
            #expect(try encoder.encode(decoded[1]) == encoder.encode(last))
        }
        #expect(try Data(contentsOf: file) == original)
        #expect(tree.snapshot() == ["a", "b", "history.sealed"])
    }

    @Test func unreadableHistoryNeverFallsBackToUnauthenticatedRecords() throws {
        let tree = try TestTree()
        let file = tree.url("history.sealed")
        let valid = try JSONEncoder().encode([OperationLog.Entry(name: "Copy", kind: .create)])
        for malformed in [Data("{}".utf8), Data(valid.dropLast())] {
            try SecureStorage.Context.shared.write(malformed, to: file)
            let original = try Data(contentsOf: file)
            #expect(OperationLog.readEntries(from: file, storage: .shared).isEmpty)
            #expect(try Data(contentsOf: file) == original)
        }
        try SecureStorage.Context.shared.write(valid, to: file)
        var damaged = try Data(contentsOf: file)
        damaged[damaged.count - 1] ^= 1
        try damaged.write(to: file)
        #expect(OperationLog.readEntries(from: file, storage: .shared).isEmpty)
        #expect(try Data(contentsOf: file) == damaged)
        #expect(OperationLog.readEntries(from: tree.url("missing.sealed"), storage: .shared).isEmpty)
        // Plain JSON is not authenticated History, even when it contains well-formed records.
        try valid.write(to: file)
        #expect(OperationLog.readEntries(from: file, storage: .shared).isEmpty)
        #expect(try Data(contentsOf: file) == valid)
        #expect(tree.snapshot() == ["history.sealed"])
    }
}
