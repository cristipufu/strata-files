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

extension ColorThemeTests {
    @Test func previewIconsKeepTheNativeGridSelectionAndThumbnailAcrossEveryPaletteAndAppearance() async throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let tree = try TestTree("photo.png")
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let env = try PreviewEnvironment(tree, makeThumbnails: { copies, store in
            FileThumbnails(copies: copies, containerStore: store, generate: { _, complete in complete(image, false) })
        })
        env.preferences.showIconPreviews = true
        let before = tree.snapshot()
        let grid = PreviewGridController(preferences: env.preferences, thumbnails: env.services.thumbnails)
        let window = PreviewGridKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                                           styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSViewController()
        host.view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        ThemeStyle.bind(host.view, to: .content)
        host.addChild(grid)
        grid.view.frame = host.view.bounds
        grid.view.autoresizingMask = [.width, .height]
        host.view.addSubview(grid.view)
        window.contentViewController = host
        window.setContentSize(NSSize(width: 500, height: 400))
        defer { grid.close(); window.contentViewController = nil; window.close() }
        let item = PreviewItem(.file(try #require(FileEntry(url: tree.url("photo.png")))))
        grid.apply([item], selected: item)
        window.contentView?.layoutSubtreeIfNeeded()
        (grid.view as? NSScrollView)?.tile()
        grid.collection.layoutSubtreeIfNeeded()
        try #require(grid.collection.numberOfSections == 1 && grid.collection.numberOfItems(inSection: 0) == 1)
        try #require(grid.collection.bounds.width > 0 && grid.collection.bounds.height > 0,
                     "window \(window.frame), scroll \(grid.view.frame), collection \(grid.collection.frame)")
        let cell = try #require(grid.collection.item(at: IndexPath(item: 0, section: 0)) as? PreviewGridItem)
        let backdrop = try #require(host.view.subviews.compactMap { $0 as? ThemeSurfaceView }.first)
        let entry = try #require(item.entry)
        let deadline = ContinuousClock.now + .seconds(20)
        while env.services.thumbnails.cached(entry, size: 80, scale: window.backingScaleFactor) == nil,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let thumbnail = try #require(env.services.thumbnails.cached(entry, size: 80, scale: window.backingScaleFactor)?.image)
        #expect(cell.itemView.imageView.image === thumbnail)
        try #require(window.makeFirstResponder(grid.collection))
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(cell.itemView.state.emphasized)
        let selected: Set<IndexPath> = [IndexPath(item: 0, section: 0)]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            window.appearance = appearance
            for highContrast in [false, true] {
                for palette in ColorTheme.allCases {
                    ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: highContrast)
                    #expect(grid.collection.selectionIndexPaths == selected && cell.item === item)
                    #expect(cell.itemView.imageView.image === thumbnail)
                    #expect(grid.collection.item(at: IndexPath(item: 0, section: 0)) === cell)
                    if ThemeStyle.colorsSurfaces {
                        let expected = try chromeColorPixel(ThemeStyle.surface(.content), appearance: appearance)
                        #expect(try chromePixel(backdrop, at: NSPoint(x: 4, y: 4), appearance: appearance) == expected)
                        let background = try #require(grid.collection.backgroundColors.first)
                        #expect(try chromeColorPixel(background, appearance: appearance) == expected)
                    }
                    #expect(!window.isVisible)
                }
            }
        }
        env.preferences.nameTextSize = 16
        grid.updateAppearance()
        #expect(cell.itemView.metrics.typography.font.pointSize == 16 && cell.itemView.imageView.image === thumbnail)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        grid.view.addSubview(editor)
        try #require(window.makeFirstResponder(editor))
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(!cell.itemView.state.emphasized)
        #expect(tree.snapshot() == before)
        withExtendedLifetime(env) {}
    }
}

private final class PreviewGridKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
