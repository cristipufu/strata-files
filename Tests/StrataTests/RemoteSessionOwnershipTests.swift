import AppKit
import Foundation
import Synchronization
import Testing
@testable import Strata

struct RemoteSessionOwnershipTests {
    nonisolated private final class Backend: RemoteBackend {
        private struct State { var alive = true; var closes = 0 }
        private let state = Mutex(State())
        var closeCount: Int { state.withLock { $0.closes } }
        var isAlive: Bool { state.withLock { $0.alive } }
        func drop() { state.withLock { $0.alive = false } }
        func close() { state.withLock { $0.alive = false; $0.closes += 1 } }
        func home() async throws -> String { "/" }
        func list(_ path: String) async throws -> [ListedEntry] { [] }
        func kind(of path: String) async throws -> RemoteItemKind? { nil }
        func download(_ path: String, to destination: URL, limit: Int64,
                      progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws { throw RemoteError.unknownServer }
        func upload(_ source: URL, to path: String, modified: Date?,
                    progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws { throw RemoteError.unknownServer }
        func makeFolder(_ path: String) async throws { throw RemoteError.unknownServer }
        func rename(_ path: String, to newPath: String) async throws { throw RemoteError.unknownServer }
        func remove(_ path: String) async throws { throw RemoteError.unknownServer }
    }

    private enum Failure: Error { case refused }

    private actor Factory {
        private(set) var calls: [RemoteServer] = []
        private(set) var changes: [Bool] = []
        private(set) var cancelled: Set<Int> = []
        private var waiting: [Int: CheckedContinuation<any RemoteBackend, any Error>] = [:]
        private let held: Set<Int>
        private let holdStatus: Bool?
        private var statusWasHeld = false
        private var statusWaiter: CheckedContinuation<Void, Never>?
        private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var statusStartWaiters: [CheckedContinuation<Void, Never>] = []

        init(held: Set<Int> = [0, 1], holdStatus: Bool? = nil) {
            self.held = held
            self.holdStatus = holdStatus
        }

        func connect(_ server: RemoteServer) async throws -> any RemoteBackend {
            let index = calls.count
            calls.append(server)
            defer { if Task.isCancelled { cancelled.insert(index) } }
            let started = startWaiters.filter { $0.count <= calls.count }
            startWaiters.removeAll { $0.count <= calls.count }
            for waiter in started { waiter.continuation.resume() }
            if !held.contains(index) { return Backend() }
            return try await withCheckedThrowingContinuation { waiting[index] = $0 }
        }

        func finish(_ index: Int, with backend: Backend) { waiting.removeValue(forKey: index)?.resume(returning: backend) }
        func fail(_ index: Int) { waiting.removeValue(forKey: index)?.resume(throwing: Failure.refused) }
        func changed(_ connected: Bool) async {
            changes.append(connected)
            if holdStatus == connected && !statusWasHeld {
                statusWasHeld = true
                await withCheckedContinuation { continuation in
                    statusWaiter = continuation
                    let started = statusStartWaiters
                    statusStartWaiters.removeAll()
                    for waiter in started { waiter.resume() }
                }
            }
        }
        func releaseStatus() { statusWaiter?.resume(); statusWaiter = nil }
        func waitForHeldStatus() async {
            guard statusWaiter == nil else { return }
            await withCheckedContinuation { statusStartWaiters.append($0) }
        }

        func waitForCalls(_ count: Int) async {
            guard calls.count < count else { return }
            await withCheckedContinuation { startWaiters.append((count, $0)) }
        }

        // The cancelled-attempt mutation intentionally never calls the factory again. Poll on the same actor as
        // the test's request tasks, so waiting cannot expire while those tasks are still queued behind other suites.
        @MainActor func waitForReplacement() async -> Bool {
            for _ in 0..<500 {
                if await calls.count >= 2 { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

    }

    @Test func aNewConnectionDoesNotJoinTheCancelledAttempt() async throws {
        for oldFirst in [false, true] {
            for oldFails in [false, true] {
                let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
                let factory = Factory()
                let sessions = RemoteSessions(server: { $0 == server.id ? server : nil },
                    connect: { try await factory.connect($0) }, changed: { _, value in await factory.changed(value) })
                let old = Backend(), replacement = Backend()
                let first = Task { try await sessions.backend(for: server.id) }
                await factory.waitForCalls(1)
                let previous = try #require(await sessions.attemptCompletion(for: server.id))
                await sessions.disconnect(server.id)
                let second = Task { try await sessions.backend(for: server.id) }
                let restarted = await factory.waitForReplacement()
                #expect(restarted)
                let firstResult: Result<any RemoteBackend, any Error>
                let secondResult: Result<any RemoteBackend, any Error>
                if oldFirst || !restarted {
                    // The fallback also releases the cancelled request when testing the buggy implementation.
                    if oldFails { await factory.fail(0) } else { await factory.finish(0, with: old) }
                    firstResult = await first.result
                    await factory.finish(1, with: replacement)
                    secondResult = await second.result
                } else {
                    await factory.finish(1, with: replacement)
                    secondResult = await second.result
                    if oldFails { await factory.fail(0) } else { await factory.finish(0, with: old) }
                    firstResult = await first.result
                }
                await previous.value
                switch firstResult {
                case .success: Issue.record("The cancelled attempt returned a backend")
                case .failure(let error): #expect(error is CancellationError)
                }
                switch secondResult {
                case .success(let backend): #expect(backend === replacement && backend.isAlive)
                case .failure(let error): Issue.record(error)
                }
                #expect(old.closeCount == (oldFails ? 0 : 1) && replacement.closeCount == 0)
                #expect(await sessions.isConnected(server.id))
                #expect(await factory.calls == [server, server])
                #expect(await factory.changes == [true])
                await sessions.disconnect(server.id)
                #expect(replacement.closeCount == 1)
                #expect(await factory.changes == [true, false])
            }
        }
    }

    @Test func concurrentCallersShareThePublishedBackendAndUnknownServersNeverConnect() async throws {
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let factory = Factory(held: [0])
        let sessions = RemoteSessions(server: { $0 == server.id ? server : nil },
            connect: { try await factory.connect($0) }, changed: { _, value in await factory.changed(value) })
        await #expect(throws: RemoteError.unknownServer) { try await sessions.backend(for: "not-saved") }
        #expect(await factory.calls.isEmpty)
        let backend = Backend()
        let first = Task { try await sessions.backend(for: server.id) }
        await factory.waitForCalls(1)
        let others = (0..<12).map { _ in Task { try await sessions.backend(for: server.id) } }
        await factory.finish(0, with: backend)
        #expect(try await first.value === backend)
        for request in others { #expect(try await request.value === backend) }
        #expect(try await sessions.backend(for: server.id) === backend)
        #expect(await factory.calls == [server])
        #expect(await factory.changes == [true])
        await sessions.disconnect(server.id)
        await sessions.disconnect(server.id)
        #expect(backend.closeCount == 1)
        #expect(await factory.changes == [true, false])
    }

    @Test func disconnectionDuringStatusPublicationCannotReturnAClosedBackend() async throws {
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let factory = Factory(held: [0], holdStatus: true)
        let sessions = RemoteSessions(server: { $0 == server.id ? server : nil },
            connect: { try await factory.connect($0) }, changed: { _, value in await factory.changed(value) })
        let backend = Backend()
        let request = Task { try await sessions.backend(for: server.id) }
        await factory.waitForCalls(1)
        await factory.finish(0, with: backend)
        await factory.waitForHeldStatus()
        await sessions.disconnect(server.id)
        await factory.releaseStatus()
        switch await request.result {
        case .success: Issue.record("A disconnected backend escaped to its caller")
        case .failure(let error): #expect(error is CancellationError)
        }
        #expect(backend.closeCount == 1)
        #expect(await !sessions.isConnected(server.id))
        #expect(await factory.changes == [true, false])
    }

    @Test func independentPoolsKeepTheirOwnServersBackendsAndStatus() async throws {
        let first = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "First", host: "first.invalid")
        var second = first
        second.host = "second.invalid"
        let otherServer = second
        let a = Factory(held: [0]), b = Factory(held: [0])
        let left = RemoteSessions(server: { $0 == first.id ? first : nil },
            connect: { try await a.connect($0) }, changed: { _, value in await a.changed(value) })
        let right = RemoteSessions(server: { $0 == otherServer.id ? otherServer : nil },
            connect: { try await b.connect($0) }, changed: { _, value in await b.changed(value) })
        let leftBackend = Backend(), rightBackend = Backend()
        let leftRequest = Task { try await left.backend(for: first.id) }
        let rightRequest = Task { try await right.backend(for: first.id) }
        await a.waitForCalls(1)
        await b.waitForCalls(1)
        await a.finish(0, with: leftBackend)
        await b.finish(0, with: rightBackend)
        #expect(try await leftRequest.value === leftBackend)
        #expect(try await rightRequest.value === rightBackend)
        #expect(await a.calls == [first])
        #expect(await b.calls == [otherServer])
        await left.disconnect(first.id)
        #expect(leftBackend.closeCount == 1 && rightBackend.closeCount == 0)
        #expect(await right.isConnected(first.id))
        #expect(try await right.backend(for: first.id) === rightBackend)
        #expect(await a.changes == [true, false])
        #expect(await b.changes == [true])
        await right.disconnect(first.id)
        #expect(rightBackend.closeCount == 1)
    }

    @Test func aDroppedConnectionIsRetiredEvenWhenReconnectingFails() async throws {
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let factory = Factory()
        let sessions = RemoteSessions(server: { $0 == server.id ? server : nil },
            connect: { try await factory.connect($0) }, changed: { _, value in await factory.changed(value) })
        let backend = Backend()
        let first = Task { try await sessions.backend(for: server.id) }
        await factory.waitForCalls(1)
        await factory.finish(0, with: backend)
        #expect(try await first.value === backend)
        backend.drop()
        let retry = Task { try await sessions.backend(for: server.id) }
        await factory.waitForCalls(2)
        #expect(backend.closeCount == 1)
        #expect(await factory.changes == [true, false])
        await factory.fail(1)
        switch await retry.result {
        case .success: Issue.record("The failed connection succeeded")
        case .failure(let error): #expect(error is Failure)
        }
        #expect(await !sessions.isConnected(server.id))
        let repaired = try await sessions.backend(for: server.id)
        #expect(repaired.isAlive && repaired !== backend)
        #expect(await factory.calls == [server, server, server])
        #expect(await factory.changes == [true, false, true])
        await sessions.disconnect(server.id)
        #expect(!repaired.isAlive && backend.closeCount == 1)
        #expect(await factory.changes == [true, false, true, false])
    }


    @Test func reconnectingDuringDroppedStatusPublicationReusesTheNewConnection() async throws {
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let factory = Factory(holdStatus: false)
        let sessions = RemoteSessions(server: { $0 == server.id ? server : nil },
            connect: { try await factory.connect($0) }, changed: { _, value in await factory.changed(value) })
        let old = Backend(), replacement = Backend()
        let first = Task { try await sessions.backend(for: server.id) }
        await factory.waitForCalls(1)
        await factory.finish(0, with: old)
        #expect(try await first.value === old)
        old.drop()
        let noticing = Task { try await sessions.backend(for: server.id) }
        await factory.waitForHeldStatus()
        let reconnecting = Task { try await sessions.backend(for: server.id) }
        await factory.waitForCalls(2)
        await factory.finish(1, with: replacement)
        #expect(try await reconnecting.value === replacement)
        await factory.releaseStatus()
        #expect(try await noticing.value === replacement)
        #expect(old.closeCount == 1 && replacement.closeCount == 0)
        #expect(await factory.calls == [server, server])
        #expect(await factory.changes == [true, false, true])
        await sessions.disconnect(server.id)
        #expect(replacement.closeCount == 1)
    }

    @Test func cancellingOneReaderAfterPublicationLeavesTheSharedConnectionAlive() async throws {
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let factory = Factory(held: [0], holdStatus: true)
        let sessions = RemoteSessions(server: { $0 == server.id ? server : nil },
            connect: { try await factory.connect($0) }, changed: { _, value in await factory.changed(value) })
        let backend = Backend()
        let first = Task { try await sessions.backend(for: server.id) }
        await factory.waitForCalls(1)
        await factory.finish(0, with: backend)
        await factory.waitForHeldStatus()
        first.cancel()
        #expect(try await sessions.backend(for: server.id) === backend)
        await factory.releaseStatus()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(backend.closeCount == 0 && backend.isAlive)
        #expect(await factory.calls == [server])
        #expect(await factory.changes == [true])
        await sessions.disconnect(server.id)
        #expect(backend.closeCount == 1)
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test func cancellingOneOfTwoWaitersFinishesPromptlyWithoutStoppingTheirSharedLogin() async throws {
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let factory = Factory(held: [0])
        let sessions = RemoteSessions(server: { $0 == server.id ? server : nil },
            connect: { try await factory.connect($0) }, changed: { _, value in await factory.changed(value) })
        var firstFinished = false
        let first = Task { defer { firstFinished = true }; return try await sessions.backend(for: server.id) }
        await factory.waitForCalls(1)
        let producer = try #require(await sessions.attemptCompletion(for: server.id))
        let second = Task { try await sessions.backend(for: server.id) }
        #expect(await eventually { await sessions.waiterCount(for: server.id) == 2 })
        first.cancel()
        #expect(await eventually { firstFinished })
        #expect(await sessions.waiterCount(for: server.id) == 1)
        #expect(!producer.isCancelled)
        let backend = Backend()
        await factory.finish(0, with: backend)
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value === backend)
        await producer.value
        #expect(await factory.calls == [server])
        #expect(await factory.cancelled.isEmpty)
        #expect(backend.closeCount == 0 && backend.isAlive)
        #expect(await sessions.waiterCount(for: server.id) == 0)
        await sessions.disconnect(server.id)
    }

    @Test func theLastCancelledWaiterRetiresItsAttemptBeforeARetryInEitherCompletionOrder() async throws {
        for oldFirst in [false, true] {
            for oldFails in [false, true] {
                let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
                let factory = Factory()
                let sessions = RemoteSessions(server: { $0 == server.id ? server : nil },
                    connect: { try await factory.connect($0) }, changed: { _, value in await factory.changed(value) })
                let first = Task { try await sessions.backend(for: server.id) }
                await factory.waitForCalls(1)
                let producer = try #require(await sessions.attemptCompletion(for: server.id))
                first.cancel()
                await #expect(throws: CancellationError.self) { try await first.value }
                let second = Task { try await sessions.backend(for: server.id) }
                let restarted = await factory.waitForReplacement()
                #expect(restarted && producer.isCancelled)
                let old = Backend(), replacement = Backend()
                if oldFirst || !restarted {
                    if oldFails { await factory.fail(0) } else { await factory.finish(0, with: old) }
                    await producer.value
                }
                await factory.finish(1, with: replacement)
                if restarted { #expect(try await second.value === replacement) }
                else { _ = await second.result }
                if !oldFirst && restarted {
                    if oldFails { await factory.fail(0) } else { await factory.finish(0, with: old) }
                    await producer.value
                }
                #expect(old.closeCount == (oldFails ? 0 : 1) && replacement.closeCount == 0)
                #expect(await factory.cancelled == [0])
                if restarted { #expect(try await sessions.backend(for: server.id) === replacement) }
                #expect(await sessions.isConnected(server.id))
                #expect(await factory.changes == [true])
                await sessions.disconnect(server.id)
            }
        }
    }

    @Test func anAlreadyCancelledReaderCannotBorrowAnEstablishedBackend() async throws {
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let factory = Factory(held: [])
        let sessions = RemoteSessions(server: { $0 == server.id ? server : nil },
            connect: { try await factory.connect($0) }, changed: { _, value in await factory.changed(value) })
        let backend = try await sessions.backend(for: server.id)
        var gate: CheckedContinuation<Void, Never>?
        let request = Task {
            await withCheckedContinuation { gate = $0 }
            return try await sessions.backend(for: server.id)
        }
        #expect(await eventually { gate != nil })
        request.cancel()
        gate?.resume()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(backend.isAlive)
        #expect(try await sessions.backend(for: server.id) === backend)
        #expect(await factory.calls == [server])
        await sessions.disconnect(server.id)
    }

    @Test func cancellationDuringDroppedStatusCannotBorrowAnotherReadersReplacement() async throws {
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let factory = Factory(holdStatus: false)
        let sessions = RemoteSessions(server: { $0 == server.id ? server : nil },
            connect: { try await factory.connect($0) }, changed: { _, value in await factory.changed(value) })
        let old = Backend(), replacement = Backend()
        let first = Task { try await sessions.backend(for: server.id) }
        await factory.waitForCalls(1)
        await factory.finish(0, with: old)
        #expect(try await first.value === old)
        old.drop()
        let noticing = Task { try await sessions.backend(for: server.id) }
        await factory.waitForHeldStatus()
        let other = Task { try await sessions.backend(for: server.id) }
        await factory.waitForCalls(2)
        await factory.finish(1, with: replacement)
        #expect(try await other.value === replacement)
        noticing.cancel()
        await factory.releaseStatus()
        await #expect(throws: CancellationError.self) { try await noticing.value }
        #expect(old.closeCount == 1 && replacement.closeCount == 0)
        #expect(try await sessions.backend(for: server.id) === replacement)
        await sessions.disconnect(server.id)
    }

    private func views<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views($0, of: type) }
    }

    private final class BrowserEnvironment {
        let services: BrowserServices
        init(_ tree: TestTree, browsing: RemoteBrowsing,
             openContainer: @escaping @MainActor @Sendable (String) async throws -> URL = { _ in throw Failure.refused }) throws {
            let preferences = try Prefs.isolated()
            preferences.showIconPreviews = false
            let storage = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("state/Caches"), key: nil)
            let transfers = TransferQueue(preferences: preferences, history: OperationLog(storage: storage, copies: .live))
            services = BrowserServices.configured(
                transfers: transfers,
                visits: Frecency(preferences: preferences.defaults),
                windows: .headless,
                remote: .shared,
                containers: .shared,
                containerStore: .shared,
                clipboard: .shared,
                directories: DirectoryReader { _, _, _ in [] },
                remoteBrowsing: browsing,
                openContainer: openContainer)
        }
    }

    @Test func theNativeBrowserCancelButtonPreventsNavigationAfterADeferredReveal() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("local/", "server/")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let factory = Factory(held: []), revealGate = Factory(held: [], holdStatus: false)
        let sessions = RemoteSessions(server: { $0 == server.id ? server : nil },
            connect: { try await factory.connect($0) }, changed: { _, value in await factory.changed(value) })
        let top = tree.url("server")
        let browsing = RemoteBrowsing(prepare: { _ in top }, backend: { try await sessions.backend(for: $0) },
            reveal: { _ in await revealGate.changed(false); return true })
        let environment = try BrowserEnvironment(tree, browsing: browsing)
        let window = BrowserWindowController(location: tree.url("local"), services: environment.services)
        defer { window.window?.close(); withExtendedLifetime(environment) {} }
        let before = tree.snapshot(), originalLocation = window.location
        let opening = window.openServer(server)
        await revealGate.waitForHeldStatus()
        let backend = try await sessions.backend(for: server.id)
        let cancel = try #require(views(window.split.noticeBar.view, of: NSButton.self).first)
        #expect(cancel.sendAction(cancel.action, to: cancel.target))
        await revealGate.releaseStatus()
        await opening.value
        #expect(window.location == originalLocation)
        #expect(window.split.noticeBar.isHidden && window.window?.attachedSheet == nil)
        #expect(backend.isAlive)
        #expect(try await sessions.backend(for: server.id) === backend)
        await sessions.disconnect(server.id)
        #expect(tree.snapshot() == before)
    }

    @Test func aDeferredServerOpeningKeepsItsOriginalPaneWhenFocusChanges() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("local/", "other/", "server/")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let gate = Factory(held: [], holdStatus: false), backend = Backend(), top = tree.url("server")
        let browsing = RemoteBrowsing(prepare: { _ in top }, backend: { _ in backend },
            reveal: { _ in await gate.changed(false); return true })
        let environment = try BrowserEnvironment(tree, browsing: browsing)
        let window = BrowserWindowController(location: tree.url("local"), services: environment.services)
        defer { window.window?.close(); withExtendedLifetime(environment) {} }
        let before = tree.snapshot(), original = window.pane
        window.toggleDualPane(at: tree.url("other"))
        let opening = window.openServer(server)
        await gate.waitForHeldStatus()
        window.focusOtherPane(nil)
        let focused = window.pane, focusedLocation = window.location
        await gate.releaseStatus()
        await opening.value
        #expect(window.pane === focused)
        #expect(window.location == focusedLocation)
        #expect(original.location == top.standardizedFileURL)
        #expect(original.backStack == [.folder(tree.url("local").standardizedFileURL)])
        #expect(focused.backStack.isEmpty)
        #expect(tree.snapshot() == before)
    }

    @Test func navigatingAwayAndBackDiscardsADeferredServerOpening() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("local/", "other/", "server/")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let gate = Factory(held: [], holdStatus: false), backend = Backend(), top = tree.url("server")
        let browsing = RemoteBrowsing(prepare: { _ in top }, backend: { _ in backend },
            reveal: { _ in await gate.changed(false); return true })
        let environment = try BrowserEnvironment(tree, browsing: browsing)
        let window = BrowserWindowController(location: tree.url("local"), services: environment.services)
        defer { window.window?.close(); withExtendedLifetime(environment) {} }
        let before = tree.snapshot(), originalLocation = window.location
        let opening = window.openServer(server)
        await gate.waitForHeldStatus()
        window.navigate(to: tree.url("other"))
        window.navigate(to: originalLocation)
        let history = window.pane.backStack
        await gate.releaseStatus()
        await opening.value
        #expect(window.location == originalLocation)
        #expect(window.pane.backStack == history)
        #expect(window.window?.attachedSheet == nil)
        #expect(tree.snapshot() == before)
    }

    @Test func closingAnOpeningPaneCancelsItsRequestWithoutMovingTheRemainingPane() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("local/", "other/", "server/")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let gate = Factory(held: [], holdStatus: false), backend = Backend(), top = tree.url("server")
        let browsing = RemoteBrowsing(prepare: { _ in top }, backend: { _ in backend },
            reveal: { _ in await gate.changed(false); return true })
        let environment = try BrowserEnvironment(tree, browsing: browsing)
        let window = BrowserWindowController(location: tree.url("local"), services: environment.services)
        defer { window.window?.close(); withExtendedLifetime(environment) {} }
        let before = tree.snapshot()
        window.toggleDualPane(at: tree.url("other"))
        let opening = window.openServer(server)
        await gate.waitForHeldStatus()
        window.focusOtherPane(nil)
        let retained = window.pane, destination = window.location
        window.toggleDualPane(nil)
        #expect(opening.isCancelled)
        await gate.releaseStatus()
        await opening.value
        #expect(window.pane === retained && window.location == destination)
        #expect(window.window?.attachedSheet == nil)
        #expect(tree.snapshot() == before)
    }

