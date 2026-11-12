import AppKit
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSupport

@MainActor struct WindowSessionTests {
    private static let availableFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    private final class Windows {
        var opened: [BrowserWindowController] = []
        var shown: [NSWindow] = []
        var framesAtOpening: [NSRect] = []
        var closeBeforeReturning = false
        private var groups: [ObjectIdentifier: [BrowserWindowController]] = [:]
        private var selected: [ObjectIdentifier: NSWindow] = [:]

        var boundary: BrowserWindows {
            BrowserWindows(controllers: { [weak self] in self?.opened ?? [] }, open: { [weak self] folder, second, parent, services, frame in
                guard let self else { return nil }
                let owner = BrowserWindowController(location: folder, secondPane: second, services: services, frame: frame)
                owner.split.splitView.autosaveName = nil
                if let window = owner.window {
                    window.isReleasedWhenClosed = false
                    let group = parent.flatMap { groups[ObjectIdentifier($0)] } ?? []
                    for member in group + [owner] {
                        if let window = member.window { groups[ObjectIdentifier(window)] = group + [owner] }
                    }
                    framesAtOpening.append(window.frame)
                }
                opened.append(owner)
                if closeBeforeReturning { owner.window?.close() }
                return owner
            }, show: { [weak self] window in self?.shown.append(window) },
            tabs: { [weak self] window in self?.groups[ObjectIdentifier(window)] ?? [] },
            selectedTab: { [weak self] window in self?.selected[ObjectIdentifier(window)] ?? window },
            selectTab: { [weak self] window in
                guard let self else { return }
                for owner in groups[ObjectIdentifier(window)] ?? [] {
                    if let member = owner.window { selected[ObjectIdentifier(member)] = window }
                }
            }, frameBounds: { [WindowSessionTests.availableFrame] })
        }

        func open(_ folder: URL, services: BrowserServices, second: URL? = nil, parent: NSWindow? = nil) throws -> BrowserWindowController {
            try #require(boundary.open(folder, second, parent, services, nil))
        }

        func detach() {
            for owner in opened {
                owner.window?.delegate = nil
                owner.panes.forEach { $0.stopBackgroundWork() }
                owner.window?.contentViewController = nil
                owner.window?.close()
            }
            opened.removeAll()
            shown.removeAll()
            groups.removeAll()
            selected.removeAll()
        }
    }

    private final class HeldPlan {
        private var continuation: CheckedContinuation<WorkspacePlan, Never>?
        private var notification: CheckedContinuation<Void, Never>?
        private(set) var reads = 0
        private var awaitedReads = 1
        var cancelledOnMainActor: (@MainActor @Sendable () -> Void)?

        func read(_ workspace: Workspace) async -> WorkspacePlan {
            let cancelled = cancelledOnMainActor
            return await withTaskCancellationHandler {
                await withCheckedContinuation {
                    continuation = $0
                    reads += 1
                    if reads >= awaitedReads {
                        notification?.resume()
                        notification = nil
                    }
                }
            } onCancel: {
                // This fixture's owner cancels on the main actor; deliberately reenter before cancellation returns.
                if let cancelled { MainActor.assumeIsolated { cancelled() } }
            }
        }

        func started(_ count: Int = 1) async {
            if reads >= count { return }
            awaitedReads = count
            await withCheckedContinuation { notification = $0 }
        }

        func finish(_ workspace: Workspace) {
            continuation?.resume(returning: WorkspacePlan(workspace, exists: { _ in true }))
            continuation = nil
        }
    }

    private func frame(_ inset: CGFloat = 40) -> NSRect {
        let screen = Self.availableFrame
        return NSRect(x: screen.minX + inset, y: screen.minY + inset,
                      width: min(1240, screen.width - 2 * inset), height: min(650, screen.height - 2 * inset))
    }

    private func panePaths(of owner: BrowserWindowController?) -> [String]? {
        owner?.snapshot.map { URL(fileURLWithPath: $0).lexicallyStandardized.path }
    }

