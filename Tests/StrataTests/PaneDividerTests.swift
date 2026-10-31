import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

struct PaneDividerTests {
    @Test(arguments: [BrowserViewMode.columns, .treemap, .list, .grid, .gallery])
    func closingTheOtherPaneKeepsItsDividerOutOfTheSharedFooter(_ mode: BrowserViewMode) async throws {
        let first = PaneHostViewController(browser: BrowserViewController(services: .shared))
        first.browser.setMode(mode, remember: false)
        let controller = MainSplitViewController(firstPane: first)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.status.text = "38 items · 1 selected · 285 GB available"
        defer { window.contentViewController = nil }

        func layout() async {
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
            window.contentView?.layoutSubtreeIfNeeded()
        }
        for width in [1240.0, 960.0, 1240.0] {
            window.setContentSize(NSSize(width: width, height: 780))
            let second = PaneHostViewController(browser: BrowserViewController(services: .shared))
            second.browser.setMode(mode, remember: false)
            controller.panes.add(second)
            controller.status.isHidden = true
            first.setStatus("First pane")
            second.setStatus("Second pane")
            await layout()
            #expect(controller.panes.splitViewItems.count == 2)

            controller.panes.remove(second)
            controller.status.isHidden = false
            first.setStatus(nil)
            await layout()
            let panes = controller.panes.view.convert(controller.panes.view.bounds, to: controller.view)
            let footer = controller.status.view.convert(controller.status.view.bounds, to: controller.view)
            #expect(controller.panes.splitViewItems.count == 1)
            try #require(panes.height > 100 && footer.height == 28)
            #expect(!panes.intersects(footer), "The pane split view must end above the shared footer, including its cached divider.")
        }
    }

    @Test func dividerStaysBetweenTheToolbarAndSharedFooter() throws {
        let panes = PaneContainerViewController(first: PaneHostViewController(browser: BrowserViewController(services: .shared)))
        let split = panes.splitView
        split.frame = NSRect(x: 0, y: 0, width: 600, height: 400)

        // The toolbar, search bar and footer change these insets. Render the actual divider without an opaque
        // browser covering it, as Columns and Disk Usage leave the shared footer exposed.
        for (top, bottom) in [(66.0, 46.0), (96.0, 72.0), (0.0, 28.0), (0.0, 0.0)] {
            split.additionalSafeAreaInsets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
            split.layoutSubtreeIfNeeded()
            let image = NSImage(size: split.bounds.size)
            image.lockFocusFlipped(true)
            NSColor.magenta.setFill()
            split.bounds.fill()
            split.drawDivider(in: NSRect(x: 300, y: 0, width: 1, height: 400))
            image.unlockFocus()
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            let scale = CGFloat(bitmap.pixelsWide) / split.bounds.width
            func isBackground(at y: CGFloat) throws -> Bool {
                let color = try #require(bitmap.colorAt(x: Int(300.5 * scale), y: Int(y * scale))?
                    .usingColorSpace(.deviceRGB))
                let background = try #require(bitmap.colorAt(x: Int(298 * scale), y: Int(y * scale))?
                    .usingColorSpace(.deviceRGB))
                return abs(color.redComponent - background.redComponent) < 0.001
                    && abs(color.greenComponent - background.greenComponent) < 0.001
                    && abs(color.blueComponent - background.blueComponent) < 0.001
            }

            #expect(try !isBackground(at: split.safeAreaRect.midY))
            if top > 0 { #expect(try isBackground(at: top / 2)) }
            if bottom > 0 { #expect(try isBackground(at: split.bounds.height - bottom / 2)) }
        }
    }
}
