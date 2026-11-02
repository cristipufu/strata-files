import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct ServerMountSessionTests {
    private actor Mounts {
        private(set) var addresses: [URL] = []
        private(set) var cancelled: [Int: Bool] = [:]
        private var waiting: [Int: CheckedContinuation<ServerMounter.Result, Never>] = [:]
        private var started: [(Int, CheckedContinuation<Void, Never>)] = []

        func mount(_ url: URL, request: ServerConnection.Request) async -> ServerMounter.Result {
            let index = addresses.count
            addresses.append(url)
            let result = await withCheckedContinuation { continuation in
                waiting[index] = continuation
                let ready = started.filter { $0.0 <= addresses.count }
                started.removeAll { $0.0 <= addresses.count }
                for (_, waiter) in ready { waiter.resume() }
            }
            cancelled[index] = Task.isCancelled
            return result
        }

        func waitForStarts(_ count: Int) async {
            if addresses.count >= count { return }
            await withCheckedContinuation { started.append((count, $0)) }
        }

        func finish(_ index: Int, _ result: ServerMounter.Result) {
            waiting.removeValue(forKey: index)?.resume(returning: result)
        }

        nonisolated var mounter: ServerMounter { ServerMounter { await self.mount($0, request: $1) } }
    }

    private let address = URL(string: "smb://fixture/share")!
    private let destination = URL(fileURLWithPath: "/Volumes/Fixture-Only-A-Value")

    @Test func cancelledResultsNeverCompleteOrClearANewerAttempt() async {
        for oldFirst in [true, false] {
            for result: ServerMounter.Result in [.success(destination), .failure(.init(message: "Old failure")), nil] {
                let driver = Mounts()
                // Every case has its own driver and owner, including both completion orders.
                let owned = ServerMountSession(mounter: driver.mounter)
                var received: [ServerMounter.Result] = []
                let old = owned.connect(address) { received.append($0) }
                await driver.waitForStarts(1)
                owned.cancel()
                #expect(!owned.isConnecting && owned.task == nil)
                let replacement = owned.connect(address) { received.append($0) }
                await driver.waitForStarts(2)
                if oldFirst {
                    await driver.finish(0, result)
                    await old.value
                    #expect(owned.isConnecting && owned.task != nil)
                    #expect(received.isEmpty)
                }
                await driver.finish(1, .success(destination))
                await replacement.value
                #expect(!owned.isConnecting && owned.task == nil)
                if !oldFirst { await driver.finish(0, result); await old.value }
                #expect(received == [.success(destination)])
                #expect(await driver.cancelled == [0: true, 1: false])
            }
        }
    }

    @Test func replacingAndReleasingAnOwnerCancelOnlyItsRequest() async {
        let driver = Mounts()
        var owner: ServerMountSession? = ServerMountSession(mounter: driver.mounter)
        weak var weakOwner: ServerMountSession?
        weakOwner = owner
        let other = ServerMountSession(mounter: driver.mounter)
        var received: [String] = []
        let first = owner!.connect(address) { _ in received.append("first") }
        await driver.waitForStarts(1)
        let independent = other.connect(address) { _ in received.append("other") }
        await driver.waitForStarts(2)
        let replacement = owner!.connect(address) { _ in received.append("replacement") }
        await driver.waitForStarts(3)
        owner = nil
        #expect(weakOwner == nil)
        await driver.finish(0, .success(destination)); await first.value
        await driver.finish(2, .failure(.init(message: "Late failure"))); await replacement.value
        #expect(other.isConnecting)
        await driver.finish(1, .success(destination)); await independent.value
        #expect(received == ["other"])
        #expect(await driver.cancelled == [0: true, 1: false, 2: true])
    }

    @Test func currentFailureAndNativeCancellationFinishWithoutBlockingRetry() async {
        let driver = Mounts(), problem = ServerConnection.Problem(message: "Fixture failure")
        let owner = ServerMountSession(mounter: driver.mounter)
        var received: [ServerMounter.Result] = []
        for result: ServerMounter.Result in [.failure(problem), nil, .success(destination)] {
            let task = owner.connect(address) { received.append($0) }
            let count = received.count + 1
            await driver.waitForStarts(count)
            await driver.finish(count - 1, result)
            await task.value
            #expect(!owner.isConnecting && owner.task == nil)
        }
        #expect(received == [.failure(problem), nil, .success(destination)])
    }

    @Test func aCompletionCanStartAnotherAttemptWithoutLosingItsOwnership() async throws {
        let driver = Mounts()
        let session = ServerMountSession(mounter: driver.mounter)
        var second: Task<Void, Never>?
        var received: [URL] = []
        let first = session.connect(address) { result in
            if case .success(let url) = result { received.append(url) }
            second = session.connect(address) { result in
                if case .success(let url) = result { received.append(url) }
            }
        }
        await driver.waitForStarts(1)
        await driver.finish(0, .success(destination)); await first.value
        await driver.waitForStarts(2)
        #expect(session.isConnecting && session.task != nil)
        await driver.finish(1, .success(destination))
        await (try #require(second)).value
        #expect(received == [destination, destination])
        #expect(!session.isConnecting)
    }

    @Test func cancellingTheTaskBeforeOrAfterMountStartsSuppressesItsResult() async {
        for beforeStart in [true, false] {
            let driver = Mounts(), owner = ServerMountSession(mounter: driver.mounter)
            var callbacks = 0
            let work = owner.connect(address) { _ in callbacks += 1 }
            if !beforeStart { await driver.waitForStarts(1) }
            work.cancel()
            await driver.waitForStarts(1)
            await driver.finish(0, .success(destination)); await work.value
            #expect(callbacks == 0)
            #expect(!owner.isConnecting && owner.task == nil)
            #expect(await driver.cancelled == [0: true])
        }
    }

    private func views<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views($0, of: type) }
    }

    @Test func nativeSheetIgnoresLateMountResultsAndKeepsItsOwnRecents() async throws {
        _ = NSApplication.shared
        let settings = ServerConnectionSettings(preferences: try Prefs.isolated())
        let driver = Mounts()
        let owned = ServerMountSession(mounter: driver.mounter)
        let sheet = ConnectToServerController(settings: settings, mounts: owned, connections: .shared)
        let addressField = try #require(views(sheet.view, of: NSComboBox.self).first)
        let picker = try #require(views(sheet.view, of: NSSegmentedControl.self).first)
        let buttons = views(sheet.view, of: NSButton.self)
        let connect = try #require(buttons.first { $0.action == NSSelectorFromString("connect:") })
        let cancel = try #require(buttons.first { $0.action == NSSelectorFromString("cancel:") })
        var connected: [URL] = []
        sheet.onConnected = { connected.append($0) }
        addressField.stringValue = "smb://old/share"
        #expect(settings.kind == .share)
        #expect(picker.selectedSegment == 0)
        #expect(connect.target === sheet)
        #expect(addressField.stringValue == "smb://old/share")
        #expect(connect.sendAction(connect.action, to: connect.target))
        let old = try #require(owned.task)
        await driver.waitForStarts(1)
        #expect(!connect.isEnabled && !picker.isEnabled && !addressField.isEnabled)
        #expect(cancel.sendAction(cancel.action, to: cancel.target))
        #expect(connect.isEnabled && picker.isEnabled && addressField.isEnabled)
        addressField.stringValue = "smb://user:fixture-password@new/share"
        #expect(connect.sendAction(connect.action, to: connect.target))
        let current = try #require(owned.task)
        await driver.waitForStarts(2)
        await driver.finish(0, .success(destination)); await old.value
        #expect(!connect.isEnabled && !picker.isEnabled && !addressField.isEnabled)
        #expect(settings.recents.isEmpty && connected.isEmpty)
        await driver.finish(1, .success(destination)); await current.value
        #expect(connect.isEnabled && picker.isEnabled && addressField.isEnabled)
        #expect(settings.recents == ["smb://user@new/share"])
        #expect(connected == [destination])
        withExtendedLifetime((sheet, settings)) {}
    }

    @Test func releasingTheSheetCancelsEvenWhenItsSessionIsRetained() async throws {
        _ = NSApplication.shared
        let settings = ServerConnectionSettings(preferences: try Prefs.isolated())
        let driver = Mounts(), owned = ServerMountSession(mounter: driver.mounter)
        var sheet: ConnectToServerController? = ConnectToServerController(settings: settings, mounts: owned, connections: .shared)
        weak var weakSheet: ConnectToServerController?
        weakSheet = sheet
        var callbacks = 0
        sheet!.onConnected = { _ in callbacks += 1 }
        let addressField = try #require(views(sheet!.view, of: NSComboBox.self).first)
        addressField.stringValue = address.absoluteString
        let connect = try #require(views(sheet!.view, of: NSButton.self).first {
            $0.action == NSSelectorFromString("connect:")
        })
        #expect(settings.kind == .share)
        #expect(connect.target === sheet)
        #expect(connect.sendAction(connect.action, to: connect.target))
        let work = try #require(owned.task)
        await driver.waitForStarts(1)
        sheet = nil
        #expect(weakSheet == nil)
        #expect(!owned.isConnecting && owned.task == nil)
        await driver.finish(0, .success(destination)); await work.value
        #expect(callbacks == 0 && settings.recents.isEmpty)
        #expect(await driver.cancelled == [0: true])
        withExtendedLifetime(settings) {}
    }
}
