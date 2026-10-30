import AppKit
import WebKit
import StrataTheme

/// A preview that reads a file, then shows it in offline WebKit. It stops when it leaves its window or the window
/// closes, and starts again where it was in the next window.
package class WebPreviewView: PreviewView {
    package let page: PreviewWebPage
    package var webView: WKWebView? { page.webView }
    package private(set) var stopped = false

    package init(page: PreviewWebPage) {
        self.page = page
        super.init(frame: .zero)
        ThemeStyle.bind(self, to: .preview)
        ThemeStyle.bind(contentView, to: .preview)
    }
    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    /// Whether the file has been read; until it has, the view reads it again when it comes back to a window.
    package var isOpen: Bool { false }
    package func open() {}
    /// Called again each time the view comes back to a window with its file read.
    package func showPage() {}

    package override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil, newWindow !== window { stop() }
        super.viewWillMove(toWindow: newWindow)
    }
    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(stop), name: NSWindow.willCloseNotification,
                                               object: window)
        if stopped {
            stopped = false
            if isOpen { showPage() } else { reopen() }
        }
    }

    private func reopen() {
        contentView.subviews.forEach { $0.isHidden = false }
        open()
    }

    @objc package func stop() { stopped = true; cancelLoad(); page.clear() }
}
