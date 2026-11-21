import AppKit
import CryptoKit
import Security
import Testing
@testable import Strata
@testable import StrataConnections
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSupport

/// Stands in for macOS: records each disk it's asked to eject and holds it until the test answers for that disk.
private actor HeldUnmounts {
    private(set) var asked: [URL] = []
    private var held: [(volume: URL, answer: CheckedContinuation<Void, any Error>)] = []
    private var arrival: CheckedContinuation<Void, Never>?

    func unmount(_ volume: URL) async throws {
        asked.append(volume)
        arrival?.resume()
        arrival = nil
        try await withCheckedThrowingContinuation { held.append((volume, $0)) }
    }

    func waitForAsks(_ count: Int) async {
        while asked.count < count { await withCheckedContinuation { arrival = $0 } }
    }

    /// Answers the eject of `volume`, however its path is spelled; when none is waiting, the oldest, so that nothing
    /// waits for good.
    func answer(_ volume: URL, throwing error: (any Error)? = nil) {
        guard !held.isEmpty else {
            Issue.record("No eject is waiting for an answer")
            return
        }
        var index = 0
        if let match = held.firstIndex(where: { PathSpelling.short($0.volume) == PathSpelling.short(volume) }) {
            index = match
        } else {
            Issue.record("No eject of \(volume.path) is waiting; the oldest is answered instead")
        }
        let answer = held.remove(at: index).answer
        if let error { answer.resume(throwing: error) } else { answer.resume() }
    }
}

/// The time an eject waits for macOS, passed when the test says so; cancelling a wait ends it at once.
private actor Deadline {
    private var passed = false
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]

    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if passed || Task.isCancelled { continuation.resume() } else { waiting[id] = continuation }
            }
        } onCancel: {
            Task { await self.release(id) }
        }
    }

    func pass() {
        passed = true
        waiting.values.forEach { $0.resume() }
        waiting = [:]
    }

    private func release(_ id: UUID) { waiting.removeValue(forKey: id)?.resume() }
}

