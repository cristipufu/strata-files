import AppKit
import Quartz
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct QuickLookLifecycleTests {
    let testEnvironment: IndependentEnvironment

    init() throws { testEnvironment = try IndependentEnvironment() }

    private func previewHost(in view: NSView) -> QuickLookPreviewView? {
        if let preview = view as? QuickLookPreviewView { return preview }
        return view.subviews.lazy.compactMap { previewHost(in: $0) }.first
    }

    @Test func closingTheInspectorBeforeItsDeferredPreviewDoesNotReviveQuickLook() throws {
        let _ = NSApplication.shared
        let tree = try TestTree("folder/", "note.rtfd/TXT.rtf", "item.bin")
        var pending: DispatchWorkItem?
        let inspector = InspectorViewController(services: testEnvironment.services, previewScheduler: { pending = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = inspector
        defer { window.contentViewController = nil }
        let preview = try #require(previewHost(in: inspector.view))
        // Folders show their icon without starting a live Quick Look folder watcher, while document packages still preview.
        inspector.show(entries: [try #require(FileEntry(url: tree.url("folder")))], folder: nil,
                       folderSize: { _ in nil }, canMeasure: { _ in false })
        #expect(pending == nil && !inspector.iconView.isHidden && preview.isHidden && preview.previewItem == nil)

        let packageEntry = try #require(FileEntry(url: tree.url("note.rtfd")))
        #expect(packageEntry.isDirectory && packageEntry.isPackage && !packageEntry.isFolder)
        inspector.show(entries: [packageEntry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        #expect(pending != nil)
        pending = nil

        inspector.show(entries: [try #require(FileEntry(url: tree.url("item.bin")))], folder: nil,
                       folderSize: { _ in nil }, canMeasure: { _ in false })
        let work = try #require(pending)
        window.close()
        #expect(preview.isClosed)
        work.perform()
        #expect(preview.previewItem == nil)
        #expect(!window.isVisible)
        #expect(tree.snapshot() == ["folder/", "item.bin", "note.rtfd/", "note.rtfd/TXT.rtf"])
    }
    @Test func aClosedNativePreviewRejectsNewItemsAndRefreshes() throws {
        let _ = NSApplication.shared
        let tree = try TestTree("folder/")
        let preview = QuickLookPreviewView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), style: .normal)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = preview
        defer { window.contentView = nil }
        #expect(preview.show(tree.url("folder")))
        #expect(preview.previewItem?.previewItemURL == tree.url("folder"))
        let native = try #require(preview.subviews.first as? QLPreviewView)
        window.close()
        #expect(preview.isClosed)
        #expect(native.previewItem == nil)
        #expect(!preview.show(tree.root))
        preview.refreshPreviewItem()
        preview.close()
        #expect(preview.previewItem == nil)
        let replacement = QuickLookPreviewView(frame: .zero, style: .compact)
        #expect(!replacement.show(tree.url("folder")))
        let nextWindow = NSWindow(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        nextWindow.isReleasedWhenClosed = false
        nextWindow.contentView = replacement
        #expect(replacement.show(tree.url("folder")))
        nextWindow.close()
        nextWindow.contentView = nil
        #expect(tree.snapshot() == ["folder/"])
    }

    @Test func movingAPreviewToAnotherWindowKeepsTheItemAndClosesTheOldNativeView() throws {
        let _ = NSApplication.shared
        let tree = try TestTree("folder/")
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: first.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        let preview = QuickLookPreviewView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), style: .compact)
        first.contentView = preview
        #expect(preview.show(tree.url("folder")))
        let original = try #require(preview.subviews.first as? QLPreviewView)
        first.contentView = nil
        second.contentView = preview
        let replacement = try #require(preview.subviews.first as? QLPreviewView)
        #expect(original !== replacement)
        #expect(original.previewItem == nil)
        #expect(preview.previewItem?.previewItemURL == tree.url("folder"))
        first.close()
        #expect(!preview.isClosed)
        #expect(preview.show(tree.root))
        second.close()
        #expect(preview.isClosed)
        second.contentView = nil
        #expect(tree.snapshot() == ["folder/"])
    }

    @Test func aRichPreviewFallbackAfterWindowCloseCannotRestartQuickLook() async throws {
        let _ = NSApplication.shared
        let tree = try TestTree("binary.swift")
        try Data([0, 1, 0, 2]).write(to: tree.url("binary.swift"))
        var pending: DispatchWorkItem?
        let inspector = InspectorViewController(services: testEnvironment.services, previewScheduler: { pending = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = inspector
        defer { window.contentViewController = nil }
        inspector.show(entries: [try #require(FileEntry(url: tree.url("binary.swift")))], folder: nil,
                       folderSize: { _ in nil }, canMeasure: { _ in false })
        try #require(pending).perform()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let rich = try #require(descendants(inspector.view).compactMap { $0 as? PreviewView }.first)
        let native = try #require(previewHost(in: inspector.view))
        window.close()
        for _ in 0..<200 {
            if !rich.isLoading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!rich.isLoading)
        #expect(native.isClosed && native.previewItem == nil)
        #expect(!descendants(inspector.view).contains { $0 === rich })
        #expect(tree.snapshot() == ["binary.swift"])
        #expect(try Data(contentsOf: tree.url("binary.swift")) == Data([0, 1, 0, 2]))
    }

    @Test func theNativePanelKeepsEditingShortcutsAndOnlyForwardsPlainArrowNavigation() async throws {
        let tree = try TestTree("a.pdf", "b.pdf")
        let browser = BrowserViewController(services: testEnvironment.services)
        _ = browser.view
        browser.load(tree.root)
        await browser.directoryReads.task?.value
        defer { browser.stopBackgroundWork() }
        browser.select([tree.url("a.pdf")])
        let clipboard = testEnvironment.services.clipboard.pasteboard
        clipboard.setString("Keep this clipboard", forType: .string)
        let clipboardChange = clipboard.changeCount
        let localKeys: [(String, UInt16, NSEvent.ModifierFlags)] = [
            ("c", 8, .command), ("a", 0, .command), ("f", 3, .command),
            (" ", 49, []), ("\u{1b}", 53, []), ("\u{7f}", 51, []), ("x", 7, []),
            ("\u{F701}", 125, .shift), ("\u{F701}", 125, .option),
            ("\u{F701}", 125, .control), ("\u{F701}", 125, .command),
        ]
        for (characters, keyCode, modifiers) in localKeys {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
            #expect(!browser.previewPanel(nil, handle: event))
            #expect(browser.selectedURLs == [tree.url("a.pdf")])
        }
        #expect(clipboard.changeCount == clipboardChange)
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F701}",
            charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        #expect(browser.previewPanel(nil, handle: down))
        #expect(browser.selectedURLs == [tree.url("b.pdf")])
        #expect(clipboard.changeCount == clipboardChange)
        #expect(tree.snapshot() == ["a.pdf", "b.pdf"])
    }

}
