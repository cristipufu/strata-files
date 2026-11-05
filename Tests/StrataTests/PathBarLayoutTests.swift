import AppKit
import Testing
@testable import Strata
@testable import StrataSupport

@MainActor struct PathBarLayoutTests {
    @Test func clearedTitlesAndCollapsedBarsHaveSafeGeometry() throws {
        _ = NSApplication.shared
        let crumbs = PathBreadcrumbs()
        crumbs.layoutSubtreeIfNeeded()
        #expect(crumbs.buttons.isEmpty)
        let button = CrumbButton(title: "Search: a long result title", symbol: "magnifyingglass", emphasized: true)
        crumbs.show([PathBreadcrumbs.Step(button: button)])
        for width in [0.0, 12.0, 100.0, 500.0, 0.0] {
            crumbs.frame = NSRect(x: 0, y: 0, width: width, height: 24)
            crumbs.layoutSubtreeIfNeeded()
            #expect(button.frame.width >= 0 && button.frame.maxX <= width)
            let text = try #require(button.cell).titleRect(forBounds: button.bounds)
            #expect(text.width >= 0 && text.height >= 0)
        }
        crumbs.show([])
        crumbs.layoutSubtreeIfNeeded()
        #expect(crumbs.buttons.isEmpty && crumbs.subviews.isEmpty)
    }

    @Test(arguments: [false, true], ["chat-design-previews", "项目与图片预览的长文件夹名称"])
    func currentFolderAndItsHoverFitInsideANarrowBar(_ embedded: Bool, name: String) throws {
        let environment = try IndependentEnvironment()
        let bar = makeBar(environment, embedded: embedded)
        let folder = URL(filePath: "/Users/example/Documents/GitHub/project/build/" + name, directoryHint: .isDirectory)
        bar.url = folder
        let window = try host(bar)
        defer { window.contentView = nil }
        for width in [200.0, 240.0, 320.0, 520.0, 720.0, 200.0] {
            window.setContentSize(NSSize(width: width + 32, height: 64))
            try checkFitting(bar, in: window, folder: folder)
        }
        #expect(!window.isVisible)
    }

    @Test(arguments: [false, true], [false, true])
    func lateGitDetailsPreserveReadableFoldersAndCompleteParents(_ embedded: Bool, repositoryIsCurrent: Bool) throws {
        let environment = try IndependentEnvironment()
        let bar = makeBar(environment, embedded: embedded)
        let folder = URL(filePath: "/Users/example/Documents/GitHub/project/build/chat-design-previews", directoryHint: .isDirectory)
        bar.url = folder
        let window = try host(bar)
        defer { window.contentView = nil }
        try checkFitting(bar, in: window, folder: folder)
        bar.gitRoot = repositoryIsCurrent ? folder : folder.deletingLastPathComponent().deletingLastPathComponent()
        for branch in ["main", String(repeating: "feature/long-branch-name", count: 4), "main"] {
            bar.branchPill.model = .init(branch: branch)
            for width in [200.0, 240.0, 320.0, 520.0, 720.0, 200.0] {
                window.setContentSize(NSSize(width: width + 32, height: 64))
                try checkFitting(bar, in: window, folder: folder)
            }
        }
        bar.branchPill.model = nil
        try checkFitting(bar, in: window, folder: folder)
        #expect(bar.branchPill.isHidden)
        #expect(!window.isVisible)
    }

    private func makeBar(_ environment: IndependentEnvironment, embedded: Bool) -> PathBar {
        let services = environment.services
        return PathBar(preferences: services.preferences, places: services.places, index: services.index,
                       copies: services.copies, names: services.folderNames, clipboard: services.clipboard, embedded: embedded)
    }

    private func host(_ bar: PathBar) throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 232, height: 64),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let root = try #require(window.contentView)
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bar.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 32),
        ])
        return window
    }

    private func checkFitting(_ bar: PathBar, in window: NSWindow, folder: URL) throws {
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()
        let current = try #require(bar.crumbButtons.last)
        #expect(current.title == folder.lastPathComponent)
        #expect(current.destination?.lexicallyStandardized.path == folder.lexicallyStandardized.path)
        #expect(!current.isHidden && current.frame.width >= min(96, current.intrinsicContentSize.width))
        for button in bar.crumbButtons where !button.isHidden {
            let frame = button.convert(button.bounds, to: bar)
            #expect(frame.minX >= 6 && frame.maxX <= bar.bounds.maxX - 6)
            if button !== current { #expect(button.frame.width >= button.intrinsicContentSize.width) }
        }
        let crumbs = try #require(current.superview)
        let arrows = crumbs.subviews.compactMap { $0 as? ChevronButton }.filter { !$0.isHidden }
        #expect(arrows.count == bar.crumbButtons.dropLast().filter { !$0.isHidden }.count)
        for arrow in arrows {
            let frame = arrow.convert(arrow.bounds, to: bar)
            #expect(frame.minX >= 6 && frame.maxX <= bar.bounds.maxX - 6)
        }
        if !bar.branchPill.isHidden {
            let branch = bar.branchPill.convert(bar.branchPill.bounds, to: bar)
            #expect(branch.minX >= 6 && branch.maxX <= bar.bounds.maxX - 6)
        }
        let paragraph = current.attributedTitle.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(paragraph?.lineBreakMode == .byTruncatingTail)
        let text = try #require(current.cell).titleRect(forBounds: current.bounds)
        #expect(text.minX >= 8 && text.maxX <= current.bounds.maxX - 8)
        if current.frame.width >= current.intrinsicContentSize.width {
            #expect(text.width >= ceil(current.attributedTitle.size().width))
        }
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
                                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                      eventNumber: 0, trackingNumber: 0, userData: nil))
        current.mouseEntered(with: event)
        let highlight = try #require(current.layer)
        #expect(highlight.backgroundColor != nil)
        let image = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: image)
        let barLayer = try #require(bar.layer)
        let hover = highlight.convert(highlight.bounds, to: barLayer)
        #expect(hover.minX >= 6 && hover.maxX <= bar.bounds.maxX - 6)
        current.mouseExited(with: event)
        #expect(highlight.backgroundColor == nil)
    }
}