    private func encodedSession(_ workspace: Workspace) throws -> Data {
        try #require(SessionStorage.encode([workspace]))
    }

    @Test func dockReopenShowsAnExistingHiddenBrowserAndKeepsItsPanes() throws {
        let tree = try TestTree("left/", "right/"), windows = Windows()
        let environment = try PreviewEnvironment(tree, reader: DirectoryReader { _, _, _ in [] }, windows: windows.boundary)
        defer { withExtendedLifetime(tree) { windows.detach() } }
        let owner = try windows.open(tree.url("left"), services: environment.services, second: tree.url("right"))
        owner.window?.setFrame(frame(), display: false)
        let before = owner.window?.frame
        #expect(owner.window?.isVisible == false)
        #expect(environment.services.windowSession.reopen(at: tree.root) == nil)
        #expect(windows.opened.count == 1 && windows.shown == [owner.window!])
        #expect(owner.isDualPane && owner.window?.frame == before)
    }

    @Test func dockReopenPrefersTheMostRecentlyActiveHiddenWindowAndIgnoresClosedOnes() throws {
        let tree = try TestTree("first/", "recent/"), windows = Windows()
        let environment = try PreviewEnvironment(tree, reader: DirectoryReader { _, _, _ in [] }, windows: windows.boundary)
        defer { withExtendedLifetime(tree) { windows.detach() } }
        let first = try windows.open(tree.url("first"), services: environment.services)
        let recent = try windows.open(tree.url("recent"), services: environment.services)
        let session = environment.services.windowSession
        session.windowBecameKey(recent)
        session.reopen(at: tree.root)
        #expect(windows.shown.last === recent.window && windows.opened.count == 2)
        recent.window?.close()
        session.reopen(at: tree.root)
        #expect(windows.shown.last === first.window && windows.opened.count == 2)
    }

    @Test func closingATabGroupRestoresItsFrameViewsHistoryAndActivePaneWhileOldWindowsAreRetained() async throws {
        let tree = try TestTree("left/", "right/", "tab/"), windows = Windows()
        let environment = try PreviewEnvironment(tree, reader: DirectoryReader { _, _, _ in [] }, windows: windows.boundary)
        defer { withExtendedLifetime(tree) { windows.detach() } }
        let first = try windows.open(tree.url("left"), services: environment.services, second: tree.url("right"))
        let second = try windows.open(tree.url("tab"), services: environment.services, parent: first.window)
        first.applyModes([BrowserViewMode.grid.rawValue, BrowserViewMode.list.rawValue])
        first.panes[1].history.back = [.recents]
        first.window?.makeFirstResponder(first.panes[1].browser.focusView)
        let expectedFrame = frame()
        first.window?.setFrame(expectedFrame, display: false)
        second.window?.setFrame(expectedFrame, display: false)
        windows.boundary.selectTab(second.window!)
        let expected = Workspaces.workspace(named: "", of: [first, second], includingNavigation: true)
        try #require(windows.boundary.tabs(first.window!).count == 2)
        #expect(first.windowShouldClose(first.window!))
        first.window?.close()
        second.window?.close()
        environment.services.windowSession.finishClosing()
        environment.services.windowSession.save()
        await environment.services.windowSession.reopen(at: tree.root)?.value

        let restored = Array(windows.opened.dropFirst(2))
        try #require(restored.count == 2)
        #expect(restored[0].snapshot == expected.tabs[0] && restored[1].snapshot == expected.tabs[1])
        #expect(restored[0].snapshotModes == expected.modes?[0])
        #expect(restored[0].pane === restored[0].panes[1])
        #expect(restored[0].panes[1].history.back == [.recents])
        #expect(restored[0].window?.frame == expectedFrame)
        #expect(restored[1].window?.frame == expectedFrame)
        #expect(windows.framesAtOpening.suffix(2).allSatisfy { $0 == expectedFrame })
        #expect(windows.boundary.selectedTab(restored[0].window!) === restored[1].window)
        #expect(first.isClosed && second.isClosed)
        #expect(windows.opened.allSatisfy { $0.window?.isVisible == false })
    }

