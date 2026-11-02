import AppKit
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataQueue

struct HistoryRecordTests {
    @Test func recordsSaveReopenAndRefuseMissingOwnership() async throws {
        let tree = try TestTree("a.txt", "ab.txt", "other/a.txt", "untracked.txt")
        let env = try IndependentEnvironment()
        let history = env.services.transfers.history
        let renamed = try await env.services.files.rename(tree.url("a.txt"), to: "b.txt", undo: nil)
        history.recordCreate("Copy", [tree.url("untracked.txt")], fileIdentities: [:])
        OperationLog.waitForWrites()
        let file = env.storage.url("history.sealed")
        let original = try Data(contentsOf: file)
        let reopened = OperationLog(storage: env.storage, copies: env.services.copies)
        let recorded = try #require(reopened.entries.first)
        let refused = try #require(reopened.entries.last)
        let key = try #require(OperationLog.identity(renamed.path))
        #expect(recorded.moves == [HistoryMove(from: tree.url("a.txt"), to: renamed)])
        #expect(recorded.expectation(at: renamed.path) == .recorded(key))
        #expect(refused.expectation(at: tree.url("untracked.txt").path) == .unavailable)
        #expect(await !reopened.canUndo(refused))
        var missing = recorded
        missing.ownership = [:]
        #expect(missing.expectation(at: renamed.path) == .unavailable)
        #expect(await !reopened.canUndo(missing))
        #expect(try Data(contentsOf: file) == original)
        try await reopened.undo(recorded, undoManager: nil)
        #expect(tree.snapshot() == ["a.txt", "ab.txt", "other/", "other/a.txt", "untracked.txt"])
    }

    @Test func unsupportedHistoryIsIgnoredOnUpgradeWithoutChangingFiles() async throws {
        let tree = try TestTree("a.txt", "ab.txt", "other/a.txt", "link -> a.txt")
        let before = tree.snapshot()
        let env = try IndependentEnvironment()
        let unsupported: [String: Any] = [
            "id": UUID().uuidString, "date": 1000, "name": "Rename", "kind": "move",
            "pairs": [[tree.url("a.txt").path, tree.url("b.txt").path]],
            "created": [], "replaced": [], "containers": [], "identities": [:], "undone": false,
        ]
        let file = env.storage.url("history.sealed")
        try env.storage.write(JSONSerialization.data(withJSONObject: [unsupported]), to: file)
        let bytes = try Data(contentsOf: file)
        let reopened = OperationLog(storage: env.storage, copies: env.services.copies)
        #expect(reopened.entries.isEmpty)
        _ = NSApplication.shared
        let panel = HistoryWindowController(history: reopened, undoManager: nil)
        defer { panel.close() }
        await panel.checking?.value
        #expect(panel.numberOfRows(in: NSTableView()) == 0)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(tree.snapshot() == before)
    }

    @Test(arguments: [["", "destination"], ["source", ""]])
    func anEmptyHistoryEndpointIsRejected(_ pair: [String]) throws {
        let tree = try TestTree("a", "ab")
        let entry = OperationLog.Entry(name: "Move", kind: .move,
            moves: [HistoryMove(from: tree.url("a"), to: tree.url("b"))], fileIdentities: [:])
        let data = try JSONEncoder().encode(entry)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["moves", "replacements"] {
            var invalid = object
            invalid[key] = [["from": pair[0], "to": pair[1]]]
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(OperationLog.Entry.self, from: JSONSerialization.data(withJSONObject: invalid))
            }
        }
        #expect(tree.snapshot() == ["a", "ab"])
    }
}
