import AppKit
import Quartz

/// Owns one native Quick Look view per window lifetime. Quick Look closes itself with the window and cannot accept
/// another item afterward; delayed selection updates and rich-preview fallbacks must not restart that closed view.
package final class QuickLookPreviewView: NSView {
    private let style: QLPreviewViewStyle
    private var preview: QLPreviewView?
    private var shownURL: URL?
    private weak var observedWindow: NSWindow?
    package private(set) var isClosed = false

    package init(frame: NSRect, style: QLPreviewViewStyle) {
        self.style = style
        super.init(frame: frame)
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { return nil }

    package override func viewWillMove(toWindow newWindow: NSWindow?) {
        if observedWindow !== newWindow {
            close()
            preview?.removeFromSuperview()
            preview = nil
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
            observedWindow = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, observedWindow !== window else { return }
        observedWindow = window
        isClosed = false
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: window)
        if let shownURL { show(shownURL) }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        // The native view owns its automatic close. Observe the window rather than overriding QLPreviewView.close:
        // its automatic close is not required to call that override.
        isClosed = true
    }

    package func close() {
        guard !isClosed else { return }
        isClosed = true
        preview?.close()
    }

    package var previewItem: (any QLPreviewItem)? { isClosed ? nil : preview?.previewItem }

    @discardableResult
    package func show(_ url: URL) -> Bool {
        guard !isClosed, window != nil else { return false }
        if preview == nil {
            guard let native = QLPreviewView(frame: bounds, style: style) else { return false }
            native.autoresizingMask = [.width, .height]
            native.shouldCloseWithWindow = true
            native.autostarts = false
            addSubview(native)
            preview = native
        }
        shownURL = url
        preview?.previewItem = url as NSURL
        return true
    }

    package func clear() {
        shownURL = nil
        guard !isClosed else { return }
        preview?.previewItem = nil
    }

    package func refreshPreviewItem() {
        guard !isClosed, window != nil else { return }
        preview?.refreshPreviewItem()
    }
}
