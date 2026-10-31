import Foundation
import Security
import Synchronization
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

struct RemoteServerStoreTests {
    nonisolated private final class Secrets: Sendable {
        struct State { var values: [String: Data] = [:]; var refuseWrites = false; var refuseDeletes = false; var calls = 0 }
        let state = Mutex(State())
        var access: KeychainAccess {
            KeychainAccess(copy: { query in
                let id = (query as NSDictionary)[kSecAttrAccount] as? String ?? ""
                return self.state.withLock { state in
                    state.calls += 1
                    guard let value = state.values[id] else { return (errSecItemNotFound, nil) }
                    return (errSecSuccess, value as CFData)
                }
            }, add: { query in
                let id = (query as NSDictionary)[kSecAttrAccount] as? String ?? ""
                let data = (query as NSDictionary)[kSecValueData] as? Data
                return self.state.withLock { state in
                    state.calls += 1
                    if state.refuseWrites { return errSecAuthFailed }
                    guard state.values[id] == nil else { return errSecDuplicateItem }
                    state.values[id] = data
                    return errSecSuccess
                }
            }, update: { query, changes in
                let id = (query as NSDictionary)[kSecAttrAccount] as? String ?? ""
                let data = (changes as NSDictionary)[kSecValueData] as? Data
                return self.state.withLock { state in
                    state.calls += 1
                    if state.refuseWrites { return errSecAuthFailed }
                    guard state.values[id] != nil else { return errSecItemNotFound }
                    state.values[id] = data
                    return errSecSuccess
                }
            }, delete: { query in
                let id = (query as NSDictionary)[kSecAttrAccount] as? String ?? ""
                return self.state.withLock { state in
                    state.calls += 1
                    if state.refuseDeletes { return errSecAuthFailed }
                    guard state.values.removeValue(forKey: id) != nil else { return errSecItemNotFound }
                    return errSecSuccess
                }
            })
        }
    }

    private final class Environment {
        let preferences: Prefs
        var defaults: UserDefaults { preferences.defaults }
        let secrets = Secrets()
        let notifications = NotificationCenter()
        let registry = RemoteServerRegistry()
        let store: RemoteServerStore
        init() throws {
            preferences = try Prefs.isolated()
            store = RemoteServerStore(preferences: preferences, credentials: RemoteKeychain(access: secrets.access),
                                      registry: registry, notifications: notifications)
        }
    }

    private func server(_ id: String = UUID().uuidString, name: String = "Fixture") -> RemoteServer {
        RemoteServer(id: id, kind: .s3, name: name, host: "s3.eu-west-1.amazonaws.com", bucket: "fixture",
                     region: "eu-west-1", accessKeyID: "FIXTUREKEY")
    }

    @Test func independentStoresRetainOrderCredentialsAndTheExistingPreferenceFormat() throws {
        let left = try Environment(), right = try Environment()
        let a = server(), b = server(), other = server(a.id, name: "Other environment")
        left.defaults.set(try JSONEncoder().encode([a, b]), forKey: "remoteServers")
        left.store.load()
        #expect(left.registry.server(id: a.id) == a && left.registry.server(id: b.id) == b)
        try right.store.save(other, secret: "Right")
        var changed = a; changed.name = "Edited"
        let catalog = RemoteConnectionCatalog(store: left.store)
        try catalog.save(changed, "Left")
        #expect(catalog.servers() == [changed, b] && catalog.secret(changed) == "Left")
        #expect(right.store.all == [other] && right.registry.server(id: a.id) == other)
        #expect(right.store.credentials.secret(for: other) == "Right")
        let saved = try #require(left.defaults.data(forKey: "remoteServers"))
        #expect(try JSONDecoder().decode([RemoteServer].self, from: saved) == [changed, b])
        let reopened = RemoteServerStore(preferences: left.preferences, credentials: left.store.credentials,
                                        registry: RemoteServerRegistry(), notifications: NotificationCenter())
        reopened.load()
        #expect(reopened.all == [changed, b] && reopened.registry.server(id: a.id) == changed)
        #expect(reopened.credentials.secret(for: changed) == "Left")
        #expect(left.store.forget(changed))
        #expect(left.store.all == [b] && left.registry.server(id: a.id) == nil)
        #expect(left.registry.server(id: b.id) == b && left.store.credentials.secret(for: changed) == nil)
        #expect(right.store.all == [other] && right.store.credentials.secret(for: other) == "Right")
        withExtendedLifetime((left, right)) {}
    }