    @Test func newWindowRestoresOnlyWhenNoBrowserRemainsAndThePreferenceIsOn() async throws {
        let tree = try TestTree("saved/", "fallback/"), windows = Windows()
        let environment = try PreviewEnvironment(tree, reader: DirectoryReader { _, _, _ in [] }, windows: windows.boundary)
        defer { withExtendedLifetime(tree) { windows.detach() } }
        let owner = try windows.open(tree.url("saved"), services: environment.services, second: tree.url("saved"))
        #expect(environment.services.windowSession.openNewWindow(at: tree.url("fallback")) == nil)
        #expect(panePaths(of: windows.opened.last) == [tree.url("fallback").lexicallyStandardized.path])
        windows.opened.last?.window?.close()
        owner.window?.close()
        await environment.services.windowSession.openNewWindow(at: tree.url("fallback"))?.value
        #expect(panePaths(of: windows.opened.last) == [tree.url("saved").lexicallyStandardized.path, tree.url("saved").lexicallyStandardized.path])
        windows.opened.last?.window?.close()
        environment.preferences.reopenWindows = false
        await environment.services.windowSession.reopen(at: tree.url("fallback"))?.value
        #expect(panePaths(of: windows.opened.last) == [tree.url("fallback").lexicallyStandardized.path])
    }

    @Test func windowsAndSavedFramesStayWithTheirEnvironment() throws {
        let tree = try TestTree("a/", "b/"), other = try TestTree(), windows = Windows()
        let a = try PreviewEnvironment(tree, reader: DirectoryReader { _, _, _ in [] }, windows: windows.boundary)
        let b = try PreviewEnvironment(other, reader: DirectoryReader { _, _, _ in [] }, windows: windows.boundary)
        defer { withExtendedLifetime((tree, other)) { windows.detach() } }
        let owner = try windows.open(tree.url("a"), services: a.services)
        let savedFrame = frame()
        owner.window?.setFrame(savedFrame, display: false)
        owner.window?.close()
        a.services.windowSession.finishClosing()
        let peer = try windows.open(tree.url("b"), services: b.services)
        #expect(b.defaults.data(forKey: "browserWindowFrame") == nil)
        a.preferences.reopenWindows = false
        a.services.windowSession.reopen(at: tree.url("a"))
        #expect(windows.shown.isEmpty)
        #expect(windows.opened.last?.services === a.services)
        #expect(windows.opened.last?.window?.frame == savedFrame)
        #expect(!peer.isClosed && peer.services === b.services)
    }

