import AppKit
import Testing
@testable import Strata
@testable import StrataFiles

extension ColorThemeTests {
    @Test func inspectorPreviewsFollowThePaletteWithoutReloadingOrLosingTextSelection() async throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let tree = try TestTree("note.md", "note.txt", "sample.swift")
        try Data("# Heading\n\nA selected paragraph.\n".utf8).write(to: tree.url("note.md"))
        try Data("A plain text preview.\n".utf8).write(to: tree.url("note.txt"))
        try Data("let value = 42\n".utf8).write(to: tree.url("sample.swift"))
        let inspector = InspectorViewController(services: .shared)
        inspector.view.frame = NSRect(x: 0, y: 0, width: 320, height: 700)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for file in ["note.md", "note.txt", "sample.swift"] {
            let entry = try #require(FileEntry(url: tree.url(file)))
            inspector.show(entries: [entry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
            var preview: PreviewView?
            for _ in 0..<150 {
                preview = descendants(inspector.view).compactMap { $0 as? PreviewView }.first
                if preview?.isLoading == false { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let loaded = try #require(preview)
            try #require(!loaded.isLoading)
            let text = try #require(descendants(loaded).compactMap { $0 as? NSTextView }.first)
            let storage = try #require(text.textStorage)
            let string = text.string
            text.setSelectedRange(NSRange(location: 0, length: min(3, storage.length)))
            let selection = text.selectedRange()
            let backdrop = try #require(descendants(inspector.view).compactMap { $0 as? NSBox }.first { $0.boxType == .custom })
            for palette in ColorTheme.allCases {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                ThemeStyle.refresh(inspector.view)
                inspector.view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    let expected = palette == .system ? NSColor.textBackgroundColor : ThemeStyle.surface(.inspector)
                    #expect(backdrop.fillColor.usingColorSpace(.sRGB) == expected.usingColorSpace(.sRGB))
                    #expect(backdrop.borderColor.usingColorSpace(.sRGB) == ThemeStyle.border.usingColorSpace(.sRGB))
                }
                #expect(text.textStorage === storage && text.string == string)
                #expect(text.selectedRange() == selection)
                #expect(descendants(inspector.view).contains { $0 === loaded })
                #expect(!text.drawsBackground)
            }
        }
        #expect(tree.snapshot() == ["note.md", "note.txt", "sample.swift"])
    }

    @Test func theInspectorPreviewSurroundMatchesThePanelWithoutChangingItsImages() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let inspector = InspectorViewController(services: .shared)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = inspector
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.contentViewController = nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let backdrop = try #require(descendants(inspector.view).compactMap { $0 as? NSBox }.first { $0.boxType == .custom })
        let surround = try #require(backdrop.superview?.subviews.compactMap { $0 as? ThemeSurfaceView }.first)
        let icon = try #require(backdrop.superview?.subviews.compactMap { $0 as? NSImageView }.first)
        try #require(surround.bounds.width > 0 && surround.bounds.height > 0)
        let folderImage = try #require(NSImage(named: NSImage.folderName))
        icon.image = folderImage
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            inspector.view.appearance = appearance
            for palette in ColorTheme.allCases {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                ThemeStyle.refresh(inspector.view)
                #expect(surround.role == .inspector && surround.isHidden == (palette == .system))
                #expect(icon.image === folderImage)
                #expect(!window.isVisible)
                if palette != .system {
                    #expect(try chromePixel(surround, at: NSPoint(x: 4, y: 4), appearance: appearance)
                            == chromeColorPixel(ThemeStyle.surface(.sidebar), appearance: appearance))
                }
            }
        }
    }
}
