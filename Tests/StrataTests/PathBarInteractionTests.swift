import AppKit
import Synchronization
import Testing
@testable import Strata

@MainActor struct PathBarInteractionTests {
    enum Ending: CaseIterable, Sendable { case hide, hideAndShow, detach, otherWindow, close }

    @Test(arguments: Ending.allCases)
    func aChevronDropsItsLookupWhenItsPresentationEnds(_ ending: Ending) async throws {
        let gate = PreviewReadGate<[URL]>()
        let folder = URL(filePath: "/fixture/parent", directoryHint: .isDirectory)
        var presented: [[URL]] = []
        let button = ChevronButton(folder: folder, name: "parent", readFolders: { _ in (try? await gate.read()) ?? [] },
                                   presentMenu: { _, folders in presented.append(folders) }, navigate: { _ in })
        let window = try host(button), other = try host(NSView())
        defer { window.contentView = nil; other.contentView = nil }
        #expect(NSApp.sendAction(try #require(button.action), to: button, from: button))
        let task = try #require(button.reading)
        await gate.waitUntilStarted()
        switch ending {
        case .hide: button.isHidden = true
        case .hideAndShow: button.isHidden = true; button.isHidden = false
        case .detach: button.removeFromSuperview()
        case .otherWindow: other.contentView?.addSubview(button)
        case .close: NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        }
        #expect(task.isCancelled)
        gate.finish(.success([folder.appending(path: "child")]))
        await task.value
        #expect(presented.isEmpty)
        #expect(button.reading == nil)
    }

    @Test(arguments: [false, true])
    func replacingAChevronLookupKeepsOnlyTheNewResult(_ oldFinishesFirst: Bool) async throws {
        let gates = [PreviewReadGate<[URL]>(), PreviewReadGate<[URL]>()]
        let calls = Mutex(0)
        let folder = URL(filePath: "/fixture/parent", directoryHint: .isDirectory)
        var presented: [[URL]] = []
        let button = ChevronButton(folder: folder, name: "parent", readFolders: { _ in
            let index = calls.withLock { current in defer { current += 1 }; return current }
            guard gates.indices.contains(index) else { return [] }
            return (try? await gates[index].read()) ?? []
        }, presentMenu: { _, folders in presented.append(folders) }, navigate: { _ in })
        let window = try host(button)
        defer { window.contentView = nil }
        #expect(NSApp.sendAction(try #require(button.action), to: button, from: button))
        let old = try #require(button.reading)
        await gates[0].waitUntilStarted()
        #expect(NSApp.sendAction(try #require(button.action), to: button, from: button))
        let current = try #require(button.reading)
        await gates[1].waitUntilStarted()
        #expect(old.isCancelled && !current.isCancelled)
        if oldFinishesFirst {
            gates[0].finish(.success([folder.appending(path: "old")]))
            await old.value
            #expect(presented.isEmpty && button.reading != nil)
        }
        let expected = [folder.appending(path: "new")]
        gates[1].finish(.success(expected))
        await current.value
        if !oldFinishesFirst {
            gates[0].finish(.success([folder.appending(path: "old")]))
            await old.value
        }
        #expect(presented == [expected])
        #expect(button.reading == nil)
    }

    @Test func unavailableChevronsStartNoLookup() throws {
        let button = ChevronButton(folder: URL(filePath: "/fixture/parent"), name: "parent",
            readFolders: { _ in Issue.record("An unavailable button started a read"); return [] },
            presentMenu: { _, _ in Issue.record("An unavailable button presented a menu") }, navigate: { _ in })
        let window = try host(button)
        defer { window.contentView = nil }
        let action = try #require(button.action)
        button.isHidden = true
        #expect(NSApp.sendAction(action, to: button, from: nil))
        #expect(button.reading == nil)
        button.isHidden = false
        button.isEnabled = false
        #expect(NSApp.sendAction(action, to: button, from: nil))
        #expect(button.reading == nil)
        button.isEnabled = true
        window.shown = false
        #expect(NSApp.sendAction(action, to: button, from: nil))
        #expect(button.reading == nil)
    }

    @Test func aPendingLookupDoesNotRetainItsButton() async throws {
        let gate = PreviewReadGate<[URL]>()
        let folder = URL(filePath: "/fixture/parent", directoryHint: .isDirectory)
        let window = try host(NSView())
        defer { window.contentView = nil }
        var button: ChevronButton?
        let task = try autoreleasepool {
            let control = ChevronButton(folder: folder, name: "parent", readFolders: { _ in (try? await gate.read()) ?? [] },
                                        presentMenu: { _, _ in Issue.record("Late menu") }, navigate: { _ in })
            button = control
            window.contentView?.addSubview(control)
            #expect(NSApp.sendAction(try #require(control.action), to: control, from: control))
            return try #require(control.reading)
        }
        await gate.waitUntilStarted()
        weak var released = button
        autoreleasepool { button?.removeFromSuperview(); button = nil }
        #expect(released == nil && task.isCancelled)
        gate.finish(.success([folder]))
        await task.value
    }