    @Test func invalidOrRefusedSavesLeaveMetadataAndCredentialsUnchanged() throws {
        let environment = try Environment(), original = server(), neighbor = server()
        try environment.store.save(original, secret: "Saved")
        try environment.store.save(neighbor, secret: "Neighbor")
        let bytes = environment.defaults.data(forKey: "remoteServers")
        let secrets = environment.secrets.state.withLock { $0.values }
        var notifications = 0
        let observer = environment.notifications.addObserver(forName: .remoteServersChanged, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { notifications += 1 }
        }
        defer { environment.notifications.removeObserver(observer) }
        let calls = environment.secrets.state.withLock { $0.calls }
        var invalidID = original; invalidID.id = "../other"
        var lowerID = original; lowerID.id = original.id.lowercased()
        var invalidHost = original; invalidHost.host = "--option"
        for invalid in [invalidID, lowerID, invalidHost] {
            #expect(throws: (any Error).self) { try environment.store.save(invalid, secret: "Invalid") }
        }
        #expect(environment.secrets.state.withLock { $0.calls } == calls)
        environment.secrets.state.withLock { $0.refuseWrites = true }
        var proposed = original; proposed.host = "new.invalid"
        #expect(throws: (any Error).self) { try environment.store.save(proposed, secret: "Proposed") }
        #expect(environment.defaults.data(forKey: "remoteServers") == bytes)
        #expect(environment.store.all == [original, neighbor] && notifications == 0)
        #expect(environment.registry.server(id: original.id) == original)
        #expect(environment.secrets.state.withLock { $0.values } == secrets)
        #expect(!environment.store.forget(proposed))
        environment.secrets.state.withLock { $0.refuseDeletes = true }
        #expect(!environment.store.forget(original))
        #expect(!environment.store.credentials.delete(original))
        #expect(environment.store.all == [original, neighbor] && notifications == 0)
        #expect(environment.registry.server(id: original.id) == original)
        #expect(environment.defaults.data(forKey: "remoteServers") == bytes)
        #expect(environment.secrets.state.withLock { $0.values } == secrets)
        environment.secrets.state.withLock { $0.refuseDeletes = false }
        #expect(environment.store.credentials.delete(server()))
        withExtendedLifetime(environment) {}
    }

    @Test func removalNotifiesOnlyAfterRetiringTheOldSecretAndRegistryEntry() throws {
        let environment = try Environment(), original = server(), neighbor = server()
        try environment.store.save(original, secret: "Old")
        try environment.store.save(neighbor, secret: "Neighbor")
        var changes = 0
        let observer = environment.notifications.addObserver(forName: .remoteServersChanged, object: nil, queue: nil) { notification in
            let source = notification.object as? RemoteServerStore
            MainActor.assumeIsolated {
                #expect(source === environment.store)
                changes += 1
                if changes == 1 {
                    #expect(environment.store.all == [neighbor])
                    #expect(environment.registry.server(id: original.id) == nil)
                    #expect(environment.store.credentials.secret(for: original) == nil)
                    do { try environment.store.save(original, secret: "Reconnected") }
                    catch { Issue.record(error) }
                } else {
                    #expect(environment.registry.server(id: original.id) == original)
                    #expect(environment.store.credentials.secret(for: original) == "Reconnected")
                }
            }
        }
        defer { environment.notifications.removeObserver(observer) }
        #expect(environment.store.forget(original))
        #expect(changes == 2 && environment.store.all == [neighbor, original])
        #expect(environment.store.credentials.secret(for: original) == "Reconnected")
        #expect(environment.store.credentials.secret(for: neighbor) == "Neighbor")
        #expect(environment.registry.server(id: original.id) == original)
        withExtendedLifetime(environment) {}
    }

    @Test func readingInvalidSavedDataNeverRewritesItOrTouchesCredentials() throws {
        let environment = try Environment(), valid = server()
        var invalid = valid; invalid.id = "not-an-id"
        var unsafe = server(); unsafe.host = "--option"
        for data in [Data("{broken".utf8), try JSONEncoder().encode([invalid, valid, unsafe])] {
            environment.defaults.set(data, forKey: "remoteServers")
            environment.store.load()
            #expect(environment.defaults.data(forKey: "remoteServers") == data)
            #expect(environment.secrets.state.withLock { $0.calls } == 0)
            #expect(environment.store.all == (data.first == UInt8(ascii: "[") ? [valid] : []))
            #expect(environment.registry.server(id: invalid.id) == nil && environment.registry.server(id: unsafe.id) == nil)
        }
        #expect(environment.registry.server(id: valid.id) == valid)
        withExtendedLifetime(environment) {}
    }
}
