import AppKit
import Foundation
import Synchronization
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

struct RemoteConnectionTests {
    private enum Failure: Error { case connect, list, save, unexpected }

    private actor Gate {
        private var open = false
        private var entered = false
        private var held: [CheckedContinuation<Void, Never>] = []
        private var observers: [CheckedContinuation<Void, Never>] = []
        func enter() async {
            entered = true
            observers.forEach { $0.resume() }; observers.removeAll()
            if !open { await withCheckedContinuation { held.append($0) } }
        }
        func waitForEntry() async {
            if !entered { await withCheckedContinuation { observers.append($0) } }
        }
        func release() {
            open = true
            held.forEach { $0.resume() }; held.removeAll()
        }
    }

    nonisolated private final class Backend: RemoteBackend {
        private struct State { var closes = 0; var alive = true; var lists: [String] = [] }
        private let state = Mutex(State())
        private let listing: @Sendable () async throws -> Void
        init(listing: @escaping @Sendable () async throws -> Void = {}) { self.listing = listing }
        var closes: Int { state.withLock { $0.closes } }
        var lists: [String] { state.withLock { $0.lists } }
        var isAlive: Bool { state.withLock { $0.alive } }
        func drop() { state.withLock { $0.alive = false } }
        func close() { state.withLock { $0.closes += 1; $0.alive = false } }
        func home() async throws -> String { "/" }
        func list(_ path: String) async throws -> [ListedEntry] {
            state.withLock { $0.lists.append(path) }
            try await listing()
            return []
        }
        func kind(of path: String) async throws -> RemoteItemKind? { nil }
        func download(_ path: String, to destination: URL, limit: Int64,
                      progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws { throw Failure.unexpected }
        func upload(_ source: URL, to path: String, modified: Date?,
                    progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws { throw Failure.unexpected }
        func makeFolder(_ path: String) async throws { throw Failure.unexpected }
        func rename(_ path: String, to newPath: String) async throws { throw Failure.unexpected }
        func remove(_ path: String) async throws { throw Failure.unexpected }
    }

    private actor Factory {
        struct Call: Sendable, Equatable { let server: RemoteServer; let secret: String? }
        private(set) var calls: [Call] = []
        private(set) var cancelled: [Int: Bool] = [:]
        private var pending: [Int: CheckedContinuation<any RemoteBackend, Error>] = [:]
        private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
        func connect(_ server: RemoteServer, secret: String?) async throws -> any RemoteBackend {
            let index = calls.count
            calls.append(Call(server: server, secret: secret))
            defer { cancelled[index] = Task.isCancelled }
            return try await withCheckedThrowingContinuation { continuation in
                pending[index] = continuation
                let ready = observers.filter { $0.0 <= calls.count }
                observers.removeAll { $0.0 <= calls.count }
                ready.forEach { $0.1.resume() }
            }
        }
        func waitForCalls(_ count: Int) async {
            if calls.count < count { await withCheckedContinuation { observers.append((count, $0)) } }
        }
        func finish(_ index: Int, _ backend: Backend) { pending.removeValue(forKey: index)?.resume(returning: backend) }
        func fail(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: Failure.connect) }
        nonisolated var connector: RemoteConnector { RemoteConnector { try await self.connect($0, secret: $1) } }
    }

    nonisolated private final class Lookup: Sendable {
        let servers: Mutex<[String: RemoteServer]>
        init(_ servers: [RemoteServer]) { self.servers = Mutex(Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })) }
    }

    private final class Store {
        let lookup: Lookup
        var servers: [RemoteServer]
        var secrets: [String: String]
        var saves: [RemoteServer] = []
        var rejectSave = false
        var onSave: (() -> Void)?
        init(_ servers: [RemoteServer] = [], secrets: [String: String] = [:]) {
            self.servers = servers; self.secrets = secrets
            lookup = Lookup(servers)
        }
        var catalog: RemoteConnectionCatalog {
            RemoteConnectionCatalog(servers: { self.servers }, secret: { self.secrets[$0.id] }, save: { server, secret in
                if self.rejectSave { throw Failure.save }
                if let secret { self.secrets[server.id] = secret }
                if let index = self.servers.firstIndex(where: { $0.id == server.id }) { self.servers[index] = server }
                else { self.servers.append(server) }
                self.lookup.servers.withLock { $0[server.id] = server }
                self.saves.append(server)
                self.onSave?()
            })
        }
        func remove(_ id: String) {
            servers.removeAll { $0.id == id }; secrets[id] = nil
            lookup.servers.withLock { $0[id] = nil }
        }
    }

    private final class Copies {
        var gate: Gate?
        var discards: [String] = []
        var disconnected: [String] = []
        var completed: [String] = []
        func discard(_ id: String) async {
            discards.append(id)
            if let gate { await gate.enter() }
            completed.append(id)
        }
    }

    private actor Status {
        private(set) var changes: [Bool] = []
        var gate: (Bool, Gate)?
        func holdPublication(_ gate: Gate) { self.gate = (true, gate) }
        func holdDisconnection(_ gate: Gate) { self.gate = (false, gate) }
        func changed(_ connected: Bool) async {
            changes.append(connected)
            if let (expected, gate) = gate, expected == connected { self.gate = nil; await gate.enter() }
        }
    }

    private final class Environment {
        let store: Store
        let factory = Factory()
        let copies = Copies()
        let status = Status()
        let sessions: RemoteSessions
        let connections: RemoteConnections
        init(_ servers: [RemoteServer] = [], secrets: [String: String] = [:]) {
            let store = Store(servers, secrets: secrets)
            self.store = store
            let lookup = store.lookup, status = status
            sessions = RemoteSessions(server: { id in lookup.servers.withLock { $0[id] } },
                connect: { _ in throw Failure.unexpected }, changed: { _, connected in await status.changed(connected) })
            let copies = copies
            connections = RemoteConnections(catalog: store.catalog, sessions: sessions, connector: factory.connector,
                discard: { await copies.discard($0) }, disconnected: { copies.disconnected.append($0) })
        }
        func seed(_ backend: Backend, for server: RemoteServer) async throws {
            let reservation = try await sessions.reserveReplacement(for: server.id)
            #expect(try await sessions.install(backend, replacing: reservation, save: {}))
        }
    }

    private func s3(_ id: String = UUID().uuidString, host: String = "s3.eu-west-1.amazonaws.com") -> RemoteServer {
        RemoteServer(id: id, kind: .s3, name: "Fixture", host: host, bucket: "fixture", region: "eu-west-1", accessKeyID: "FIXTUREKEY")
    }

    @Test func failuresAndCancellationNeverPublishProposedSecretsOrDisconnectTheWorkingServer() async throws {
        for outcome in 0..<3 {
            let original = s3(), existing = Backend()
            let environment = Environment([original], secrets: [original.id: "Working"])
            try await environment.seed(existing, for: original)
            var edited = original; edited.host = "new.invalid"
            let request = environment.connections.connect(edited, secret: "Proposed")
            await environment.factory.waitForCalls(1)
            #expect(environment.store.servers == [original] && environment.store.secrets == [original.id: "Working"])
            #expect(try await environment.sessions.backend(for: original.id) === existing)
            let proposed = Backend(listing: { if outcome == 1 { throw Failure.list } })
            if outcome == 0 { await environment.factory.fail(0) }
            else {
                if outcome == 2 { request.cancel() }
                await environment.factory.finish(0, proposed)
            }
            await #expect(throws: (any Error).self) { try await request.value }
            #expect(environment.store.servers == [original] && environment.store.secrets == [original.id: "Working"])
            #expect(environment.store.saves.isEmpty && environment.copies.discards.isEmpty)
            #expect(existing.closes == 0 && proposed.closes == (outcome == 0 ? 0 : 1))
            #expect(await environment.factory.cancelled[0] == (outcome == 2))
            #expect(try await environment.sessions.backend(for: original.id) === existing)
            #expect(await environment.factory.calls == [.init(server: edited, secret: "Proposed")])
            await environment.sessions.disconnect(original.id)
        }
    }

    @Test func cancelledAttemptsCannotOverwriteOrDisconnectTheirReplacementInEitherCompletionOrder() async throws {
        for oldFirst in [false, true] {
            for oldFails in [false, true] {
                let original = s3(), environment = Environment([original], secrets: [original.id: "Saved"])
                var firstServer = original; firstServer.host = "first.invalid"
                var secondServer = original; secondServer.host = "second.invalid"
                let old = environment.connections.connect(firstServer, secret: "First")
                await environment.factory.waitForCalls(1)
                let current = environment.connections.connect(secondServer, secret: "Second")
                await environment.factory.waitForCalls(2)
                let first = Backend(), second = Backend()
                if oldFirst {
                    if oldFails { await environment.factory.fail(0) } else { await environment.factory.finish(0, first) }
                    await #expect(throws: (any Error).self) { try await old.value }
                    #expect(environment.store.saves.isEmpty)
                }
                await environment.factory.finish(1, second)
                #expect(try await current.value == secondServer)
                if !oldFirst {
                    if oldFails { await environment.factory.fail(0) } else { await environment.factory.finish(0, first) }
                    await #expect(throws: (any Error).self) { try await old.value }
                }
                #expect(environment.store.servers == [secondServer])
                #expect(environment.store.secrets == [original.id: "Second"])
                #expect(environment.store.saves == [secondServer])
                #expect(first.closes == (oldFails ? 0 : 1) && second.closes == 0)
                #expect(second.lists == ["/"])
                #expect(try await environment.sessions.backend(for: original.id) === second)
                await environment.sessions.disconnect(original.id)
            }
        }
    }

    @Test func savingWaitsForBucketVerificationAndReusesUnchangedCredentials() async throws {
        let server = s3(), environment = Environment([server], secrets: [server.id: "Existing"]), gate = Gate()
        let proposed = Backend(listing: { await gate.enter() })
        var renamed = server; renamed.name = "Renamed"
        let request = environment.connections.connect(renamed)
        await environment.factory.waitForCalls(1)
        await environment.factory.finish(0, proposed)
        await gate.waitForEntry()
        #expect(environment.store.saves.isEmpty && environment.store.servers == [server])
        #expect(environment.store.secrets == [server.id: "Existing"])
        await gate.release()
        #expect(try await request.value == renamed)
        #expect(environment.store.servers == [renamed] && environment.store.secrets == [server.id: "Existing"])
        #expect(environment.copies.discards.isEmpty)
        #expect(await environment.factory.calls == [.init(server: renamed, secret: "Existing")])
        await environment.sessions.disconnect(server.id)
    }

    @Test func cancelledHandoffsFinishCleanupBeforeTheRetryPublishes() async throws {
        let original = s3(), environment = Environment([original], secrets: [original.id: "Saved"]), gate = Gate()
        environment.copies.gate = gate
        var firstServer = original; firstServer.host = "first.invalid"
        let first = environment.connections.connect(firstServer, secret: "First")
        let firstBackend = Backend()
        await environment.factory.waitForCalls(1); await environment.factory.finish(0, firstBackend)
        await gate.waitForEntry()
        await #expect(throws: CancellationError.self) { try await environment.sessions.backend(for: original.id) }
        first.cancel()
        var secondServer = original; secondServer.host = "second.invalid"
        let second = environment.connections.connect(secondServer, secret: "Second"), secondBackend = Backend()
        await environment.factory.waitForCalls(2)
        await environment.factory.finish(1, secondBackend)
        #expect(environment.store.saves.isEmpty)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value == secondServer)
        #expect(environment.store.saves == [secondServer] && environment.store.secrets == [original.id: "Second"])
        #expect(environment.copies.discards == [original.id, original.id])
        #expect(environment.copies.disconnected == [original.id])
        #expect(firstBackend.closes == 1 && secondBackend.closes == 0)
        #expect(try await environment.sessions.backend(for: original.id) === secondBackend)
        await environment.sessions.disconnect(original.id)
    }

    @Test func removedOrChangedSavedServersAndRefusedSecretWritesAreNeverOverwritten() async throws {
        for outcome in 0..<3 {
            let original = s3(), environment = Environment([original], secrets: [original.id: "Saved"]), existing = Backend()
            try await environment.seed(existing, for: original)
            var proposed = original; proposed.name = "Proposed"
            let request = environment.connections.connect(proposed, secret: "Changed")
            await environment.factory.waitForCalls(1)
            if outcome == 0 { environment.store.remove(original.id) }
            if outcome == 1 { environment.store.servers[0].name = "Changed elsewhere" }
            if outcome == 2 { environment.store.rejectSave = true }
            let expected = environment.store.servers, secrets = environment.store.secrets, backend = Backend()
            await environment.factory.finish(0, backend)
            await #expect(throws: (any Error).self) { try await request.value }
            #expect(environment.store.servers == expected && environment.store.secrets == secrets)
            #expect(environment.store.saves.isEmpty && backend.closes == 1)
            #expect(existing.closes == (outcome == 2 ? 1 : 0))
            #expect(environment.copies.discards.isEmpty || outcome == 2)
            await environment.sessions.disconnect(original.id)
        }
    }

    @Test func disconnectingDuringCleanupRevokesTheReservationBeforeSaving() async throws {
        let original = s3(), environment = Environment([original], secrets: [original.id: "Saved"]), gate = Gate()
        environment.copies.gate = gate
        var proposed = original; proposed.host = "new.invalid"
        let request = environment.connections.connect(proposed, secret: "Changed"), backend = Backend()
        await environment.factory.waitForCalls(1); await environment.factory.finish(0, backend)
        await gate.waitForEntry()
        await environment.sessions.disconnect(original.id)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(environment.store.servers == [original] && environment.store.secrets == [original.id: "Saved"])
        #expect(environment.store.saves.isEmpty && backend.closes == 1)
    }

    @Test func aPublishedBackendBelongsToThePoolEvenIfDisconnectedDuringNotification() async throws {
        let server = s3(), environment = Environment(), gate = Gate(), backend = Backend()
        await environment.status.holdPublication(gate)
        let request = environment.connections.connect(server, secret: "Saved")
        await environment.factory.waitForCalls(1); await environment.factory.finish(0, backend)
        await gate.waitForEntry()
        #expect(environment.store.servers == [server] && environment.store.secrets == [server.id: "Saved"])
        request.cancel()
        await environment.sessions.disconnect(server.id)
        await gate.release()
        _ = try await request.value
        #expect(backend.closes == 1)
        #expect(!(await environment.sessions.isConnected(server.id)))
    }

    @Test func independentEnvironmentsAndSFTPKeepTheirOwnSettingsAndBackends() async throws {
        let id = UUID().uuidString
        let left = Environment(), right = Environment()
        let a = RemoteServer(id: id, kind: .sftp, name: "Left", host: "left.invalid")
        let b = s3(id, host: "right.invalid")
        let one = left.connections.connect(a), two = right.connections.connect(b, secret: "Right")
        await left.factory.waitForCalls(1); await right.factory.waitForCalls(1)
        let first = Backend(), second = Backend()
        await left.factory.finish(0, first); await right.factory.finish(0, second)
        #expect(try await one.value == a)
        #expect(try await two.value == b)
        #expect(left.store.servers == [a] && right.store.servers == [b])
        #expect(left.store.secrets.isEmpty && right.store.secrets == [id: "Right"])
        #expect(first.lists.isEmpty && second.lists == ["/"])
        left.connections.cancel(id)
        await left.sessions.disconnect(id)
        #expect(first.closes == 1 && second.closes == 0)
        #expect(try await right.sessions.backend(for: id) === second)
        await right.sessions.disconnect(id)
    }

    @Test func invalidDefinitionsAndMissingSecretsNeverReachTheConnector() async {
        let environment = Environment()
        var badID = s3(); badID.id = "not-a-server-id"
        var badHost = s3(); badHost.host = "--option"
        for server in [badID, badHost] {
            let request = environment.connections.connect(server, secret: "Proposed")
            await #expect(throws: (any Error).self) { try await request.value }
        }
        let missing = environment.connections.connect(s3())
        await #expect(throws: RemoteError.noSecret) { try await missing.value }
        #expect(await environment.factory.calls.isEmpty)
        #expect(environment.store.servers.isEmpty && environment.store.secrets.isEmpty && environment.copies.discards.isEmpty)
    }
    private func views<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views($0, of: type) }
    }

    @Test func nativeSheetKeepsNewAttemptsBusyWhenOldResultsArrive() async throws {
        _ = NSApplication.shared
        let settings = ServerConnectionSettings(preferences: try Prefs.isolated())
        let original = s3(), environment = Environment([original], secrets: [original.id: "Saved"])
        let sheet = ConnectToServerController(editing: original, settings: settings, mounts: ServerMountSession(mounter: .live), connections: environment.connections, sshHosts: { [] })
        let secret = try #require(views(sheet.view, of: NSSecureTextField.self).first)
        let buttons = views(sheet.view, of: NSButton.self)
        let connect = try #require(buttons.first { $0.action == NSSelectorFromString("connect:") })
        let cancel = try #require(buttons.first { $0.action == NSSelectorFromString("cancel:") })
        var received: [RemoteServer] = []
        sheet.onServer = { received.append($0) }
        secret.stringValue = "First"
        #expect(connect.sendAction(connect.action, to: connect.target))
        let firstUI = try #require(sheet.connecting)
        await environment.factory.waitForCalls(1)
        #expect(!connect.isEnabled && !secret.isEnabled)
        #expect(cancel.sendAction(cancel.action, to: cancel.target))
        #expect(connect.isEnabled && secret.isEnabled)
        secret.stringValue = "Second"
        #expect(connect.sendAction(connect.action, to: connect.target))
        let secondUI = try #require(sheet.connecting)
        await environment.factory.waitForCalls(2)
        await environment.factory.fail(0); await firstUI.value
        #expect(!connect.isEnabled && !secret.isEnabled && received.isEmpty)
        #expect(environment.store.secrets == [original.id: "Saved"])
        let backend = Backend()
        await environment.factory.finish(1, backend); await secondUI.value
        #expect(connect.isEnabled && secret.isEnabled)
        var expected = original; expected.pathStyle = false
        #expect(received == [expected] && environment.store.secrets == [original.id: "Second"])
        #expect(environment.store.saves == [expected])
        await environment.sessions.disconnect(original.id)
        withExtendedLifetime((sheet, settings)) {}
    }

    @Test func releasingTheNativeSheetCancelsItsPrivateConnection() async throws {
        _ = NSApplication.shared
        let settings = ServerConnectionSettings(preferences: try Prefs.isolated())
        let original = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let environment = Environment([original])
        var sheet: ConnectToServerController? = ConnectToServerController(editing: original, settings: settings,
            mounts: ServerMountSession(mounter: .live), connections: environment.connections, sshHosts: { ["fixture.invalid"] })
        weak let weakSheet = sheet
        var callbacks = 0
        sheet!.onServer = { _ in callbacks += 1 }
        let connect = try #require(views(sheet!.view, of: NSButton.self).first { $0.action == NSSelectorFromString("connect:") })
        #expect(connect.sendAction(connect.action, to: connect.target))
        let ui = try #require(sheet!.connecting)
        await environment.factory.waitForCalls(1)
        sheet = nil
        #expect(weakSheet == nil)
        let backend = Backend()
        await environment.factory.finish(0, backend); await ui.value
        #expect(callbacks == 0 && backend.closes == 1)
        #expect(environment.store.servers == [original] && environment.store.saves.isEmpty)
        #expect(!(await environment.sessions.isConnected(original.id)))
        withExtendedLifetime(settings) {}
    }

    @Test func invalidRequestsDoNotCancelAnAlreadyValidAttempt() async throws {
        let server = s3(), environment = Environment()
        let valid = environment.connections.connect(server, secret: "Valid")
        await environment.factory.waitForCalls(1)
        var invalid = server; invalid.host = "--invalid"
        let refused = environment.connections.connect(invalid, secret: "Invalid")
        await #expect(throws: (any Error).self) { try await refused.value }
        let missing = environment.connections.connect(server)
        await #expect(throws: RemoteError.noSecret) { try await missing.value }
        #expect(!valid.isCancelled)
        let backend = Backend()
        await environment.factory.finish(0, backend)
        #expect(try await valid.value == server)
        #expect(environment.store.servers == [server] && environment.store.secrets == [server.id: "Valid"])
        #expect(await environment.factory.calls.count == 1)
        await environment.sessions.disconnect(server.id)
    }

    @Test func staleReservationsCannotSaveOrReleaseANewerReservation() async throws {
        let server = s3(), environment = Environment([server]), stale = Backend(), current = Backend()
        let first = try await environment.sessions.reserveReplacement(for: server.id)
        let second = try await environment.sessions.reserveReplacement(for: server.id)
        #expect(!first.isValid && second.isValid)
        await environment.sessions.release(first)
        await #expect(throws: CancellationError.self) { try await environment.sessions.backend(for: server.id) }
        var saves = 0
        await #expect(throws: CancellationError.self) {
            try await environment.sessions.install(stale, replacing: first, save: { saves += 1 })
        }
        #expect(saves == 0 && stale.closes == 0)
        #expect(try await environment.sessions.install(current, replacing: second, save: { saves += 1 }))
        #expect(saves == 1 && !second.isValid)
        #expect(try await environment.sessions.backend(for: server.id) === current)
        stale.close()
        await environment.sessions.disconnect(server.id)
        #expect(stale.closes == 1 && current.closes == 1)
        let third = try await environment.sessions.reserveReplacement(for: server.id)
        await environment.sessions.disconnect(server.id)
        #expect(!third.isValid)
    }

    @Test func aReservationCreatedDuringDroppedStatusBlocksAutomaticReconnection() async throws {
        let server = s3(), environment = Environment([server]), previous = Backend(), gate = Gate()
        try await environment.seed(previous, for: server)
        previous.drop()
        await environment.status.holdDisconnection(gate)
        let reader = Task { try await environment.sessions.backend(for: server.id) }
        await gate.waitForEntry()
        let replacement = try await environment.sessions.reserveReplacement(for: server.id)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await reader.value }
        #expect(replacement.isValid && previous.closes == 1)
        await environment.sessions.release(replacement)
    }

    @Test func cancellingDuringVerificationCannotAffectAConnectionAlreadyPublishedByItsRetry() async throws {
        let server = s3(), environment = Environment([server], secrets: [server.id: "Saved"]), gate = Gate()
        let oldBackend = Backend(listing: { await gate.enter() }), newBackend = Backend()
        let first = environment.connections.connect(server, secret: "First")
        await environment.factory.waitForCalls(1); await environment.factory.finish(0, oldBackend)
        await gate.waitForEntry()
        let second = environment.connections.connect(server, secret: "Second")
        await environment.factory.waitForCalls(2); await environment.factory.finish(1, newBackend)
        #expect(try await second.value == server)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(environment.store.saves == [server] && environment.store.secrets == [server.id: "Second"])
        #expect(oldBackend.closes == 1 && newBackend.closes == 0)
        #expect(try await environment.sessions.backend(for: server.id) === newBackend)
        await environment.sessions.disconnect(server.id)
    }

    @Test func changingLoginOrBackendRetiresCopiesButRenamingAndIdenticalSecretsPreserveThem() async throws {
        for change in 0..<5 {
            let server = s3(), environment = Environment([server], secrets: [server.id: "Saved"])
            var proposed = server
            if change == 0 { proposed.accessKeyID = "ANOTHERKEY" }
            if change == 1 { proposed.kind = .sftp }
            if change == 3 { proposed.name = "Renamed" }
            let secret: String? = change == 2 ? "Changed" : change == 4 ? "Saved" : nil
            let request = environment.connections.connect(proposed, secret: secret), backend = Backend()
            await environment.factory.waitForCalls(1); await environment.factory.finish(0, backend)
            #expect(try await request.value == proposed)
            #expect(environment.copies.discards == (change < 3 ? [server.id] : []))
            #expect(environment.copies.disconnected == (change < 3 ? [server.id] : []))
            #expect(environment.store.saves == [proposed])
            await environment.sessions.disconnect(server.id)
        }
    }

    @Test func completedAndCancelledWorkReleasesItsCoordinator() async throws {
        let server = s3(), environment = Environment()
        var connections: RemoteConnections? = RemoteConnections(catalog: environment.store.catalog, sessions: environment.sessions,
            connector: environment.factory.connector, discard: { _ in }, disconnected: { _ in })
        weak let weakConnections = connections
        let request = connections!.connect(server, secret: "Proposed")
        await environment.factory.waitForCalls(1)
        request.cancel()
        connections = nil
        let backend = Backend()
        await environment.factory.finish(0, backend)
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(weakConnections == nil && backend.closes == 1 && environment.store.saves.isEmpty)
    }

    @Test func changingTheSavedDefinitionWhileRetiringTheOldSessionPreventsCacheRemoval() async throws {
        let original = s3(), environment = Environment([original], secrets: [original.id: "Saved"])
        let existing = Backend(), proposedBackend = Backend(), gate = Gate()
        try await environment.seed(existing, for: original)
        await environment.status.holdDisconnection(gate)
        var proposed = original; proposed.host = "new.invalid"
        let request = environment.connections.connect(proposed, secret: "Proposed")
        await environment.factory.waitForCalls(1); await environment.factory.finish(0, proposedBackend)
        await gate.waitForEntry()
        environment.store.servers[0].name = "Changed elsewhere"
        let expected = environment.store.servers
        await gate.release()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(environment.copies.discards.isEmpty && environment.copies.disconnected.isEmpty)
        #expect(environment.store.servers == expected && environment.store.secrets == [original.id: "Saved"])
        #expect(environment.store.saves.isEmpty && existing.closes == 1 && proposedBackend.closes == 1)
    }

    @Test func staleRemovalAndDisconnectConfirmationsLeaveEditedServersAndPendingLoginsAlone() async throws {
        let original = s3(), neighbor = s3(), existing = Backend()
        var edited = original; edited.host = "edited.invalid"
        let environment = Environment([edited, neighbor], secrets: [original.id: "Edited", neighbor.id: "Neighbor"])
        try await environment.seed(existing, for: edited)
        let request = environment.connections.connect(edited)
        await environment.factory.waitForCalls(1)
        var forgotten = false
        #expect(environment.connections.remove(original, forget: { forgotten = true }) == nil)
        #expect(environment.connections.disconnect(original) == nil)
        #expect(!forgotten && !request.isCancelled && existing.closes == 0)
        #expect(environment.store.servers == [edited, neighbor])
        #expect(environment.store.secrets == [original.id: "Edited", neighbor.id: "Neighbor"])
        #expect(environment.copies.discards.isEmpty && environment.copies.disconnected.isEmpty)
        let backend = Backend()
        await environment.factory.finish(0, backend)
        #expect(try await request.value == edited)
        #expect(try await environment.sessions.backend(for: original.id) === backend)
        await environment.sessions.disconnect(original.id)
    }

    @Test func removalBlocksReadersUntilCleanupFinishesAndPreservesItsNeighbor() async throws {
        let server = s3(), neighbor = s3(), environment = Environment([server, neighbor],
            secrets: [server.id: "Removed", neighbor.id: "Neighbor"])
        let backend = Backend(), other = Backend(), gate = Gate()
        try await environment.seed(backend, for: server)
        try await environment.seed(other, for: neighbor)
        environment.copies.gate = gate
        let login = environment.connections.connect(server)
        await environment.factory.waitForCalls(1)
        let retirement = try #require(environment.connections.remove(server) { environment.store.remove(server.id) })
        #expect(login.isCancelled)
        #expect(environment.store.servers == [neighbor] && environment.store.secrets == [neighbor.id: "Neighbor"])
        await gate.waitForEntry()
        await #expect(throws: CancellationError.self) { try await environment.sessions.backend(for: server.id) }
        #expect(try await environment.sessions.backend(for: neighbor.id) === other)
        retirement.cancel()
        let late = Backend()
        await environment.factory.finish(0, late)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await login.value }
        #expect(await retirement.value)
        #expect(environment.copies.completed == [server.id] && environment.copies.disconnected == [server.id])
        #expect(backend.closes == 1 && late.closes == 1 && other.closes == 0)
        #expect(environment.store.saves.isEmpty)
        await environment.sessions.disconnect(neighbor.id)
    }

    private func expectWaitingHandoff(_ connections: RemoteConnections, serverID: String, after previous: UUID?) async {
        let deadline = ContinuousClock.now + .seconds(15)
        var turns = 0
        while turns < 128 && (ContinuousClock.now < deadline || turns < 16) {
            if let state = connections.handoffState(for: serverID), state.id != previous, state.phase != .queued {
                #expect(state.phase == .waiting)
                return
            }
            turns += 1
            await Task.yield()
        }
        Issue.record("The queued handoff never reached its prerequisite wait")
    }

    @Test func removalObserversCanReconnectWithoutOldCleanupErasingTheirConnection() async throws {
        let server = s3(), environment = Environment([server], secrets: [server.id: "Saved"])
        let existing = Backend(), backend = Backend(), gate = Gate()
        try await environment.seed(existing, for: server)
        environment.copies.gate = gate
        var request: RemoteConnectionRequest?
        environment.store.onSave = { #expect(environment.copies.completed == [server.id]) }
        defer { environment.store.onSave = nil }
        let retirement = try #require(environment.connections.remove(server) {
            environment.store.remove(server.id)
            request = environment.connections.connect(server, secret: "Reconnected")
        })
        await gate.waitForEntry()
        let retiringID = environment.connections.handoffState(for: server.id)?.id
        await environment.factory.waitForCalls(1)
        await environment.factory.finish(0, backend)
        await expectWaitingHandoff(environment.connections, serverID: server.id, after: retiringID)
        await gate.release()
        #expect(await retirement.value)
        #expect(try await #require(request).value == server)
        #expect(environment.store.servers == [server] && environment.store.secrets == [server.id: "Reconnected"])
        #expect(environment.copies.discards == [server.id] && environment.copies.disconnected == [server.id])
        #expect(existing.closes == 1 && backend.closes == 0)
        #expect(try await environment.sessions.backend(for: server.id) === backend)
        environment.store.onSave = nil
        await environment.sessions.disconnect(server.id)
    }

    @Test func disconnectWaitsForAnOlderHandoffAndReleasesItsCoordinator() async throws {
        let server = s3(), environment = Environment([server], secrets: [server.id: "Saved"]), gate = Gate()
        environment.copies.gate = gate
        var connections: RemoteConnections? = RemoteConnections(catalog: environment.store.catalog, sessions: environment.sessions,
            connector: environment.factory.connector, discard: { await environment.copies.discard($0) },
            disconnected: { environment.copies.disconnected.append($0) })
        weak let weakConnections = connections
        var proposed = server; proposed.host = "new.invalid"
        let request = connections!.connect(proposed, secret: "Proposed"), backend = Backend()
        await environment.factory.waitForCalls(1); await environment.factory.finish(0, backend)
        await gate.waitForEntry()
        let publishingID = connections!.handoffState(for: server.id)?.id
        let retirement = try #require(connections!.disconnect(server))
        await expectWaitingHandoff(connections!, serverID: server.id, after: publishingID)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await retirement.value)
        #expect(connections!.activeHandoffCount == 0)
        connections = nil
        #expect(weakConnections == nil)
        #expect(environment.store.servers == [server] && environment.store.secrets == [server.id: "Saved"])
        #expect(environment.copies.discards == [server.id, server.id])
        #expect(environment.copies.disconnected == [server.id] && backend.closes == 1)
        #expect(!(await environment.sessions.isConnected(server.id)))
    }

}