    @Test func quitSessionRestoresEachWindowsOwnFrameBeforeOpening() async throws {
        let tree = try TestTree("first/", "second/"), windows = Windows()
        let environment = try PreviewEnvironment(tree, reader: DirectoryReader { _, _, _ in [] }, windows: windows.boundary)
        defer { withExtendedLifetime(tree) { windows.detach() } }
        let first = try windows.open(tree.url("first"), services: environment.services)
        let second = try windows.open(tree.url("second"), services: environment.services)
        first.window?.setFrame(frame(), display: false)
        second.window?.setFrame(frame(80), display: false)
        environment.services.windowSession.save()
        let data = try #require(environment.defaults.data(forKey: "lastSession"))
        let saved = try #require(SessionStorage.decode(data))
        #expect(saved.map { $0.frame?.rectangle } == [frame(), frame(80)])
        windows.detach()
        await environment.services.windowSession.reopen(at: tree.root)?.value
        #expect(windows.opened.map { panePaths(of: $0) }
                == [[tree.url("second").lexicallyStandardized.path], [tree.url("first").lexicallyStandardized.path]])
        #expect(windows.opened.map { $0.window?.frame } == [frame(80), frame()])
    }

    @Test func aLateRestorationCannotReopenAfterANewerWindowOpenedAndClosed() async throws {
        let tree = try TestTree("saved/", "new/"), windows = Windows(), held = HeldPlan()
        let environment = try PreviewEnvironment(tree, reader: DirectoryReader { _, _, _ in [] }, windows: windows.boundary)
        defer { withExtendedLifetime(tree) { windows.detach() } }
        let saved = Workspace(name: "", tabs: [[tree.url("saved").path]])
        environment.defaults.set(try encodedSession(saved), forKey: "lastSession")
        let session = WindowSession(services: environment.services, plan: held.read)
        environment.services.windowSession = session
        let work = try #require(session.reopen(at: tree.root))
        await held.started()
        let newer = try windows.open(tree.url("new"), services: environment.services)
        newer.window?.close()
        held.finish(saved)
        await work.value
        #expect(windows.opened.count == 1 && newer.isClosed)
        #expect(work.isCancelled)
    }

    @Test func repeatedReopenRequestsShareOnePlanAndTurningRestorationOffWins() async throws {
        let tree = try TestTree("saved/", "fallback/"), windows = Windows(), held = HeldPlan()
        let environment = try PreviewEnvironment(tree, reader: DirectoryReader { _, _, _ in [] }, windows: windows.boundary)
        defer { withExtendedLifetime(tree) { windows.detach() } }
        let saved = Workspace(name: "", tabs: [[tree.url("saved").path]])
        environment.defaults.set(try encodedSession(saved), forKey: "lastSession")
        let session = WindowSession(services: environment.services, plan: held.read)
        environment.services.windowSession = session
        let work = try #require(session.reopen(at: tree.url("fallback")))
        await held.started()
        let duplicate = try #require(session.reopen(at: tree.url("fallback")))
        environment.preferences.reopenWindows = false
        held.finish(saved)
        await work.value
        await duplicate.value
        #expect(held.reads == 1 && windows.opened.count == 1)
        #expect(panePaths(of: windows.opened.first) == [tree.url("fallback").lexicallyStandardized.path])
    }

    @Test func aCancellationCallbackCanStartAReplacementWithoutLosingItsOwnership() async throws {
        let tree = try TestTree("saved/"), windows = Windows(), held = HeldPlan()
        let environment = try PreviewEnvironment(tree, reader: DirectoryReader { _, _, _ in [] }, windows: windows.boundary)
        defer { withExtendedLifetime(tree) { windows.detach() } }
        let saved = Workspace(name: "", tabs: [[tree.url("saved").path]])
        environment.defaults.set(try encodedSession(saved), forKey: "lastSession")
        let session = WindowSession(services: environment.services, plan: held.read)
        environment.services.windowSession = session
        var replacement: Task<Void, Never>?
        held.cancelledOnMainActor = { [weak session] in replacement = session?.reopen(at: tree.root) }
        let old = try #require(session.reopen(at: tree.root))
        await held.started()
        session.cancelRestoration()
        held.finish(saved)
        let next = try #require(replacement)
        try #require(!next.isCancelled)
        await old.value
        await held.started(2)
        let duplicate = try #require(session.reopen(at: tree.root))
        held.finish(saved)
        await next.value
        await duplicate.value
        #expect(held.reads == 2 && windows.opened.count == 1)
    }

    @Test func pendingRestorationDoesNotKeepItsEnvironmentAlive() async throws {
        let tree = try TestTree("saved/"), windows = Windows(), held = HeldPlan()
        var environment: PreviewEnvironment? = try PreviewEnvironment(tree, windows: windows.boundary)
        defer { withExtendedLifetime(tree) { windows.detach() } }
        let saved = Workspace(name: "", tabs: [[tree.url("saved").path]])
        let bytes = try #require(SessionStorage.encode([saved]))
        environment?.defaults.set(bytes, forKey: "lastSession")
        if let services = environment?.services { services.windowSession = WindowSession(services: services, plan: held.read) }
        weak var session = environment?.services.windowSession
        let work = try #require(session?.reopen(at: tree.root))
        await held.started()
        environment = nil
        #expect(session == nil)
        held.finish(saved)
        await work.value
        #expect(windows.opened.isEmpty && work.isCancelled)
    }

    @Test func quittingCancelsARestorationWhoseFolderHasNotAnswered() async throws {
        let tree = try TestTree("saved/"), windows = Windows(), held = HeldPlan()
        let environment = try PreviewEnvironment(tree, windows: windows.boundary)
        defer { withExtendedLifetime(tree) { windows.detach() } }
        let saved = Workspace(name: "", tabs: [[tree.url("saved").path]])
        let bytes = try encodedSession(saved)
        environment.defaults.set(bytes, forKey: "lastSession")
        let session = WindowSession(services: environment.services, plan: held.read)
        environment.services.windowSession = session
        let work = try #require(session.reopen(at: tree.root))
        await held.started()
        session.save()
        held.finish(saved)
        await work.value
        #expect(work.isCancelled && windows.opened.isEmpty)
        #expect(environment.defaults.data(forKey: "lastSession") == bytes)
    }

    @Test func anImmediateReopenKeepsTheSameTabLimitAsTheSavedSession() async throws {
        let tree = try TestTree("folder/"), windows = Windows()
        let environment = try PreviewEnvironment(tree, reader: DirectoryReader { _, _, _ in [] }, windows: windows.boundary)
        defer { withExtendedLifetime(tree) { windows.detach() } }
        let first = try windows.open(tree.url("folder"), services: environment.services)
        for _ in 0..<20 { _ = try windows.open(tree.url("folder"), services: environment.services, parent: first.window) }
        let saved = Workspaces.workspace(named: "", of: windows.opened, includingNavigation: true)
        let persisted = try #require(SessionStorage.decode(try encodedSession(saved)))
        try #require(persisted.first?.tabs.count == 20)
        #expect(first.windowShouldClose(first.window!))
        let previous = windows.opened
        for owner in previous { owner.window?.close() }
        environment.services.windowSession.finishClosing()
        await environment.services.windowSession.reopen(at: tree.root)?.value
        #expect(windows.opened.count - previous.count == 20)
    }

    @Test func aPendingCloseSaveCannotOverwriteTheSessionSavedAtQuit() async throws {
        let tree = try TestTree("old/", "current/"), windows = Windows()
        let environment = try PreviewEnvironment(tree, reader: DirectoryReader { _, _, _ in [] }, windows: windows.boundary)
        defer { withExtendedLifetime(tree) { windows.detach() } }
        let old = try windows.open(tree.url("old"), services: environment.services)
        old.window?.close()
        let session = environment.services.windowSession
        session.finishClosing()
        let oldSave = try #require(session.saving)
        let current = try windows.open(tree.url("current"), services: environment.services)
        session.save()
        let data = try #require(environment.defaults.data(forKey: "lastSession"))
        await oldSave.value
        #expect(oldSave.isCancelled && environment.defaults.data(forKey: "lastSession") == data)
        #expect(SessionStorage.decode(data)?.first?.tabs == [current.snapshot])
    }

    @Test func aWindowClosedByTheFactoryIsNeverConfiguredOrSelectedAsARestoredTab() throws {
        let tree = try TestTree("folder/"), windows = Windows()
        let environment = try PreviewEnvironment(tree, reader: DirectoryReader { _, _, _ in [] }, windows: windows.boundary)
        defer { withExtendedLifetime(tree) { windows.detach() } }
        windows.closeBeforeReturning = true
        let saved = Workspace(name: "", tabs: [[tree.url("folder").path]])
        let restored = environment.services.workspaces.openWindows(WorkspacePlan(saved, exists: { _ in true }), name: "")
        #expect(restored.isEmpty && windows.opened.allSatisfy(\.isClosed))
        #expect(windows.shown.isEmpty)
    }

    @Test func invalidDisplayBoundsNeverReachNativeWindowGeometryOrRewriteTheSavedFrame() throws {
        let tree = try TestTree("folder/"), windows = Windows()
        var boundary = windows.boundary
        boundary.frameBounds = { [.zero, CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100)] }
        let environment = try PreviewEnvironment(tree, reader: DirectoryReader { _, _, _ in [] }, windows: boundary)
        defer { withExtendedLifetime(tree) { windows.detach() } }
        let data = try JSONEncoder().encode(try #require(SavedWindowFrame(frame())))
        environment.defaults.set(data, forKey: "browserWindowFrame")
        let owner = try windows.open(tree.url("folder"), services: environment.services)
        #expect(owner.window?.frame.width.isFinite == true && owner.window?.frame.height.isFinite == true)
        #expect(environment.defaults.data(forKey: "browserWindowFrame") == data)
    }

    @Test func validFramesAcrossDisplaysArePreservedAndMissingDisplaysDoNotLeaveAWindowOffscreen() throws {
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let other = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let spanning = try #require(SavedWindowFrame(CGRect(x: 1500, y: 100, width: 1240, height: 650)))
        #expect(WindowSession.restorationFrame(spanning, in: [main, other]) == spanning.rectangle)
        #expect(WindowSession.restorationFrame(spanning, in: [main]) == CGRect(x: 680, y: 100, width: 1240, height: 650))
        #expect(WindowSession.restorationFrame(spanning, in: [.zero]) == nil)
        let gap = try #require(SavedWindowFrame(CGRect(x: 2100, y: 100, width: 200, height: 650)))
        let distant = CGRect(x: 3000, y: 0, width: 1920, height: 1080)
        #expect(WindowSession.restorationFrame(gap, in: [main, distant]) == CGRect(x: 1720, y: 100, width: 200, height: 650))
    }

    @Test func oldSessionsAndMalformedFramesStillRestoreTheirWindows() throws {
        let data = Data(#"[{"name":"old","tabs":[["/a"]]},{"name":"bad-frame","tabs":[["/b"]],"frame":[[0,0],[-1,600]]},{"name":"bad-shape","tabs":[["/c"]],"frame":"bad"}]"#.utf8)
        let decoded = try #require(SessionStorage.decode(data))
        #expect(decoded.count == 3 && decoded.allSatisfy { $0.frame == nil })
        #expect(decoded.map { WorkspacePlan($0, exists: { _ in true }).tabs.count } == [1, 1, 1])
        #expect(SavedWindowFrame(.zero) == nil)
        #expect(SavedWindowFrame(CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100)) == nil)
        #expect(SavedWindowFrame(CGRect(x: 0, y: CGFloat.nan, width: 100, height: 100)) == nil)
        let available = CGRect(x: -1200, y: 40, width: 1200, height: 800)
        let oversized = try #require(SavedWindowFrame(CGRect(x: 1e100, y: -1e100, width: 1e100, height: 1e100)))
        #expect(oversized.fitting(in: available) == available)
        let away = try #require(SavedWindowFrame(CGRect(x: 9000, y: 9000, width: 800, height: 600)))
        #expect(away.fitting(in: available) == CGRect(x: -800, y: 240, width: 800, height: 600))
        let encoded = try JSONEncoder().encode(away)
        let boundary = encoded + Data(repeating: 32, count: SavedWindowFrame.byteLimit - encoded.count)
        #expect(SavedWindowFrame.decode(boundary) == away)
        #expect(SavedWindowFrame.decode(boundary + Data([32])) == nil)
        #expect(SavedWindowFrame.decode(Data("[".utf8)) == nil)
    }
}
