import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

struct StorageContextTests {
    private let key = SymmetricKey(data: Data(repeating: 7, count: 32))

    private func context(_ tree: TestTree, _ folder: String, key: SymmetricKey?) -> SecureStorage.Context {
        SecureStorage.Context(directory: tree.url(folder), caches: tree.url(folder + "/Caches"), key: key)
    }

    @Test func contextsKeepIndependentKeysAndHistory() throws {
        let tree = try TestTree("first/", "second/", "a.txt", "b.txt")
        let first = context(tree, "first", key: key)
        let second = context(tree, "second", key: SymmetricKey(data: Data(repeating: 8, count: 32)))
        let a = OperationLog(storage: first, copies: .live)
        let b = OperationLog(storage: second, copies: .live)
        let firstID = try #require(a.recordCreate("Copy", [tree.url("a.txt")]))
        let secondID = try #require(b.recordCreate("Copy", [tree.url("b.txt")]))
        #expect(a.entries.map(\.id) == [firstID])
        #expect(b.entries.map(\.id) == [secondID])
        #expect(OperationLog(storage: first, copies: .live).entries.map(\.id) == [firstID])
        #expect(OperationLog(storage: second, copies: .live).entries.map(\.id) == [secondID])
        #expect(!OperationLog.shared.entries.contains { $0.id == firstID || $0.id == secondID })
        let saved = try Data(contentsOf: second.url("history.sealed"))
        a.clear()
        #expect(OperationLog(storage: first, copies: .live).entries.isEmpty)
        #expect(try Data(contentsOf: second.url("history.sealed")) == saved)
        // Same relative store name, different key: authentication must still refuse it without rewriting it.
        try saved.write(to: first.url("history.sealed"))
        #expect(OperationLog(storage: first, copies: .live).entries.isEmpty)
        #expect(try Data(contentsOf: first.url("history.sealed")) == saved)
        #expect(tree.snapshot() == ["a.txt", "b.txt", "first/", "first/Caches/", "first/history.sealed", "second/", "second/Caches/", "second/history.sealed"])
    }

    @Test func storeNamesRemainRelativeAndStreamsKeepTheirContext() throws {
        let tree = try TestTree("first/", "second/")
        let first = context(tree, "first", key: key)
        let second = context(tree, "second", key: key)
        let bytes = Data((0..<(2 * 1024 * 1024 + 31)).map { UInt8(truncatingIfNeeded: $0) })
        let writer = try SecureStorage.Writer(url: first.url("index.sealed"), storage: first)
        bytes.withUnsafeBytes { writer.write($0) }
        try writer.commit()
        let sealed = try Data(contentsOf: first.url("index.sealed"))
        try sealed.write(to: second.url("index.sealed"))
        let reader = try SecureStorage.Reader(url: second.url("index.sealed"), storage: second)
        var prefix = Data(count: 1031)
        try prefix.withUnsafeMutableBytes { try reader.read(into: $0) }
        #expect(prefix == bytes.prefix(1031))
        #expect(try reader.readToEnd() == bytes.dropFirst(1031))
        // Moving the app's storage root preserves identity; renaming a store does not.
        try sealed.write(to: second.url("other.sealed"))
        #expect(second.read(second.url("other.sealed")) == nil)
        #expect(try Data(contentsOf: second.url("other.sealed")) == sealed)
        #expect(tree.snapshot() == ["first/", "first/Caches/", "first/index.sealed", "second/", "second/Caches/", "second/index.sealed", "second/other.sealed"])
    }