    @Test func containerOpeningsUseTheSamePaneOwnershipAndNavigationCancellation() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("local/", "other/", "container/")
        for navigateAway in [false, true] {
            let gate = Factory(held: [], holdStatus: false), backend = Backend(), top = tree.url("container")
            let browsing = RemoteBrowsing(prepare: { _ in top }, backend: { _ in backend }, reveal: { _ in true })
            let environment = try BrowserEnvironment(tree, browsing: browsing, openContainer: { id in
                #expect(id == "fixture")
                await gate.changed(false)
                return top
            })
            let window = BrowserWindowController(location: tree.url("local"), services: environment.services)
            let before = tree.snapshot(), origin = window.pane
            window.toggleDualPane(at: tree.url("other"))
            let opening = window.openContainer("fixture")
            await gate.waitForHeldStatus()
            if navigateAway { window.navigate(to: tree.url("other")) }
            window.focusOtherPane(nil)
            let focused = window.pane, destination = window.location
            await gate.releaseStatus()
            await opening.value
            #expect(window.pane === focused && window.location == destination)
            #expect(origin.location == tree.url(navigateAway ? "other" : "container").standardizedFileURL)
            #expect(opening.isCancelled == navigateAway)
            window.window?.close()
            #expect(tree.snapshot() == before)
            withExtendedLifetime(environment) {}
        }
    }

    @Test func aPendingOpeningNoticeFollowsItsPaneAndSurvivesOldListingFailures() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("local/", "other/", "server/")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let gate = Factory(held: [], holdStatus: false), backend = Backend(), top = tree.url("server")
        let browsing = RemoteBrowsing(prepare: { _ in top }, backend: { _ in backend },
            reveal: { _ in await gate.changed(false); return true })
        let environment = try BrowserEnvironment(tree, browsing: browsing)
        let window = BrowserWindowController(location: tree.url("local"), services: environment.services)
        defer { window.window?.close(); withExtendedLifetime(environment) {} }
        let before = tree.snapshot(), original = window.pane
        window.toggleDualPane(at: tree.url("other"))
        let opening = window.openServer(server)
        await gate.waitForHeldStatus()
        #expect(!window.split.noticeBar.isHidden)
        window.focusOtherPane(nil)
        #expect(window.split.noticeBar.isHidden)
        window.focusOtherPane(nil)
        #expect(window.pane === original && !window.split.noticeBar.isHidden)
        window.containerCopyProblem(Notification(name: .containerCopyProblem,
            userInfo: ["folder": original.location, "message": "Old listing failure"]))
        let cancel = try #require(views(window.split.noticeBar.view, of: NSButton.self).first)
        #expect(cancel.title == String(localized: "Cancel"))
        #expect(cancel.sendAction(cancel.action, to: cancel.target))
        #expect(opening.isCancelled && window.split.noticeBar.isHidden)
        await gate.releaseStatus()
        await opening.value
        #expect(window.location == tree.url("local").standardizedFileURL)
        #expect(tree.snapshot() == before)
    }

    @Test func enteringADeeperColumnCancelsAPendingOpeningButReportingTheSameFolderDoesNot() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("local/child/", "server/")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let gate = Factory(held: [], holdStatus: false), backend = Backend(), top = tree.url("server")
        let browsing = RemoteBrowsing(prepare: { _ in top }, backend: { _ in backend },
            reveal: { _ in await gate.changed(false); return true })
        let environment = try BrowserEnvironment(tree, browsing: browsing)
        let window = BrowserWindowController(location: tree.url("local"), services: environment.services)
        defer { window.window?.close(); withExtendedLifetime(environment) {} }
        let before = tree.snapshot(), original = window.location
        let opening = window.openServer(server)
        await gate.waitForHeldStatus()
        window.browser(window.browser, columnLocationChanged: original)
        #expect(!opening.isCancelled)
        window.browser(window.browser, columnLocationChanged: tree.url("local/child"))
        #expect(opening.isCancelled && window.split.noticeBar.isHidden)
        await gate.releaseStatus()
        await opening.value
        #expect(window.location == original)
        #expect(window.pane.columnLocation == tree.url("local/child"))
        #expect(tree.snapshot() == before)
    }

    @Test func closingAWindowCancelsItsOpeningBeforeTheBackendFinishes() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("local/", "server/")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let gate = Factory(held: [], holdStatus: false), backend = Backend(), top = tree.url("server")
        let browsing = RemoteBrowsing(prepare: { _ in top }, backend: { _ in backend },
            reveal: { _ in await gate.changed(false); return true })
        let environment = try BrowserEnvironment(tree, browsing: browsing)
        let window = BrowserWindowController(location: tree.url("local"), services: environment.services)
        let before = tree.snapshot(), original = window.location
        let opening = window.openServer(server)
        await gate.waitForHeldStatus()
        window.window?.close()
        #expect(opening.isCancelled && window.isClosed)
        await gate.releaseStatus()
        await opening.value
        #expect(window.location == original && window.window?.attachedSheet == nil)
        #expect(tree.snapshot() == before)
        withExtendedLifetime(environment) {}
    }

    @Test func theNativeWorkspaceCancelButtonLeavesAnotherPanesLoginRunning() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("server/")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let factory = Factory(held: [0])
        let sessions = RemoteSessions(server: { $0 == server.id ? server : nil },
            connect: { try await factory.connect($0) }, changed: { _, value in await factory.changed(value) })
        let top = tree.url("server")
        let browsing = RemoteBrowsing(prepare: { _ in top }, backend: { try await sessions.backend(for: $0) }, reveal: { _ in true })
        let sheet = WorkspaceConnectController()
        sheet.show(server.name)
        let before = tree.snapshot()
        var finished = false
        let opening = Task { defer { finished = true }; try await sheet.connect(server, using: browsing) }
        await factory.waitForCalls(1)
        let producer = try #require(await sessions.attemptCompletion(for: server.id))
        let other = Task { try await sessions.backend(for: server.id) }
        #expect(await eventually { await sessions.waiterCount(for: server.id) == 2 })
        let cancel = try #require(views(sheet.view, of: NSButton.self).first)
        #expect(cancel.sendAction(cancel.action, to: cancel.target))
        #expect(await eventually { finished })
        #expect(sheet.isCancelled && sheet.onCancel == nil && !producer.isCancelled)
        let backend = Backend()
        await factory.finish(0, with: backend)
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(try await other.value === backend)
        await producer.value
        #expect(backend.closeCount == 0)
        await #expect(throws: CancellationError.self) { try await sheet.connect(server, using: browsing) }
        #expect(await factory.calls == [server])
        await sessions.disconnect(server.id)
        #expect(tree.snapshot() == before)
    }

    @Test func cancellingServerResolutionDoesNotReturnALateFolder() async throws {
        let tree = try TestTree("server/")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let backend = Backend(), top = tree.url("server")
        let gate = Factory(held: [], holdStatus: false)
        let browsing = RemoteBrowsing(prepare: { _ in top }, backend: { _ in backend },
            reveal: { _ in await gate.changed(false); return true })
        let before = tree.snapshot()
        let request = Task { try await browsing.open(server) }
        await gate.waitForHeldStatus()
        request.cancel()
        await gate.releaseStatus()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(backend.isAlive && backend.closeCount == 0)
        #expect(tree.snapshot() == before)
    }

    @Test func openingAServerKeepsItsStartingFolderAndMissingFolderFallback() async throws {
        let tree = try TestTree("server/", "server/nested/")
        let base = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let backend = Backend(), top = tree.url("server"), nested = tree.url("server/nested")
        let before = tree.snapshot()
        for hasPath in [false, true] {
            for found in [false, true] {
                var definition = base; definition.path = hasPath ? "/nested" : nil
                let server = definition
                let expected = hasPath && found ? nested : top
                let browsing = RemoteBrowsing(prepare: { value in #expect(value == server); return top },
                    backend: { id in #expect(id == server.id); return backend },
                    reveal: { url in #expect(url == (hasPath ? nested : top)); return found })
                #expect(try await browsing.open(server).standardizedFileURL == expected.standardizedFileURL)
                try await browsing.connect(server)
            }
        }
        #expect(backend.closeCount == 0)
        #expect(tree.snapshot() == before)
    }

}
