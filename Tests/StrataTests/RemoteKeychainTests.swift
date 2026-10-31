import Foundation
import Security
import Synchronization
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct RemoteKeychainTests {
    nonisolated private struct Identity: Hashable, Sendable {
        var service = "Strata S3"
        var account: String
        var kind = kSecClassGenericPassword as String
    }

    nonisolated private struct Item: Equatable, Sendable {
        let identity = UUID()
        var data: Data
        var label: String
        var accessible = kSecAttrAccessibleWhenUnlocked as String

        init(_ value: String, label: String = "Fixture") {
            data = Data(value.utf8)
            self.label = label
        }
    }

    nonisolated private struct Call: Equatable, Sendable {
        enum Operation: Sendable { case read, add, update, delete }
        let operation: Operation
        let queryKeys: Set<String>
        let attributeKeys: Set<String>
        let returnsData: Bool?
        let matchLimit: String?
    }

    /// A model of the four Security calls, including matching every item an update/delete query selects. It never
    /// calls Security: omitted identity keys really do select neighboring fixtures, so scope assertions catch that.
    nonisolated private final class Keychain: Sendable {
        struct State: Sendable {
            var items: [Identity: Item] = [:]
            var calls: [Call] = []
            var updateError: OSStatus?
            var addError: OSStatus?
            var readError: OSStatus?
            var wrongReadType = false
            var concurrentCreation: Item?
            var updateErrorAfterCreation: OSStatus?
        }
        let state: Mutex<State>
        init(_ state: State = State()) { self.state = Mutex(state) }
        var items: [Identity: Item] { state.withLock { $0.items } }
        var calls: [Call] { state.withLock { $0.calls } }
        var access: KeychainAccess {
            KeychainAccess(copy: { self.read($0) }, add: { self.add($0) },
                           update: { self.update($0, $1) }, delete: { self.delete($0) })
        }

        private func matches(_ key: Identity, _ query: [String: Any]) -> Bool {
            [(kSecClass as String, key.kind), (kSecAttrService as String, key.service), (kSecAttrAccount as String, key.account)]
                .allSatisfy { field, value in query[field] == nil || query[field] as? String == value }
        }

        private func record(_ operation: Call.Operation, _ query: [String: Any], _ attributes: [String: Any] = [:]) -> Call {
            Call(operation: operation, queryKeys: Set(query.keys), attributeKeys: Set(attributes.keys),
                 returnsData: query[kSecReturnData as String] as? Bool,
                 matchLimit: query[kSecMatchLimit as String] as? String)
        }

        private func read(_ raw: CFDictionary) -> (OSStatus, CFTypeRef?) {
            let query = raw as! [String: Any]
            return state.withLock { state in
                state.calls.append(record(.read, query))
                if let error = state.readError { return (error, Data("Untrusted error result".utf8) as CFData) }
                if state.wrongReadType { return (errSecSuccess, "Not credential data" as CFString) }
                guard let item = state.items.first(where: { matches($0.key, query) })?.value else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, item.data as CFData)
            }
        }

        private func add(_ raw: CFDictionary) -> OSStatus {
            let item = raw as! [String: Any]
            return state.withLock { state in
                state.calls.append(record(.add, item))
                if let error = state.addError { return error }
                guard let service = item[kSecAttrService as String] as? String,
                      let account = item[kSecAttrAccount as String] as? String,
                      let kind = item[kSecClass as String] as? String,
                      let data = item[kSecValueData as String] as? Data,
                      let label = item[kSecAttrLabel as String] as? String,
                      let accessible = item[kSecAttrAccessible as String] as? String else { return errSecParam }
                let key = Identity(service: service, account: account, kind: kind)
                if let concurrent = state.concurrentCreation {
                    state.concurrentCreation = nil
                    state.items[key] = concurrent
                    state.updateError = state.updateErrorAfterCreation
                    return errSecDuplicateItem
                }
                guard state.items[key] == nil else { return errSecDuplicateItem }
                var made = Item("")
                made.data = data; made.label = label; made.accessible = accessible
                state.items[key] = made
                return errSecSuccess
            }
        }

        private func update(_ raw: CFDictionary, _ rawAttributes: CFDictionary) -> OSStatus {
            let query = raw as! [String: Any], attributes = rawAttributes as! [String: Any]
            return state.withLock { state in
                state.calls.append(record(.update, query, attributes))
                if let error = state.updateError { return error }
                guard query[kSecReturnData as String] == nil, query[kSecMatchLimit as String] == nil,
                      let data = attributes[kSecValueData as String] as? Data,
                      let label = attributes[kSecAttrLabel as String] as? String else { return errSecParam }
                let matching = state.items.keys.filter { matches($0, query) }
                guard !matching.isEmpty else { return errSecItemNotFound }
                for key in matching {
                    state.items[key]?.data = data
                    state.items[key]?.label = label
                    if let accessibility = attributes[kSecAttrAccessible as String] as? String {
                        state.items[key]?.accessible = accessibility
                    }
                }
                return errSecSuccess
            }
        }

        private func delete(_ raw: CFDictionary) -> OSStatus {
            let query = raw as! [String: Any]
            return state.withLock { state in
                state.calls.append(record(.delete, query))
                let matching = state.items.keys.filter { matches($0, query) }
                for key in matching { state.items[key] = nil }
                return matching.isEmpty ? errSecItemNotFound : errSecSuccess
            }
        }
    }

    private let server = RemoteServer(id: UUID().uuidString, kind: .s3, name: "Fixture", host: "s3.eu-west-1.amazonaws.com",
                                      bucket: "fixture", region: "eu-west-1", accessKeyID: "FIXTUREKEY")
    private var key: Identity { Identity(account: server.id) }
    private var neighbors: [Identity: Item] {
        [Identity(account: server.id + "-other"): Item("Neighbor"),
         Identity(service: "Another service", account: server.id): Item("Other service"),
         Identity(account: server.id, kind: kSecClassInternetPassword as String): Item("Other class")]
    }
    private var identityKeys: Set<String> { [kSecClass as String, kSecAttrService as String, kSecAttrAccount as String] }

    @Test func replacingASecretKeepsTheOriginalWhenSecurityRefusesTheUpdate() {
        for error in [errSecAuthFailed, errSecInteractionNotAllowed, errSecParam] {
            var items = neighbors
            items[key] = Item("Working secret")
            let fixture = Keychain(.init(items: items, updateError: error, addError: error))
            let store = RemoteKeychain(access: fixture.access)
            #expect(!store.setSecret("Replacement", for: server))
            #expect(fixture.items == items)
            #expect(fixture.calls.map(\.operation) == [.update])
        }
    }

    @Test func creationAndReplacementKeepExactIdentityAndNativeProtection() throws {
        let original = neighbors
        let fixture = Keychain(.init(items: original)), store = RemoteKeychain(access: fixture.access)
        #expect(store.setSecret("First", for: server))
        var first = try #require(fixture.items[key])
        #expect(first.data == Data("First".utf8))
        #expect(first.label == "Strata S3: fixture")
        #expect(first.accessible == kSecAttrAccessibleWhenUnlocked as String)
        #expect(fixture.items.filter { $0.key != key } == original)
        first.accessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        fixture.state.withLock { $0.items[key] = first }
        var edited = server
        edited.name = "Renamed"; edited.bucket = "renamed-bucket"
        #expect(store.setSecret("Updated ☃", for: edited))
        var expected = first
        expected.data = Data("Updated ☃".utf8); expected.label = "Strata S3: renamed-bucket"
        #expect(fixture.items[key] == expected)
        #expect(fixture.items.filter { $0.key != key } == original)
        #expect(fixture.calls.map(\.operation) == [.update, .add, .update])
        for call in fixture.calls where call.operation == .update {
            #expect(call.queryKeys == identityKeys)
            #expect(call.attributeKeys == [kSecValueData as String, kSecAttrLabel as String])
        }
        let add = try #require(fixture.calls.first { $0.operation == .add })
        #expect(add.queryKeys == identityKeys.union([kSecValueData as String, kSecAttrLabel as String, kSecAttrAccessible as String]))
    }

    @Test func anotherCreatorIsUpdatedInPlaceAndFailedRetriesLeaveItsItemIntact() throws {
        let neighbors = self.neighbors
        for failure: OSStatus? in [nil, errSecAuthFailed, errSecItemNotFound] {
            let concurrent = Item("Created concurrently", label: "Keep unless update succeeds")
            let fixture = Keychain(.init(items: neighbors, concurrentCreation: concurrent, updateErrorAfterCreation: failure))
            let store = RemoteKeychain(access: fixture.access)
            #expect(store.setSecret("Wanted", for: server) == (failure == nil))
            var expected = concurrent
            if failure == nil { expected.data = Data("Wanted".utf8); expected.label = "Strata S3: fixture" }
            #expect(fixture.items[key] == expected)
            #expect(fixture.items.filter { $0.key != key } == neighbors)
            #expect(fixture.calls.map(\.operation) == [.update, .add, .update])
        }
    }

    @Test func failedNewItemsNeverChangeExistingCredentials() {
        let neighbors = self.neighbors
        for error in [errSecAuthFailed, errSecInteractionNotAllowed, errSecParam] {
            let fixture = Keychain(.init(items: neighbors, addError: error))
            let store = RemoteKeychain(access: fixture.access)
            #expect(!store.setSecret("Rejected", for: server))
            #expect(fixture.items == neighbors)
            #expect(fixture.calls.map(\.operation) == [.update, .add])
        }
    }

    @Test func readsAndDeletesStayWithTheirStoreAndExactServer() {
        let neighbors = self.neighbors
        var items = neighbors
        items[key] = Item("First")
        let first = Keychain(.init(items: items))
        var otherItems = neighbors
        otherItems[key] = Item("Second")
        let second = Keychain(.init(items: otherItems))
        let left = RemoteKeychain(access: first.access), right = RemoteKeychain(access: second.access)
        #expect(left.secret(for: server) == "First" && right.secret(for: server) == "Second")
        left.delete(server)
        #expect(first.items == neighbors && second.items == otherItems)
        #expect(left.secret(for: server) == nil && right.secret(for: server) == "Second")
        left.delete(server)
        #expect(first.items == neighbors && second.items == otherItems)
        for call in first.calls {
            switch call.operation {
            case .read:
                #expect(call.queryKeys == identityKeys.union([kSecReturnData as String, kSecMatchLimit as String]))
                #expect(call.returnsData == true && call.matchLimit == kSecMatchLimitOne as String)
            case .delete: #expect(call.queryKeys == identityKeys)
            default: Issue.record("A read or deletion unexpectedly wrote a credential")
            }
        }
    }

    @Test func unreadableCredentialsNeverChangeTheStoreOrConstructAnAuthenticatedBackend() throws {
        var bad = Item("")
        bad.data = Data([0xff, 0xfe])
        let states = [Keychain.State(), .init(items: [key: Item("Saved")], readError: errSecAuthFailed),
                      .init(items: [key: Item("Saved")], wrongReadType: true), .init(items: [key: bad])]
        for state in states {
            let fixture = Keychain(state), store = RemoteKeychain(access: fixture.access)
            #expect(store.secret(for: server) == nil)
            #expect(throws: RemoteError.noSecret) { try S3Backend(server, credentials: store) }
            #expect(fixture.items == state.items)
            #expect(fixture.calls.allSatisfy { $0.operation == .read })
        }
        let fixture = Keychain(.init(items: [key: Item("Fixture secret")]))
        let backend = try S3Backend(server, credentials: RemoteKeychain(access: fixture.access))
        #expect(backend.isAlive)
        #expect(fixture.calls.map(\.operation) == [.read])
        #expect(fixture.items[key]?.data == Data("Fixture secret".utf8))
        backend.close()
    }
}