    @Test func keyProviderRunsOnceAndUnavailableKeysNeverReplaceFiles() async throws {
        for available in [false, true] {
            let tree = try TestTree("store/", "outside.txt", "store/history.sealed -> ../outside.txt")
            let calls = Mutex(0)
            let suppliedKey = key
            let storage = SecureStorage.Context(directory: tree.url("store"), caches: tree.url("store/Caches")) {
                calls.withLock { $0 += 1 }
                return available ? suppliedKey : nil
            }
            #expect(calls.withLock { $0 } == 0)
            let url = tree.url("store/history.sealed")
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<16 { group.addTask { await Self.attemptRead(storage, url) } }
            }
            #expect(calls.withLock { $0 } == 1)
            if available {
                try storage.write(Data("saved".utf8), to: url)
                #expect(storage.read(url) == Data("saved".utf8))
                #expect(tree.snapshot() == ["outside.txt", "store/", "store/Caches/", "store/history.sealed"])
            } else {
                #expect(throws: SecureStorage.Failure.self) { try storage.write(Data("saved".utf8), to: url) }
                #expect(tree.snapshot() == ["outside.txt", "store/", "store/Caches/", "store/history.sealed -> ../outside.txt"])
            }
            #expect(calls.withLock { $0 } == 1)
            #expect(tree.text("outside.txt") == "outside.txt")
        }
    }

    @concurrent private static func attemptRead(_ storage: SecureStorage.Context, _ url: URL) async {
        #expect(storage.read(url) == nil)
    }

    @Test func contextsReadTheLegacyEncryptedFormat() throws {
        let tree = try TestTree("store/")
        let storage = context(tree, "store", key: key)
        var legacy = Data()
        for word: UInt32 in [0x5354_5253, 1] {
            withUnsafeBytes(of: word.littleEndian) { legacy.append(contentsOf: $0) }
        }
        var associated = Data(repeating: 0, count: 8)
        associated.append(1)
        let contents = Data("older history".utf8)
        let box = try #require(AES.GCM.seal(contents, using: key, authenticating: associated).combined)
        withUnsafeBytes(of: UInt32(box.count).littleEndian) { legacy.append(contentsOf: $0) }
        legacy.append(box)
        let file = storage.url("history.sealed")
        try legacy.write(to: file)
        #expect(storage.read(file) == contents)
        #expect(try Data(contentsOf: file) == legacy)
        try storage.write(contents, to: file)
        #expect(storage.read(file) == contents)
        let rewritten = try Data(contentsOf: file)
        #expect(rewritten.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) } == 2)
        #expect(tree.snapshot() == ["store/", "store/Caches/", "store/history.sealed"])
    }

    @Test func historyRemovesOnlyItsOwnLegacyStore() throws {
        let tree = try TestTree("first/", "first/history.json -> ../outside.txt", "first/history.json.tmp",
                                "second/", "second/history.json", "outside.txt")
        let storage = context(tree, "first", key: key)
        #expect(OperationLog(storage: storage, copies: .live).entries.isEmpty)
        #expect(tree.text("outside.txt") == "outside.txt")
        #expect(tree.text("second/history.json") == "second/history.json")
        #expect(tree.snapshot() == ["first/", "first/Caches/", "outside.txt", "second/", "second/history.json"])
    }

    @Test func historyUndoAndRedoKeepTheOwningStore() async throws {
        let tree = try TestTree("state/", "a.txt", "ab.txt", "nested/", "nested/a.txt", "link -> a.txt")
        let storage = context(tree, "state", key: key)
        let history = OperationLog(storage: storage, copies: .live)
        let moves = [(from: tree.url("a.txt"), to: tree.url("b.txt"))]
        try await FileOps.moveAsPart(moves, copies: .live)
        let id = try #require(history.recordMove("Rename", moves))
        let entry = try #require(history.entries.first)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        try await history.undo(entry, undoManager: undo)
        undo.endUndoGrouping()
        #expect(OperationLog(storage: storage, copies: .live).entries.first?.undone == true)
        let restored = ["a.txt", "ab.txt", "link -> a.txt", "nested/", "nested/a.txt", "state/", "state/Caches/", "state/history.sealed"]
        let renamed = ["ab.txt", "b.txt", "link -> a.txt", "nested/", "nested/a.txt", "state/", "state/Caches/", "state/history.sealed"]
        #expect(tree.snapshot() == restored)
        for _ in 0..<2 {
            undo.undo()
            await FileOps.undoWork?.value
            #expect(OperationLog(storage: storage, copies: .live).entries.first?.undone == false)
            #expect(tree.snapshot() == renamed)
            undo.redo()
            await FileOps.undoWork?.value
            #expect(OperationLog(storage: storage, copies: .live).entries.first?.undone == true)
            #expect(tree.snapshot() == restored)
        }
        #expect(!OperationLog.shared.entries.contains { $0.id == id })
        #expect(tree.text("a.txt") == "a.txt")
        #expect(tree.text("nested/a.txt") == "nested/a.txt")
        #expect(tree.snapshot() == restored)
    }
}
