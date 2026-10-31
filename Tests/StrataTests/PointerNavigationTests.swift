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

struct PointerNavigationTests {
    @Test func sideButtonsNavigateThePaneUnderThePointerInEveryView() async throws {
        for mode in BrowserViewMode.ordered {
            for index in 0...1 {
                let fixture = try Fixture(mode: mode)
                let owner = fixture.controller.panes[index], other = fixture.controller.panes[1 - index]
                let otherLocation = other.location, current = owner.location
                let previous = fixture.tree.url(index == 0 ? "left/previous" : "right/previous")
                owner.backStack = [.folder(previous)]
                let point = fixture.point(in: owner)
                let window = try #require(fixture.controller.window as? BrowserWindow)
                window.sendEvent(try mouse(button: 3, at: point))
                await owner.browser.directoryReads.task?.value
                #expect(owner.location.standardizedFileURL.fileViewKey == previous.standardizedFileURL.fileViewKey)
                #expect(fixture.controller.pane === owner)
                #expect((window.firstResponder as? NSView)?.isDescendant(of: owner.host.view) == true)
                #expect(other.location == otherLocation)
                window.sendEvent(try mouse(button: 4, at: point))
                await owner.browser.directoryReads.task?.value
                #expect(owner.location.standardizedFileURL.fileViewKey == current.standardizedFileURL.fileViewKey)
                #expect(other.location == otherLocation)
                #expect(fixture.tree.snapshot() == fixture.before)
            }
        }
    }

    @Test func aFluidSwipeKeepsItsOriginatingPaneAndCommitsOnlyOnce() async throws {
        let fixture = try Fixture()
        let owner = fixture.controller.panes[1], other = fixture.controller.panes[0]
        let previous = fixture.tree.url("right/previous")
        owner.backStack = [.folder(previous)]
        var update: BrowserNavigation.SwipeUpdate?
        let wheel = try wheel(x: 10, y: 0, at: fixture.point(in: owner))
        let began = fixture.controller.navigationGestures.beginSwipe(wheel, enabled: true) { _, minimum, maximum, handler in
            #expect(minimum == 0 && maximum == 1)
            update = handler
        }
        #expect(began)
        let complete = try #require(update)
        #expect(!complete(0.4, .changed, false))
        #expect(owner.location.standardizedFileURL.fileViewKey == fixture.tree.url("right/current").standardizedFileURL.fileViewKey)
        fixture.controller.window?.makeFirstResponder(other.browser.focusView)
        #expect(complete(1, [], true))
        await owner.browser.directoryReads.task?.value
        #expect(owner.location.standardizedFileURL.fileViewKey == previous.standardizedFileURL.fileViewKey)
        #expect(other.location.standardizedFileURL.fileViewKey == fixture.tree.url("left/current").standardizedFileURL.fileViewKey)
        #expect(complete(-1, [], true))
        #expect(owner.location.standardizedFileURL.fileViewKey == previous.standardizedFileURL.fileViewKey)
        #expect(fixture.tree.snapshot() == fixture.before)
    }

