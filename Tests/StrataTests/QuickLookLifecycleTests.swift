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
    private func previewHost(in view: NSView) -> QuickLookPreviewView? {
        if let preview = view as? QuickLookPreviewView { return preview }
        return view.subviews.lazy.compactMap { previewHost(in: $0) }.first
    }

    @Test func closingTheInspectorBeforeItsDeferredPreviewDoesNotReviveQuickLook() throws {
        let _ = NSApplication.shared
        let tree = try TestTree("folder/")
        var pending: DispatchWorkItem?
        let inspector = InspectorViewController(services: .shared, previewScheduler: { pending = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = inspector
        defer { window.contentViewController = nil }
        let preview = try #require(previewHost(in: inspector.view))
        inspector.show(entries: [try #require(FileEntry(url: tree.url("folder")))], folder: nil,
                       folderSize: { _ in nil }, canMeasure: { _ in false })
        let work = try #require(pending)
        window.close()
        #expect(preview.isClosed)
        work.perform()
        #expect(preview.previewItem == nil)
        #expect(!window.isVisible)
        #expect(tree.snapshot() == ["folder/"])
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
        let inspector = InspectorViewController(services: .shared, previewScheduler: { pending = $0 })
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

}