    @Test func cancellingAQueuedLookupDoesNotStartTheReader() async throws {
        let calls = Mutex(0)
        let button = ChevronButton(folder: URL(filePath: "/fixture/parent"), name: "parent", readFolders: { _ in
            calls.withLock { $0 += 1 }; return []
        }, presentMenu: { _, _ in Issue.record("Cancelled menu") }, navigate: { _ in })
        let window = try host(button)
        defer { window.contentView = nil }
        #expect(NSApp.sendAction(try #require(button.action), to: button, from: button))
        let task = try #require(button.reading)
        button.isHidden = true
        await task.value
        #expect(calls.withLock { $0 } == 0)
        #expect(button.reading == nil)
    }

    @Test func hiddenBreadcrumbButtonsReleaseTheirHoverHighlights() throws {
        let crumb = CrumbButton(title: "parent", symbol: nil, emphasized: false)
        let chevron = ChevronButton(folder: URL(filePath: "/fixture/parent"), name: "parent", navigate: { _ in })
        for button in [crumb as NSButton, chevron] {
            let window = try host(button)
            defer { window.contentView = nil }
            let event = try enterEvent(window)
            button.mouseEntered(with: event)
            #expect(button.layer?.backgroundColor != nil)
            button.isHidden = true
            #expect(button.layer?.backgroundColor == nil)
            button.isHidden = false
            button.mouseExited(with: event)
            button.mouseEntered(with: event)
            button.removeFromSuperview()
            #expect(button.layer?.backgroundColor == nil)
        }
    }

    @Test func theBranchBadgeDoesNotRestoreAnOldHoverAfterBeingHidden() throws {
        let environment = try IndependentEnvironment()
        let badge = GitBranchPill(clipboard: environment.services.clipboard)
        badge.model = .init(branch: "main")
        let window = try host(badge)
        defer { window.contentView = nil }
        let normal = try background(of: badge)
        let event = try enterEvent(window)
        badge.mouseEntered(with: event)
        #expect(try background(of: badge) != normal)
        badge.isHidden = true
        badge.isHidden = false
        #expect(try background(of: badge) == normal)
    }

    @Test(arguments: [nil as String?, "house.fill", "magnifyingglass"])
    func paddedBreadcrumbsKeepTheirFullClickAreaAndNativeAccessibility(_ symbol: String?) throws {
        let button = CrumbButton(title: "chat-design-previews", symbol: symbol, emphasized: true)
        let window = try host(button)
        defer { window.contentView = nil }
        let native = NSButton(title: button.title, target: nil, action: nil)
        native.attributedTitle = button.attributedTitle
        native.image = button.image
        native.imagePosition = button.imagePosition
        native.imageHugsTitle = button.imageHugsTitle
        #expect(button.accessibilityRole() == native.accessibilityRole())
        #expect(button.accessibilityLabel() == native.accessibilityLabel())
        let cell = try #require(button.cell)
        let text = cell.titleRect(forBounds: button.bounds)
        #expect(text.minX >= 8 && text.maxX <= button.bounds.maxX - 8)
        #expect(text.width >= ceil(button.attributedTitle.size().width))
        if symbol != nil {
            let icon = cell.imageRect(forBounds: button.bounds)
            #expect(icon.minX >= 0 && icon.maxX <= text.minX)
        }
        for x in [1.0, button.bounds.midX, button.bounds.maxX - 1] {
            let point = button.convert(NSPoint(x: x, y: button.bounds.midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil,
                                                       eventNumber: 0, clickCount: 1, pressure: 1))
            let hit = try #require(button.cell).hitTest(for: event, in: button.bounds, of: button)
            #expect(hit.contains(.trackableArea))
        }
        for x in [-1.0, button.bounds.maxX + 1] {
            let point = button.convert(NSPoint(x: x, y: button.bounds.midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil,
                                                       eventNumber: 0, clickCount: 1, pressure: 1))
            #expect(try #require(button.cell).hitTest(for: event, in: button.bounds, of: button).isEmpty)
        }
        button.isEnabled = false
        let point = button.convert(NSPoint(x: 1, y: button.bounds.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(try #require(button.cell).hitTest(for: event, in: button.bounds, of: button).contains(.trackableArea) == false)
    }

    private func host(_ view: NSView) throws -> MenuWindow {
        _ = NSApplication.shared
        let window = MenuWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 64),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        let root = try #require(window.contentView)
        let natural = view.intrinsicContentSize
        view.frame = NSRect(x: 16, y: 16, width: max(0, natural.width), height: max(0, natural.height))
        root.addSubview(view)
        return window
    }

    private func enterEvent(_ window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil,
                                           eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    private func background(of view: NSView) throws -> NSColor {
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        return try #require(image.colorAt(x: 2, y: image.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
    }

    private final class MenuWindow: NSWindow {
        var shown = true
        override var isVisible: Bool { shown }
    }
}