/// The disks the places read lists; a read can be held to show what's offered before it lands.
private actor DiskList {
    private let disks: [Place]
    private var holding = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ disks: [Place]) { self.disks = disks }

    func snapshot() async -> PlaceChecks.Snapshot {
        if holding { await withCheckedContinuation { waiting.append($0) } }
        return PlaceChecks.Snapshot(volumes: disks)
    }

    func hold() { holding = true }

    func release() {
        holding = false
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// What the environment reported, kept where its report closures can add to it.
@MainActor private final class Reports<Item> {
    var items: [Item] = []
}

/// A window that takes clicks as the front one does, without ever being shown.
private final class ClickWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// The eject button, its menus and ⌘E share one owner: it hands macOS only the root of a disk the latest read lists as
/// ejectable, once until it answers. Panes on the disk go Home before it's asked, and stay there.
@MainActor struct VolumeEjectorTests {
    private static func disk(_ url: URL, named title: String, ejectable: Bool = true) -> Place {
        Place(title: title, url: url, symbol: ejectable ? "externaldrive" : "internaldrive", isEjectable: ejectable)
    }

    private static func volumes(_ paths: String...) -> [URL] {
        paths.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// An environment whose disks are `list`'s, whose ejects `unmounts` answers, and whose Home is `home`.
    private static func environment(_ list: DiskList, unmounts: HeldUnmounts, home: URL,
                                    patience: @escaping VolumeEjector.Patience = { await Deadline().wait() },
                                    notifications: NotificationCenter = NotificationCenter(),
                                    failed: @escaping VolumeEjector.Report = { _, _ in }) async throws -> IndependentEnvironment {
        let environment = try IndependentEnvironment(readPlaces: { _ in await list.snapshot() },
                                                     unmount: { try await unmounts.unmount($0) }, ejectPatience: patience,
                                                     ejectFailed: failed, workspaceNotifications: notifications, homeFolder: home)
        environment.preferences.favoritePaths = []
        await read(environment.services.places)
        return environment
    }

    private static func read(_ places: PlaceChecks) async {
        places.refresh()
        while let read = places.task { await read.value }
    }

    private static func paths(_ urls: [URL]) -> [String] { urls.map { PathSpelling.short($0) }.sorted() }

    /// Lets the main actor run until `condition` holds, for at most ten thousand turns.
    private static func turns(until condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
    }

    /// Until the read begun after its eject lands, an ejected disk is refused.
    private static func readAgain(_ disk: Place, by ejector: VolumeEjector) async throws {
        await turns { !ejector.isEjecting(disk.url) }
        try #require(!ejector.isEjecting(disk.url))
    }

    @Test func onlyTheRootOfAnEjectableDiskInTheLatestReadCanBeEjected() throws {
        let urls = Self.volumes("/Volumes/a", "/Volumes/ab", "/Volumes/a 1", "/Volumes/Data")
        let a = Self.disk(urls[0], named: "a"), ab = Self.disk(urls[1], named: "ab"), a1 = Self.disk(urls[2], named: "a 1")
        let data = Self.disk(urls[3], named: "Data", ejectable: false)
        // Even listed as ejectable, the startup disk never is.
        let startup = Self.disk(URL(filePath: "/", directoryHint: .isDirectory), named: "Macintosh HD")
        let disks = [startup, data, a, ab, a1]
        func decided(_ path: String, refused: Set<String> = []) -> Place? {
            VolumeEjector.volume(URL(filePath: path), in: VolumeEjector.ejectable(disks, except: refused))
        }
        #expect(decided("/Volumes/a") == a)
        #expect(decided("/Volumes/a/") == a)
        #expect(decided("/Volumes/./a") == a)
        #expect(decided("/Volumes/ab") == ab)
        #expect(decided("/Volumes/a 1") == a1)
        #expect(decided("/") == nil)
        #expect(decided("/Volumes/Data") == nil)
        #expect(decided("/Volumes/a/folder") == nil)
        #expect(decided("/Volumes") == nil)
        #expect(decided("/Volumes/gone") == nil)
        let web = try #require(URL(string: "https://example.com/Volumes/a"))
        #expect(VolumeEjector.volume(web, in: VolumeEjector.ejectable(disks, except: [])) == nil)
        // A disk already ejecting, or ejected and not yet read again, is refused; its look-alikes aren't.
        let refused: Set<String> = [VolumeEjector.key(a.url)]
        #expect(decided("/Volumes/a", refused: refused) == nil)
        #expect(decided("/Volumes/ab", refused: refused) == ab)
        #expect(decided("/Volumes/a 1", refused: refused) == a1)
    }

    @Test func aLocationIsOnADiskOnlyByWholePathComponents() {
        let a = URL(filePath: "/Volumes/a/", directoryHint: .isDirectory)
        for inside in ["/Volumes/a", "/Volumes/a/", "/Volumes/a/folder", "/Volumes/a/folder/deeper"] {
            #expect(VolumeEjector.isOnVolume(URL(filePath: inside), a), "\(inside)")
        }
        for outside in ["/Volumes/ab", "/Volumes/ab/folder", "/Volumes/a 1", "/Volumes/a.txt", "/Volumes", "/", "/Users/someone"] {
            #expect(!VolumeEjector.isOnVolume(URL(filePath: outside), a), "\(outside)")
        }
        #expect(!VolumeEjector.isOnVolume(URL(filePath: "/Users/someone"), URL(filePath: "/")))
    }

    @Test(.timeLimit(.minutes(2)))
    func eachDiskIsHandedToMacOSOnceUntilItAnswersAndAnEjectedOneStaysRefusedUntilReadAgain() async throws {
        let tree = try TestTree("Home/")
        let urls = Self.volumes("/Volumes/strata-test-a", "/Volumes/strata-test-ab", "/Volumes/strata-test-a 1")
        let a = Self.disk(urls[0], named: "a"), ab = Self.disk(urls[1], named: "ab"), a1 = Self.disk(urls[2], named: "a 1")
        let list = DiskList([a, ab, a1]), unmounts = HeldUnmounts()
        let failures = Reports<String>(), ejectors = Reports<VolumeEjector>(), stillEjecting = Reports<Bool>()
        let environment = try await Self.environment(list, unmounts: unmounts, home: tree.url("Home"), failed: { failure, _ in
            failures.items.append(failure.name)
            stillEjecting.items.append(ejectors.items.first?.isEjecting(a.url) ?? true)
        })
        let ejector = environment.services.volumeEjector
        ejectors.items.append(ejector)
        let ejected = Reports<URL>()
        let observer = NotificationCenter.default.addObserver(forName: .volumeEjected, object: ejector, queue: nil) { note in
            let volume = note.userInfo?[VolumeEjector.volumeKey] as? URL
            MainActor.assumeIsolated { if let volume { ejected.items.append(volume) } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Two disks at once: one fails, the other is ejected.
        let first = try #require(ejector.eject(a.url, from: nil))
        try #require(ejector.eject(a.url, from: nil) == nil, "A second request while it ejects asks nothing more")
        #expect(ejector.eject(URL(filePath: "/Volumes/strata-test-a"), from: nil) == nil)
        #expect(ejector.isEjecting(a.url) && !ejector.isEjecting(ab.url) && !ejector.isEjecting(a1.url))
        #expect(ejector.ejectable([a.url, ab.url, a1.url]) == [ab.url, a1.url])
        await unmounts.waitForAsks(1)
        let other = try #require(ejector.eject(ab.url, from: nil))
        await unmounts.waitForAsks(2)
        #expect(await unmounts.asked == [a.url, ab.url])

        await unmounts.answer(a.url, throwing: CocoaError(.fileWriteNoPermission))
        await first.value
        #expect(!ejector.isEjecting(a.url) && ejector.isEjecting(ab.url))
        #expect(failures.items == ["a"])
        #expect(stillEjecting.items == [false], "A failure dialog doesn't keep the disk ejecting while it's up")
        #expect(ejected.items.isEmpty)

        let retry = try #require(ejector.eject(a.url, from: nil))
        await unmounts.waitForAsks(3)
        // Ejected, but still listed until the read begun since lands: offering it again would only fail.
        await list.hold()
        await unmounts.answer(ab.url)
        await other.value
        #expect(ejected.items == [ab.url])
        #expect(ejector.isEjecting(ab.url) && ejector.ejectable([ab.url]).isEmpty)
        #expect(ejector.eject(ab.url, from: nil) == nil)
        await list.release()
        await Self.turns { !ejector.isEjecting(ab.url) }
        #expect(!ejector.isEjecting(ab.url), "A read that still lists the disk offers it again: it was mounted again")

        await unmounts.answer(a.url)
        await retry.value
        #expect(await unmounts.asked == [a.url, ab.url, a.url])
        #expect(ejected.items == [ab.url, a.url])
        #expect(failures.items.count == 1)
        #expect(ejector.tasks.isEmpty)
        #expect(tree.snapshot() == ["Home/"])
    }

    @Test(.timeLimit(.minutes(2)))
    func aDiskThatDoesntAnswerIsReportedAndStaysEjectingUntilMacOSAnswersLate() async throws {
        let tree = try TestTree("Home/")
        let a = Self.disk(URL(filePath: "/Volumes/strata-test-a", directoryHint: .isDirectory), named: "a")
        let b = Self.disk(URL(filePath: "/Volumes/strata-test-b", directoryHint: .isDirectory), named: "b")
        let unmounts = HeldUnmounts(), deadline = Deadline()
        let failures = Reports<any Error>()
        let environment = try await Self.environment(DiskList([a, b]), unmounts: unmounts, home: tree.url("Home"),
                                                     patience: { await deadline.wait() },
                                                     failed: { failure, _ in failures.items.append(failure.error) })
        let ejector = environment.services.volumeEjector
        let ejected = Reports<URL>()
        let observer = NotificationCenter.default.addObserver(forName: .volumeEjected, object: ejector, queue: nil) { note in
            let volume = note.userInfo?[VolumeEjector.volumeKey] as? URL
            MainActor.assumeIsolated { if let volume { ejected.items.append(volume) } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let first = try #require(ejector.eject(a.url, from: nil))
        await unmounts.waitForAsks(1)
        let second = try #require(ejector.eject(b.url, from: nil))
        await unmounts.waitForAsks(2)
        await deadline.pass()
        await Self.turns { failures.items.count == 2 }
        try #require(failures.items.count == 2, "Both are reported as not answering")
        #expect(failures.items.allSatisfy { $0 is VolumeEjector.NoAnswer })
        // Still in macOS's hands: asking again would only block another thread on the same disk.
        #expect(ejector.isEjecting(a.url) && ejector.isEjecting(b.url))
        #expect(ejector.eject(a.url, from: nil) == nil && ejector.eject(b.url, from: nil) == nil)

        // A late success is an eject like any other; a late failure lets the disk be tried again. Neither is reported
        // a second time.
        await unmounts.answer(a.url)
        await first.value
        #expect(ejected.items == [a.url])
        await unmounts.answer(b.url, throwing: CocoaError(.fileWriteNoPermission))
        await second.value
        #expect(!ejector.isEjecting(b.url) && ejected.items == [a.url] && failures.items.count == 2)
        #expect(await unmounts.asked.count == 2)
        #expect(tree.snapshot() == ["Home/"])
    }

    @Test(.timeLimit(.minutes(2)))
    func anAnswerBeforeTheDeadlineIsNeverTakenForNoAnswer() async {
        // The deadline's wait ends the moment it's cancelled, as `Task.sleep` does: it must still not count.
        for _ in 0..<50 {
            let deadline = Deadline()
            let answer = Task.detached { () -> Result<Void, any Error> in .success(()) }
            let outcome = await VolumeEjector.outcome(of: answer, patience: { await deadline.wait() })
            guard case .success = outcome else {
                Issue.record("An eject that succeeded was reported as \(outcome)")
                return
            }
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func anEnvironmentOfItsOwnNeverHandsADiskToMacOS() async throws {
        let disk = Self.disk(URL(filePath: "/Volumes/strata-test-disk", directoryHint: .isDirectory), named: "disk")
        let state = try TestTree()
        let failures = Reports<(name: String, refused: Bool)>()
        let refusals: VolumeEjector.Report = { failure, _ in
            failures.items.append((failure.name, (failure.error as? CocoaError)?.code == .featureUnsupported))
        }
        let clipboard = Clipboard(pasteboard: .withUniqueName(), notifications: NotificationCenter())
        defer { clipboard.pasteboard.releaseGlobally() }
        let credentials = RemoteKeychain(access: KeychainAccess(
            copy: { _ in (errSecItemNotFound, nil) }, add: { _ in errSecNotAvailable },
            update: { _, _ in errSecNotAvailable }, delete: { _ in errSecItemNotFound }))
        let preferences = try Prefs.isolated()
        let isolated = BrowserServices.isolated(
            preferences: preferences,
            storage: SecureStorage.Context(directory: state.url("state"), caches: state.url("cache"), key: SymmetricKey(size: .bits256)),
            credentials: credentials, connector: RemoteConnector { _, _ in throw RemoteError.unknownServer }, clipboard: clipboard,
            readPlaces: { _ in PlaceChecks.Snapshot(volumes: [disk]) }, ejectFailed: refusals)
        let configured = BrowserServices.configured(transfers: isolated.transfers, visits: isolated.visits, windows: .headless,
            remote: isolated.remote, containers: isolated.containers, containerStore: isolated.containerStore,
            clipboard: clipboard, readPlaces: { _ in PlaceChecks.Snapshot(volumes: [disk]) }, ejectFailed: refusals)
        for services in [isolated, configured] {
            await Self.read(services.places)
            let task = try #require(services.volumeEjector.eject(disk.url, from: nil))
            await task.value
        }
        #expect(failures.items.map { $0.name } == ["disk", "disk"] && failures.items.allSatisfy { $0.refused })
        withExtendedLifetime((isolated, configured)) {}
        #expect(state.snapshot().allSatisfy { $0.hasPrefix("state") || $0.hasPrefix("cache") })
    }

    @Test(.timeLimit(.minutes(3)))
    func panesLeaveADiskBeforeItsEjectedAndStayAway() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("Home/", "Volumes/a/folder/deeper/", "Volumes/ab/", "Volumes/a 1/", "Volumes/share/folder/")
        let a = Self.disk(tree.url("Volumes/a"), named: "a"), ab = Self.disk(tree.url("Volumes/ab"), named: "ab")
        let a1 = Self.disk(tree.url("Volumes/a 1"), named: "a 1")
        let address = try #require(URL(string: "smb://server.invalid/share"))
        let share = Place(title: "share", url: tree.url("Volumes/share"), symbol: "network", isEjectable: true, remountAddress: address)
        let unmounts = HeldUnmounts(), workspace = NotificationCenter()
        let reportedIn = Reports<NSWindow?>()
        let environment = try await Self.environment(DiskList([a, ab, a1, share]), unmounts: unmounts, home: tree.url("Home"),
                                                     notifications: workspace,
                                                     failed: { _, window in reportedIn.items.append(window) })
        let window = BrowserWindowController(location: tree.url("Volumes/a/folder"), secondPane: tree.url("Volumes/ab"),
                                             services: environment.services)
        window.split.splitView.autosaveName = nil
        window.window?.setFrameAutosaveName("")
        defer { window.window?.close() }
        let left = window.pane, right = try #require(window.panes.last)
        try #require(left !== right)
        func show(_ path: String, in pane: Pane) async {
            window.go(.folder(tree.url(path)), in: pane)
            await pane.browser.directoryReads.task?.value
        }
        func shows(_ pane: Pane, _ path: String) -> Bool { PathSpelling.short(pane.location) == PathSpelling.short(tree.url(path)) }
        await left.browser.directoryReads.task?.value
        await right.browser.directoryReads.task?.value
        let ejector = environment.services.volumeEjector

        // The folder inside the disk goes Home before macOS is asked, and stays when the eject fails; the look-alike
        // disk beside it stays where it is.
        try #require(window.panesShowing(a.url).count == 1 && window.panesShowing(a.url).first === left)
        let failed = try #require(ejector.eject(a.url, from: window.window))
        #expect(shows(left, "Home") && shows(right, "Volumes/ab"))
        await unmounts.waitForAsks(1)
        await unmounts.answer(a.url, throwing: CocoaError(.fileWriteNoPermission))
        await failed.value
        #expect(reportedIn.items.count == 1 && reportedIn.items.first.flatMap { $0 } === window.window)
        #expect(shows(left, "Home") && shows(right, "Volumes/ab"))

        // Two disks at once in one window: one fails, one is ejected; both panes stay Home.
        await show("Volumes/a", in: left)
        let first = try #require(ejector.eject(a.url, from: window.window))
        let second = try #require(ejector.eject(ab.url, from: window.window))
        #expect(shows(left, "Home") && shows(right, "Home"))
        await unmounts.waitForAsks(3)
        await unmounts.answer(ab.url)
        await unmounts.answer(a.url, throwing: CocoaError(.fileWriteNoPermission))
        await first.value
        await second.value
        #expect(shows(left, "Home") && shows(right, "Home") && reportedIn.items.count == 2)

        // ⌘E: the disk whose top a pane shows, or whose top a deeper column shows, but not a folder only inside it.
        let eject = NSMenuItem(title: "", action: #selector(BrowserWindowController.ejectVolume(_:)), keyEquivalent: "")
        left.browser.setMode(.columns, remember: false)
        await show("Volumes", in: left)
        window.browser(left.browser, columnLocationChanged: tree.url("Volumes/a/folder"))
        #expect(window.panesShowing(a.url).first === left && !window.validateMenuItem(eject))
        window.browser(left.browser, columnLocationChanged: tree.url("Volumes/a"))
        #expect(window.validateMenuItem(eject))
        await show("Volumes/a", in: left)
        window.browser(left.browser, columnLocationChanged: tree.url("Volumes/a/folder"))
        try #require(window.pane === left && window.validateMenuItem(eject))
        window.ejectVolume(nil)
        let byCommand = try #require(ejector.tasks.values.first)
        #expect(shows(left, "Home"))
        // Back on the disk's top while it ejects: ⌘E waits for the eject under way, and the pane leaves again after.
        await show("Volumes/a", in: left)
        #expect(!window.validateMenuItem(eject))
        await unmounts.waitForAsks(4)
        await unmounts.answer(a.url)
        await byCommand.value
        #expect(shows(left, "Home"))

        // A search inside a disk leaves it too; Recents, last on a folder of that disk, is no view of it and stays.
        await show("Volumes/a 1", in: left)
        window.go(.recents, in: left)
        window.go(.search("report", scope: tree.url("Volumes/a 1")), in: right)
        let searched = try #require(ejector.eject(a1.url, from: window.window))
        #expect(shows(right, "Home"))
        if case .search = right.destination { Issue.record("The search inside the disk is still showing") }
        if left.destination != .recents { Issue.record("Recents went Home with the disk") }
        #expect(shows(left, "Home"), "Recents no longer counts the disk as where it was opened from")
        await unmounts.waitForAsks(5)
        await unmounts.answer(a1.url)
        await searched.value
        await show("Home", in: left)

        // A disk unmounted elsewhere (Finder, unplugged, taken along with another): its panes go Home, as soon as macOS
        // says it's about to go, and it isn't offered again until the disks are read again. One on a share keeps the
        // folder it showed there for its workspace and the session; one on a local disk keeps nothing.
        try await Self.readAgain(ab, by: ejector)
        await show("Volumes/ab", in: right)
        workspace.post(name: NSWorkspace.didUnmountNotification, object: nil, userInfo: [NSWorkspace.volumeURLUserInfoKey: a1.url])
        #expect(shows(right, "Volumes/ab"))
        workspace.post(name: NSWorkspace.didUnmountNotification, object: nil, userInfo: [NSWorkspace.volumeURLUserInfoKey: ab.url])
        #expect(shows(right, "Home") && right.waiting == nil && ejector.isEjecting(ab.url))
        let scope = tree.url("Volumes/share/folder")
        window.go(.search("report", scope: scope), in: right)
        // A willUnmount notice may name the disk by its path alone.
        workspace.post(name: NSWorkspace.willUnmountNotification, object: nil, userInfo: ["NSDevicePath": share.url.path])
        #expect(ejector.isEjecting(share.url))
        #expect(shows(right, "Home"))
        let kept = right.waiting
        #expect(kept?.path == scope.path && kept?.mountPoint == share.url.path && kept?.address != nil)
        workspace.post(name: NSWorkspace.didUnmountNotification, object: nil, userInfo: [NSWorkspace.volumeURLUserInfoKey: share.url])
        #expect(shows(right, "Home") && right.waiting == kept)
        #expect(await Self.paths(unmounts.asked) == Self.paths([a.url, a.url, a.url, ab.url, a1.url]))
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["Home/", "Volumes/", "Volumes/a 1/", "Volumes/a/", "Volumes/a/folder/", "Volumes/a/folder/deeper/",
                                    "Volumes/ab/", "Volumes/share/", "Volumes/share/folder/"])
    }

    @Test(.timeLimit(.minutes(3)))
    func everyWindowLetsTheDiskGoAndOneClosedOrAPaneClosedMeanwhileIsLeftAlone() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("Home/", "Volumes/a/folder/", "elsewhere/")
        let a = Self.disk(tree.url("Volumes/a"), named: "a")
        let unmounts = HeldUnmounts()
        let reportedIn = Reports<NSWindow?>()
        let environment = try await Self.environment(DiskList([a]), unmounts: unmounts, home: tree.url("Home"),
                                                     failed: { _, window in reportedIn.items.append(window) })
        let one = BrowserWindowController(location: tree.url("Volumes/a/folder"), services: environment.services)
        let two = BrowserWindowController(location: tree.url("Volumes/a"), secondPane: tree.url("Volumes/a/folder"),
                                          services: environment.services)
        for controller in [one, two] {
            controller.split.splitView.autosaveName = nil
            controller.window?.setFrameAutosaveName("")
        }
        defer { one.window?.close(); two.window?.close() }
        for pane in one.panes + two.panes { await pane.browser.directoryReads.task?.value }
        func home(_ panes: [Pane]) -> Bool { panes.allSatisfy { PathSpelling.short($0.location) == PathSpelling.short(tree.url("Home")) } }
        let ejector = environment.services.volumeEjector

        let failed = try #require(ejector.eject(a.url, from: one.window))
        #expect(home(one.panes) && home(two.panes))
        // The window that asked closes, and the other loses a pane, before macOS answers.
        one.window?.close()
        try #require(one.isClosed)
        two.toggleDualPane(nil)
        try #require(two.panes.count == 1)
        await unmounts.waitForAsks(1)
        await unmounts.answer(a.url, throwing: CocoaError(.fileWriteNoPermission))
        await failed.value
        #expect(reportedIn.items.count == 1, "The failure is still reported")
        #expect(home(two.panes))

        // The window still open leaves the disk; the closed one is left alone.
        two.go(.folder(tree.url("Volumes/a/folder")), in: two.pane)
        await two.pane.browser.directoryReads.task?.value
        let ejected = try #require(ejector.eject(a.url, from: two.window))
        #expect(home(two.panes))
        await unmounts.waitForAsks(2)
        await unmounts.answer(a.url)
        await ejected.value
        #expect(home(two.panes) && home(one.panes))
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["Home/", "Volumes/", "Volumes/a/", "Volumes/a/folder/", "elsewhere/"])
    }

    @Test func failuresWaitTheirTurnInTheirWindowAndADialogTakesOverOnceItsClosed() throws {
        _ = NSApplication.shared
        let sheets = Reports<(alert: NSAlert, window: NSWindow, done: () -> Void)>()
        let dialogs = Reports<NSAlert>(), closed = Reports<ObjectIdentifier>()
        let alerts = EjectFailureAlerts(sheet: { alert, window, done in sheets.items.append((alert, window, done)) },
                                        dialog: { dialogs.items.append($0) },
                                        canAsk: { !closed.items.contains(ObjectIdentifier($0)) })
        func titles(_ shown: [NSAlert]) -> [String] { shown.map { $0.messageText } }
        func ejectFailed(_ name: String) -> String { String(localized: "“\(name)” couldn’t be ejected") }
        func window() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }
        func failure(_ name: String, _ error: any Error = CocoaError(.fileWriteNoPermission)) -> VolumeEjector.Failure {
            VolumeEjector.Failure(name: name, error: error)
        }
        let first = window(), second = window(), third = window()

        alerts.present(failure("a"), in: first)
        alerts.present(failure("b"), in: first)
        alerts.present(failure("c"), in: first)
        alerts.present(failure("d"), in: second)
        #expect(titles(sheets.items.map { $0.alert }) == [ejectFailed("a"), ejectFailed("d")])
        sheets.items[0].done()
        #expect(sheets.items.count == 3 && sheets.items[2].window === first)
        #expect(titles(sheets.items.map { $0.alert }).last == ejectFailed("b"))
        // Closed with "c" still waiting: it's shown as a dialog, and so is what comes for that window later.
        closed.items.append(ObjectIdentifier(first))
        sheets.items[2].done()
        #expect(sheets.items.count == 3 && titles(dialogs.items) == [ejectFailed("c")])
        alerts.present(failure("e"), in: first)
        alerts.present(failure("f"), in: nil)
        #expect(titles(dialogs.items) == [ejectFailed("c"), ejectFailed("e"), ejectFailed("f")] && sheets.items.count == 3)

        // A window that closed without its sheet ever ending leaves nothing stuck.
        alerts.present(failure("g"), in: third)
        closed.items.append(ObjectIdentifier(third))
        alerts.present(failure("h", VolumeEjector.NoAnswer()), in: third)
        #expect(sheets.items.count == 4 && titles(dialogs.items).last == ejectFailed("h"))
        #expect(dialogs.items.last?.informativeText == String(localized: "“\("h")” didn’t answer in time."))
        for window in [first, second, third] { window.close() }
    }

    /// A sidebar in a window of its own, never shown, laid out so its rows are where a click finds them.
    private func host(_ sidebar: SidebarViewController) -> NSWindow {
        let window = ClickWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 700), styleMask: .borderless,
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar.view
        sidebar.view.layoutSubtreeIfNeeded()
        return window
    }

    private func cell(_ row: Int, in outline: NSOutlineView) throws -> SidebarCellView {
        let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView)
        outline.layoutSubtreeIfNeeded()
        return cell
    }

    private func button(of cell: SidebarCellView) throws -> NSButton {
        try #require(cell.subviews.compactMap { $0 as? NSButton }.first)
    }

    private func label(of cell: SidebarCellView) throws -> NSTextField {
        try #require(cell.subviews.compactMap { $0 as? NSTextField }.first)
    }

    private func mouse(_ type: CGEventType, at point: NSPoint) throws -> NSEvent {
        let source = try #require(CGEventSource(stateID: .privateState))
        let event = try #require(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left))
        event.flags = []
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 0)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: 0)
        let initial = try #require(NSEvent(cgEvent: event)).locationInWindow
        let location = event.location
        event.location = CGPoint(x: location.x + point.x - initial.x, y: location.y + initial.y - point.y)
        let result = try #require(NSEvent(cgEvent: event))
        try #require(abs(result.locationInWindow.x - point.x) < 1 && abs(result.locationInWindow.y - point.y) < 1)
        return result
    }

    /// A click at the button's center, delivered by the window as AppKit delivers it. The release waits in the app's
    /// own queue for whatever tracks the press; one nothing took is delivered after it.
    private func click(_ button: NSButton, in window: NSWindow) throws {
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let down = try mouse(.leftMouseDown, at: point), up = try mouse(.leftMouseUp, at: point)
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        if let unclaimed = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            window.sendEvent(unclaimed)
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func placesShowAnEjectButtonOnlyOnEjectableDisksAndAClickEjectsThatDiskWithoutSelectingIt() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("Home/", "Volumes/a/", "Volumes/Data/")
        let a = Self.disk(tree.url("Volumes/a"), named: "a")
        let data = Self.disk(tree.url("Volumes/Data"), named: "Data", ejectable: false)
        let unmounts = HeldUnmounts()
        let failures = Reports<String>()
        let environment = try await Self.environment(DiskList([data, a]), unmounts: unmounts, home: tree.url("Home"),
                                                     failed: { failure, _ in failures.items.append(failure.name) })
        let sidebar = SidebarViewController(services: environment.services)
        let window = host(sidebar)
        defer { window.close() }
        await sidebar.cloudRead?.value
        sidebar.reload()
        let outline = sidebar.outline
        let locations = try #require(sidebar.sections.first { $0.id == "locations" })
        func item(_ disk: Place) throws -> SidebarItem {
            try #require(locations.items.first { $0.url.map { PathSpelling.short($0) } == PathSpelling.short(disk.url) })
        }
        let trashItem = try #require(locations.items.last), diskItem = try item(a), dataItem = try item(data)
        let trash = outline.row(forItem: trashItem), aRow = outline.row(forItem: diskItem)
        let shown = try cell(aRow, in: outline), eject = try button(of: shown)
        #expect(!eject.isHidden && eject.isEnabled && eject.refusesFirstResponder)
        #expect(eject.accessibilityLabel() == String(localized: "Eject “\("a")”") && eject.toolTip == eject.accessibilityLabel())
        #expect(shown.accessibilityCustomActions()?.map(\.name) == [String(localized: "Eject")])
        #expect(eject.frame.maxX <= shown.bounds.maxX - SidebarRowView.selectionInset)
        for other in [outline.row(forItem: dataItem), trash] {
            let plain = try cell(other, in: outline)
            #expect(try button(of: plain).isHidden && (plain.accessibilityCustomActions() ?? []).isEmpty)
        }
        for section in sidebar.sections where section.id != "locations" {
            for item in section.items {
                let row = outline.row(forItem: item)
                if row >= 0 { #expect(try button(of: cell(row, in: outline)).isHidden, "\(item.title)") }
            }
        }
        let menuItem = NSMenuItem(title: "", action: NSSelectorFromString("ejectItem:"), keyEquivalent: "")
        menuItem.representedObject = diskItem.url
        #expect(sidebar.validateMenuItem(menuItem))

        outline.selectRowIndexes([trash], byExtendingSelection: false)
        window.makeFirstResponder(outline)
        var navigations = 0
        sidebar.onSelect = { _ in navigations += 1 }
        try click(eject, in: window)
        let task = try #require(environment.services.volumeEjector.tasks.values.first, "The click reached the button")
        await unmounts.waitForAsks(1)
        #expect(await unmounts.asked == [a.url])
        #expect(outline.selectedRow == trash && navigations == 0 && window.firstResponder === outline)
        let same = try #require(outline.view(atColumn: 0, row: aRow, makeIfNecessary: false) as? SidebarCellView)
        try #require(same === shown)
        #expect(!eject.isEnabled, "Busy while it ejects")
        #expect(!sidebar.validateMenuItem(menuItem))
        // A click on the busy button selects nothing and asks nothing more.
        try click(eject, in: window)
        #expect(outline.selectedRow == trash && navigations == 0 && environment.services.volumeEjector.tasks.count == 1)
        await unmounts.answer(a.url, throwing: CocoaError(.fileWriteNoPermission))
        await task.value
        #expect(failures.items == ["a"])
        #expect(eject.isEnabled && sidebar.validateMenuItem(menuItem), "A failed eject can be tried again")
        let voiceOver = try #require(shown.accessibilityCustomActions()?.first?.selector)
        #expect(NSApp.sendAction(voiceOver, to: shown, from: nil))
        let byVoiceOver = try #require(environment.services.volumeEjector.tasks.values.first, "VoiceOver's Eject ejects the disk")
        await unmounts.waitForAsks(2)
        await unmounts.answer(a.url)
        await byVoiceOver.value
        #expect(await unmounts.asked == [a.url, a.url])

        // Reused: the label stops before the button, and a row that isn't a disk has none.
        shown.frame = NSRect(x: 0, y: 0, width: 160, height: 28)
        shown.configure(title: String(repeating: "Long disk name ", count: 8), symbol: "externaldrive",
                        ejection: SidebarCellView.Ejection(isUnderway: { false }, perform: {}))
        shown.layoutSubtreeIfNeeded()
        #expect(try label(of: shown).frame.maxX <= eject.frame.minX)
        #expect(eject.frame.width >= 20)
        shown.configure(title: "folder", symbol: "folder")
        shown.layoutSubtreeIfNeeded()
        #expect(eject.isHidden && (eject.accessibilityLabel() ?? "").isEmpty && (shown.accessibilityCustomActions() ?? []).isEmpty)
        #expect(try label(of: shown).frame.maxX > eject.frame.minX)
        sidebar.onSelect = nil
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["Home/", "Volumes/", "Volumes/Data/", "Volumes/a/"])
    }

    @Test(.timeLimit(.minutes(2)))
    func theFolderTreeEjectsOnlyEjectableDisksFromItsButtonAndMenu() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("Home/", "Volumes/a/", "Volumes/Data/")
        let a = Self.disk(tree.url("Volumes/a"), named: "a")
        let data = Self.disk(tree.url("Volumes/Data"), named: "Data", ejectable: false)
        let unmounts = HeldUnmounts()
        let environment = try await Self.environment(DiskList([data, a]), unmounts: unmounts, home: tree.url("Home"))
        environment.preferences.sidebarShowsTree = true
        let sidebar = SidebarViewController(services: environment.services)
        let window = host(sidebar)
        defer { window.close() }
        let folders = try #require(sidebar.children.first as? FolderTreeController)
        let outline = try #require(folders.focusView as? NSOutlineView)
        func node(_ url: URL) throws -> FolderNode {
            let row = try #require((0..<outline.numberOfRows).first { row in
                (outline.item(atRow: row) as? FolderNode).map { PathSpelling.short($0.url) } == PathSpelling.short(url)
            })
            return try #require(outline.item(atRow: row) as? FolderNode)
        }
        let disk = try node(a.url), plain = try node(data.url), home = try node(tree.url("Home"))
        let shown = try cell(outline.row(forItem: disk), in: outline), eject = try button(of: shown)
        #expect(!eject.isHidden && eject.accessibilityLabel() == String(localized: "Eject “\("a")”"))
        #expect(try button(of: cell(outline.row(forItem: plain), in: outline)).isHidden)
        #expect(try button(of: cell(outline.row(forItem: home), in: outline)).isHidden)

        func ejectItems(for node: FolderNode) -> [NSMenuItem] {
            let menu = NSMenu()
            folders.addItems(for: node, to: menu)
            return menu.items.filter { $0.action == NSSelectorFromString("ejectNode:") }
        }
        #expect(ejectItems(for: disk).map(\.title) == [String(localized: "Eject “\("a")”")])
        #expect(ejectItems(for: plain).isEmpty && ejectItems(for: home).isEmpty)
        let menuItem = try #require(ejectItems(for: disk).first)
        #expect(folders.validateMenuItem(menuItem))

        outline.selectRowIndexes([outline.row(forItem: plain)], byExtendingSelection: false)
        var navigations = 0
        sidebar.onSelect = { _ in navigations += 1 }
        try click(eject, in: window)
        let task = try #require(environment.services.volumeEjector.tasks.values.first, "The click reached the button")
        await unmounts.waitForAsks(1)
        #expect(outline.item(atRow: outline.selectedRow) as? FolderNode === plain && navigations == 0)
        #expect(!eject.isEnabled && !folders.validateMenuItem(menuItem))
        // The menu's Eject while the button's is under way asks nothing more of macOS.
        let action = try #require(menuItem.action)
        _ = folders.perform(action, with: menuItem)
        #expect(environment.services.volumeEjector.tasks.count == 1)
        await unmounts.answer(a.url)
        await task.value
        #expect(await unmounts.asked == [a.url])
        sidebar.onSelect = nil
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["Home/", "Volumes/", "Volumes/Data/", "Volumes/a/"])
    }
}
