import AppKit
import CPreviewText
import Testing
import os
@testable import Strata
@testable import StrataModel
@testable import StrataPreviews
@testable import StrataSupport

@MainActor struct CodeWrappingTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func text(in view: NSView) throws -> STPreviewTextView {
        if let text = view as? STPreviewTextView { return text }
        for child in view.subviews {
            if let found = try? text(in: child) { return found }
        }
        throw CocoaError(.coderValueNotFound)
    }

    private func layout(_ view: NSView) throws -> (STPreviewTextView, Int) {
        view.layoutSubtreeIfNeeded()
        let text = try text(in: view)
        let manager = try #require(text.layoutManager), container = try #require(text.textContainer)
        manager.ensureLayout(for: container)
        var fragments = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, _, _ in fragments += 1 }
        return (text, fragments)
    }

    @Test(arguments: ["note.txt", "source.swift", "data.json"])
    func textCodeAndJSONWrapByDefaultWithoutChangingTheirFiles(_ name: String) async throws {
        let tree = try TestTree(name)
        let payload = String(repeating: "wide words 😀 ", count: 40)
        let original = name.hasSuffix("json") ? "{\"message\":\"\(payload)\"}" : "\(payload)\nsecond line\nlast line"
        try Data(original.utf8).write(to: tree.url(name))
        let preferences = try Prefs.isolated()
        #expect(preferences.previewWrapLines)
        let view = try #require(RichPreview.makeView(for: tree.url(name), contentType: .plainText,
                                                    preferences: preferences) as? CodePreviewView)
        defer { view.cancelLoad() }
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 220)
        view.layoutSubtreeIfNeeded()
        await view.loadingTask?.value
        let (text, fragments) = try layout(view)
        let scroll = try #require(text.enclosingScrollView)
        #expect(text.textContainer?.widthTracksTextView == true)
        #expect(!scroll.hasHorizontalScroller)
        #expect(text.string.contains(payload))
        #expect(fragments > text.string.components(separatedBy: "\n").count)
        #expect(text.frame.width <= scroll.contentSize.width)
        #expect(text.frame.height > scroll.contentSize.height)
        let ruler = try #require(scroll.verticalRulerView as? LineNumberRuler)
        #expect(ruler.labels(in: text.bounds).map { $0.number } == Array(1...text.string.components(separatedBy: "\n").count))
        _ = view.dataWithPDF(inside: view.bounds)
        #expect(text.renderingError == nil)
        #expect(try String(contentsOf: tree.url(name), encoding: .utf8) == original)
        #expect(tree.snapshot() == [name])
    }

    @Test func resizingAndSwitchingWrappingKeepTheDocumentSelectionAndSingleRead() async throws {
        let tree = try TestTree("source.swift")
        let original = String(repeating: "let veryLongName = \"some words 😀 to read\"; ", count: 20) + "\nlast line"
        try Data(original.utf8).write(to: tree.url("source.swift"))
        let url = tree.url("source.swift"), reads = OSAllocatedUnfairLock(initialState: 0)
        let preferences = try Prefs.isolated()
        let view = CodePreviewView(source: {
            reads.withLock { $0 += 1 }
            return try TextFile.read(url)
        }, language: Languages.swift, preferences: preferences)
        defer { view.cancelLoad() }
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 200)
        view.layoutSubtreeIfNeeded()
        await view.loadingTask?.value
        let (text, narrow) = try layout(view)
        let storage = try #require(text.textStorage)
        text.setSelectedRange(NSRange(location: 4, length: 12))
        view.setFrameSize(NSSize(width: 800, height: 200))
        let (_, wide) = try layout(view)
        #expect(wide < narrow)
        let toggle = try #require(descendants(view).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "preview.wrapLines" })
        toggle.performClick(nil)
        #expect(!preferences.previewWrapLines)
        _ = try layout(view)
        #expect(text.textContainer?.widthTracksTextView == false)
        #expect(text.enclosingScrollView?.hasHorizontalScroller == true)
        #expect(text.frame.width > view.bounds.width)
        let manager = try #require(text.layoutManager), container = try #require(text.textContainer)
        #expect(manager.usedRect(for: container).maxX + text.textContainerOrigin.x <= text.frame.width)
        toggle.performClick(nil)
        #expect(preferences.previewWrapLines)
        let (_, wrapped) = try layout(view)
        #expect(wrapped == wide)
        #expect(text.textStorage === storage && text.string == original)
        #expect(text.selectedRange() == NSRange(location: 4, length: 12))
        #expect(reads.withLock { $0 } == 1)
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
        #expect(tree.snapshot() == ["source.swift"])
    }

    @Test func aLongUnbrokenLineWrapsAndTheOffChoiceSurvivesReopening() async throws {
        let tree = try TestTree("source.swift")
        let original = String(repeating: "abcdef1234", count: 150) + "\nlast line"
        try Data(original.utf8).write(to: tree.url("source.swift"))
        let preferences = try Prefs.isolated()
        let view = CodePreviewView(url: tree.url("source.swift"), mode: .source(Languages.swift), preferences: preferences)
        defer { view.cancelLoad() }
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 200)
        view.layoutSubtreeIfNeeded()
        await view.loadingTask?.value
        let (text, wrapped) = try layout(view)
        #expect(wrapped > 2 && text.string == original)
        preferences.previewWrapLines = false
        let reopened = Prefs(defaults: try #require(UserDefaults(suiteName: preferences.domainName)),
                             domainName: preferences.domainName)
        #expect(!reopened.previewWrapLines)
        let next = CodePreviewView(url: tree.url("source.swift"), mode: .source(Languages.swift), preferences: reopened)
        defer { next.cancelLoad() }
        next.frame = view.frame
        next.layoutSubtreeIfNeeded()
        await next.loadingTask?.value
        let (unwrapped, fragments) = try layout(next)
        #expect(fragments == 2)
        #expect(unwrapped.enclosingScrollView?.hasHorizontalScroller == true)
        #expect(tree.snapshot() == ["source.swift"])
    }

    @Test func hiddenPreviewsApplyWrappingWhenTheyAreShownAgain() async throws {
        let tree = try TestTree("source.swift")
        let preferences = try Prefs.isolated()
        let view = CodePreviewView(url: tree.url("source.swift"), mode: .source(Languages.swift), preferences: preferences)
        defer { view.cancelLoad() }
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 200)
        await view.loadingTask?.value
        let (text, _) = try layout(view)
        view.isHidden = true
        preferences.previewWrapLines = false
        view.layoutSubtreeIfNeeded()
        #expect(text.textContainer?.widthTracksTextView == true)
        view.isHidden = false
        _ = try layout(view)
        #expect(text.textContainer?.widthTracksTextView == false)
        #expect(tree.snapshot() == ["source.swift"])
    }

    @Test func aLargeWrappedPreviewLeavesOffscreenLayoutLazy() async throws {
        let tree = try TestTree("source.swift")
        let original = String(repeating: "let value = \"a moderately long line of source code\";\n", count: 8_000)
        try Data(original.utf8).write(to: tree.url("source.swift"))
        let view = CodePreviewView(url: tree.url("source.swift"), mode: .source(Languages.swift), preferences: try Prefs.isolated())
        defer { view.cancelLoad() }
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 200)
        view.layoutSubtreeIfNeeded()
        await view.loadingTask?.value
        view.layoutSubtreeIfNeeded()
        let text = try text(in: view)
        let manager = try #require(text.layoutManager)
        #expect(manager.allowsNonContiguousLayout)
        #expect(!manager.backgroundLayoutEnabled)
        #expect(manager.firstUnlaidCharacterIndex() < text.string.utf16.count)
        #expect(tree.snapshot() == ["source.swift"])
    }

    @Test func spaceAndInspectorKeepTheirOwnersWrappingPreference() async throws {
        let tree = try TestTree("source.swift")
        try Data(String(repeating: "let value = 1; ", count: 30).utf8).write(to: tree.url("source.swift"))
        let first = try PreviewEnvironment(tree), second = try IndependentEnvironment()
        let before = tree.snapshot()
        first.preferences.previewWrapLines = false
        let entry = try #require(FileEntry(url: tree.url("source.swift")))
        let file = PreviewFileView(thumbnails: first.services.thumbnails, copies: first.services.copies, preferences: first.preferences)
        defer { file.close() }
        file.frame = NSRect(x: 0, y: 0, width: 400, height: 250)
        file.show(nil, root: entry)
        let inspector = InspectorViewController(services: first.services, previewScheduler: { $0.perform() })
        inspector.view.frame = NSRect(x: 0, y: 0, width: 400, height: 700)
        inspector.show(entries: [entry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        let rich = try #require(inspector.richPreview as? CodePreviewView)
        await rich.loadingTask?.value
        let preview = try text(in: file)
        let info = try text(in: rich)
        #expect(preview.textContainer?.widthTracksTextView == false)
        #expect(info.textContainer?.widthTracksTextView == false)
        second.preferences.previewWrapLines = false
        first.preferences.previewWrapLines = true
        file.layoutSubtreeIfNeeded()
        rich.layoutSubtreeIfNeeded()
        #expect(preview.textContainer?.widthTracksTextView == true)
        #expect(info.textContainer?.widthTracksTextView == true)
        #expect(!second.preferences.previewWrapLines)
        withExtendedLifetime((first, second)) {}
        #expect(tree.text("source.swift") == String(repeating: "let value = 1; ", count: 30))
        #expect(tree.snapshot() == before)
    }
}
