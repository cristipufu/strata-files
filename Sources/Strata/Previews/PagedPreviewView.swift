import AppKit
import WebKit
import StrataTheme

/// A preview that pages through a file one offline WebKit document at a time, under a header for its contents. It
/// stops when it leaves its window or the window closes, and starts again where it was in the next window.
package class PagedPreviewView: PreviewView {
    package let header: PreviewContentsHeader
    package let page: PreviewWebPage
    package var webView: WKWebView? { page.webView }
    package private(set) var stopped = false

    package init(name: String, timeLimit: @escaping PreviewWebPage.TimeLimit) {
        header = PreviewContentsHeader(name: name)
        page = PreviewWebPage(timeLimit: timeLimit)
        super.init(frame: .zero)
        ThemeStyle.bind(self, to: .preview)
        ThemeStyle.bind(contentView, to: .preview)
        let separator = NSBox(); separator.boxType = .separator
        for item in [header, separator, page] {
            item.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(item)
            NSLayoutConstraint.activate([item.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                                         item.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)])
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            page.topAnchor.constraint(equalTo: separator.bottomAnchor),
            page.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        header.onSelect = { [weak self] _ in self?.entryChanged() }
    }
    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    /// Whether the file has been read; until it has, the view reads it again when it comes back to a window.
    package var isOpen: Bool { false }
    /// Reads the file, then shows its contents in the header and its chosen entry.
    package func open() {}
    /// Nil while the file isn't read.
    package func document(_ index: Int) -> (@Sendable () async throws -> PreviewWebPage.Document)? { nil }
    /// `error` is nil when WebKit couldn't show the document, in time or at all.
    package func failure(_ error: Error?) -> String { String(localized: "No Preview Available") }

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
            if isOpen { entryChanged() } else { reopen() }
        }
    }

    private func reopen() {
        contentView.subviews.forEach { $0.isHidden = false }
        open()
    }

    @objc package func back() {
        guard !stopped, header.selected > 0 else { return }
        header.select(header.selected - 1); entryChanged()
    }
    @objc package func forward() {
        guard !stopped, header.selected + 1 < header.contents.numberOfItems else { return }
        header.select(header.selected + 1); entryChanged()
    }
    @objc package func entryChanged() {
        guard !stopped, let prepare = document(header.selected) else {
            page.clear()
            return
        }
        page.show(prepare, failure: { [weak self] in self?.failure($0) ?? "" })
    }
    @objc package func stop() { stopped = true; cancelLoad(); page.clear() }
}