    @Test func cancelledAndStaleSwipesLeaveTheCurrentFolderAlone() async throws {
        let fixture = try Fixture()
        let controller = fixture.controller, owner = controller.panes[0]
        owner.backStack = [.folder(fixture.tree.url("left/previous"))]
        var update: BrowserNavigation.SwipeUpdate?
        func begin() throws -> BrowserNavigation.SwipeUpdate {
            #expect(controller.navigationGestures.beginSwipe(try wheel(x: 10, y: 0, at: fixture.point(in: owner)), enabled: true) {
                _, _, _, handler in update = handler
            })
            return try #require(update)
        }
        let cancelled = try begin()
        #expect(cancelled(1, .cancelled, true))
        #expect(owner.location.standardizedFileURL.fileViewKey == fixture.tree.url("left/current").standardizedFileURL.fileViewKey)
        let replaced = try begin()
        controller.navigate(to: fixture.tree.url("late"))
        await owner.browser.directoryReads.task?.value
        #expect(replaced(1, [], true))
        #expect(owner.location.standardizedFileURL.fileViewKey == fixture.tree.url("late").standardizedFileURL.fileViewKey)
        let resigned = try begin()
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        #expect(resigned(1, [], true))
        #expect(owner.location.standardizedFileURL.fileViewKey == fixture.tree.url("late").standardizedFileURL.fileViewKey)
        let closed = try begin()
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(closed(1, [], true))
        #expect(owner.location.standardizedFileURL.fileViewKey == fixture.tree.url("late").standardizedFileURL.fileViewKey)
        #expect(fixture.tree.snapshot() == fixture.before)
    }

    @Test func scrollingAndTheSystemSwipePreferenceKeepTheirMeaning() throws {
        let fixture = try Fixture()
        let owner = fixture.controller.panes[0]
        owner.backStack = [.folder(fixture.tree.url("left/previous"))]
        let navigation = fixture.controller.navigationGestures
        let point = fixture.point(in: owner)
        var tracked = false
        let tracker: BrowserNavigation.SwipeTracker = { _, _, _, _ in tracked = true }
        #expect(!navigation.beginSwipe(try wheel(x: 10, y: 0, at: point), enabled: false, track: tracker))
        #expect(!navigation.beginSwipe(try wheel(x: 0, y: 10, at: point), enabled: true, track: tracker))
        #expect(!navigation.beginSwipe(try wheel(x: 10, y: 0, at: point, phase: 0), enabled: true, track: tracker))
        #expect(!navigation.beginSwipe(try wheel(x: 10, y: 0, at: point, momentum: 1), enabled: true, track: tracker))
        for mode in [BrowserViewMode.columns, .gallery] {
            owner.browser.setMode(mode, remember: false)
            #expect(!navigation.canTrackSwipe(at: point))
            #expect(!navigation.beginSwipe(try wheel(x: 10, y: 0, at: point), enabled: true, track: tracker))
        }
        #expect(!tracked)
        #expect(BrowserNavigation.direction(button: 2) == nil)
        #expect(BrowserNavigation.direction(x: .nan, y: 0) == nil)
        #expect(BrowserNavigation.direction(x: 0, y: 1) == nil)
        #expect(owner.location.standardizedFileURL.fileViewKey == fixture.tree.url("left/current").standardizedFileURL.fileViewKey)
        #expect(fixture.tree.snapshot() == fixture.before)
    }

    @Test func aSwipeDoesNotInterruptTextEditingOrANewFolderOpen() async throws {
        let fixture = try Fixture()
        let controller = fixture.controller, owner = controller.panes[0]
        for pane in controller.panes { await pane.browser.directoryReads.task?.value }
        owner.backStack = [.folder(fixture.tree.url("left/previous"))]
        let navigation = controller.navigationGestures, point = fixture.point(in: owner)
        let window = try #require(controller.window)
        let field = NSTextField(string: "Editing")
        field.frame = NSRect(x: 10, y: 10, width: 160, height: 24)
        owner.browser.view.addSubview(field)
        field.selectText(nil)
        let editor = try #require(window.firstResponder as? NSTextView)
        try #require(editor.isFieldEditor)
        let canTrack = navigation.canTrackSwipe(at: point)
        #expect(!canTrack)
        window.makeFirstResponder(owner.browser.focusView)
        var update: BrowserNavigation.SwipeUpdate?
        #expect(navigation.beginSwipe(try wheel(x: 10, y: 0, at: point), enabled: true) { _, _, _, handler in update = handler })
        let complete = try #require(update)
        let gate = PreviewReadGate<URL>()
        let opening = controller.openFolder(operation: { try await gate.read() }, failed: { _ in Issue.record("The controlled folder open should succeed") })
        await gate.waitUntilStarted()
        #expect(complete(1, [], true))
        #expect(owner.location.standardizedFileURL.fileViewKey == fixture.tree.url("left/current").standardizedFileURL.fileViewKey)
        gate.finish(.success(fixture.tree.url("late")))
        await opening.value
        #expect(owner.location.standardizedFileURL.fileViewKey == fixture.tree.url("late").standardizedFileURL.fileViewKey)
        #expect(fixture.tree.snapshot() == fixture.before)
    }

    @Test func aRemovedPaneRejectsItsOldSwipeAndRightToLeftNavigationMirrors() async throws {
        let fixture = try Fixture()
        let controller = fixture.controller, owner = controller.panes[1]
        owner.backStack = [.folder(fixture.tree.url("right/previous"))]
        controller.window?.contentView?.userInterfaceLayoutDirection = .rightToLeft
        var update: BrowserNavigation.SwipeUpdate?
        var limits: (CGFloat, CGFloat)?
        #expect(controller.navigationGestures.beginSwipe(try wheel(x: -10, y: 0, at: fixture.point(in: owner)), enabled: true) {
            _, minimum, maximum, handler in limits = (minimum, maximum); update = handler
        })
        #expect(limits?.0 == -1 && limits?.1 == 0)
        let complete = try #require(update)
        #expect(complete(-1, [], true))
        await owner.browser.directoryReads.task?.value
        #expect(owner.location.standardizedFileURL.fileViewKey == fixture.tree.url("right/previous").standardizedFileURL.fileViewKey)
        #expect(BrowserNavigation.direction(x: 1, y: 0, rightToLeft: true) == .forward)
        owner.backStack = [.folder(fixture.tree.url("right/current"))]
        #expect(controller.navigationGestures.beginSwipe(try wheel(x: -10, y: 0, at: fixture.point(in: owner)), enabled: true) {
            _, _, _, handler in update = handler
        })
        let closed = try #require(update)
        let before = owner.location
        controller.focusOtherPane(nil)
        controller.toggleDualPane(nil)
        #expect(closed(-1, [], true))
        #expect(owner.location == before)
        #expect(fixture.tree.snapshot() == fixture.before)
    }

    @Test func aPendingSwipeDoesNotKeepItsWindowControllerAlive() throws {
        var tree: TestTree?, environment: PreviewEnvironment?
        var before: [String] = []
        weak var released: BrowserWindowController?
        var update: BrowserNavigation.SwipeUpdate?
        try autoreleasepool {
            let active = try Fixture()
            tree = active.tree; environment = active.environment; before = active.before
            released = active.controller
            let owner = active.controller.panes[0]
            owner.backStack = [.folder(active.tree.url("left/previous"))]
            let started = active.controller.navigationGestures.beginSwipe(try wheel(x: 10, y: 0, at: active.point(in: owner)), enabled: true) {
                _, _, _, handler in update = handler
            }
            #expect(started)
        }
        let wasReleased = released == nil
        #expect(wasReleased)
        let complete = try #require(update)
        #expect(complete(1, [], true))
        let retainedEnvironment = try #require(environment), retainedTree = try #require(tree)
        #expect(retainedEnvironment.services.preferences === retainedEnvironment.preferences)
        #expect(retainedTree.snapshot() == before)
    }

    private func located(_ event: CGEvent, at point: NSPoint) throws -> NSEvent {
        event.flags = []
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 0)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: 0)
        let initial = try #require(NSEvent(cgEvent: event)).locationInWindow
        let location = event.location
        event.location = CGPoint(x: location.x + point.x - initial.x, y: location.y + initial.y - point.y)
        let result = try #require(NSEvent(cgEvent: event))
        #expect(abs(result.locationInWindow.x - point.x) < 1 && abs(result.locationInWindow.y - point.y) < 1)
        return result
    }

    private func mouse(button: Int64, at point: NSPoint) throws -> NSEvent {
        let source = try #require(CGEventSource(stateID: .privateState))
        let event = try #require(CGEvent(mouseEventSource: source, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center))
        event.setIntegerValueField(.mouseEventButtonNumber, value: button)
        return try located(event, at: point)
    }

    private func wheel(x: Int32, y: Int32, at point: NSPoint, phase: Int64 = 1, momentum: Int64 = 0) throws -> NSEvent {
        let source = try #require(CGEventSource(stateID: .privateState))
        let event = try #require(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return try located(event, at: point)
    }
}

private final class Fixture {
    let tree: TestTree
    let environment: PreviewEnvironment
    let controller: BrowserWindowController
    let before: [String]

    init(mode: BrowserViewMode = .list) throws {
        tree = try TestTree("left/current/a", "left/previous/a", "right/current/b", "right/previous/b", "late/")
        environment = try PreviewEnvironment(tree)
        controller = BrowserWindowController(location: tree.url("left/current"), secondPane: tree.url("right/current"), services: environment.services)
        controller.window?.setFrameAutosaveName("")
        controller.window?.contentView?.userInterfaceLayoutDirection = .leftToRight
        controller.split.splitView.autosaveName = nil
        for pane in controller.panes { pane.browser.setMode(mode, remember: false) }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        before = tree.snapshot()
    }

    func point(in pane: Pane) -> NSPoint {
        pane.host.view.convert(NSPoint(x: pane.host.view.bounds.midX, y: pane.host.view.bounds.midY), to: nil)
    }

    isolated deinit {
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.window?.contentViewController = nil
    }
}
