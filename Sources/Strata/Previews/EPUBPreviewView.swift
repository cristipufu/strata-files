import AppKit
import WebKit
import StrataTheme

/// Owns one book and one WebKit chapter at a time; native navigation and resource loading have separate owners.
package final class EPUBPreviewView: PreviewView {
    package typealias Loader = @Sendable (PreviewArchiveSource) async throws -> EPUBBook
    package let header: EPUBPreviewHeader
    package var chapters: NSPopUpButton { header.chapters }
    package var chapterIndex: Int { header.selectedChapter }
    private let host = NSView()
    private let spinner = NSProgressIndicator()
    private let problem = NSTextField(labelWithString: String(localized: "No Preview Available"))
    package private(set) var book: EPUBBook?
    package private(set) var webView: WKWebView?
    package private(set) var chapterTask: Task<Void, Never>?
    private var session: HTMLWebSession?
    private var timeout: Task<Void, Never>?
    private var revision = 0
    private var stopped = false
    private let source: PreviewArchiveSource?
    private let loader: Loader

    package init(url: URL, loader: @escaping Loader = { try await EPUBBook.open($0) }) {
        source = try? PreviewArchiveSource(url)
        self.loader = loader
        header = EPUBPreviewHeader(name: url.deletingPathExtension().lastPathComponent)
        super.init(frame: .zero)
        ThemeStyle.bind(self, to: .preview)
        ThemeStyle.bind(contentView, to: .preview)
        ThemeStyle.bind(host, to: .preview)
        problem.font = .systemFont(ofSize: 12)
        problem.isHidden = true
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        for item in [problem, spinner] {
            item.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(item)
            NSLayoutConstraint.activate([item.centerXAnchor.constraint(equalTo: host.centerXAnchor), item.centerYAnchor.constraint(equalTo: host.centerYAnchor)])
        }
        let separator = NSBox(); separator.boxType = .separator
        for item in [header, separator, host] { item.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(item) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor), separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            host.topAnchor.constraint(equalTo: separator.bottomAnchor), host.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), host.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        header.onSelect = { [weak self] _ in self?.chapterChanged() }
        openBook()
    }
    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }
    isolated deinit { stop(); NotificationCenter.default.removeObserver(self) }

    private func openBook() {
        contentView.subviews.forEach { $0.isHidden = false }
        let source = source, loader = loader
        load({
            guard let source else { throw PreviewError.unsupported }
            return try await loader(source)
        }, apply: { [weak self] book in
            guard let self, !stopped else { return }
            self.book = book
            header.show(book)
            footer.show(["EPUB"], note: String(localized: "Scripts and online content are blocked."))
            chapterChanged()
        })
    }
    package override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil, newWindow !== window { stop() }
        super.viewWillMove(toWindow: newWindow)
    }
    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(stop), name: NSWindow.willCloseNotification, object: window)
        if stopped {
            stopped = false
            if book == nil { openBook() } else { chapterChanged() }
        }
    }

    @objc package func back() {
        guard !stopped, chapterIndex > 0 else { return }
        header.select(chapterIndex - 1); chapterChanged()
    }
    @objc package func forward() {
        guard !stopped, let book, chapterIndex + 1 < book.chapters.count else { return }
        header.select(chapterIndex + 1); chapterChanged()
    }
    @objc package func chapterChanged() {
        clearChapter()
        problem.isHidden = true
        guard !stopped, let book else { return }
        spinner.startAnimation(nil)
        let index = chapterIndex, revision = revision
        chapterTask = Task { [weak self] in
            do {
                let document = try EPUBChapterDocument(book: book, chapter: index)
                _ = try await document.read(document.url)
                let rules = try await HTMLWebSession.contentRules()
                try Task.checkCancellation()
                guard let self, !stopped, self.revision == revision else { return }
                let session = HTMLWebSession(url: document.url, read: { try await document.read($0) }, openLink: { NSWorkspace.shared.open($0) })
                let web = WKWebView(frame: .zero, configuration: session.configuration(rules: rules))
                web.navigationDelegate = session; web.uiDelegate = session
                web.allowsLinkPreview = false
                web.allowsBackForwardNavigationGestures = false
                session.onFailure = { [weak self] in self?.chapterFailed() }
                session.onFinish = { [weak self] in self?.spinner.stopAnimation(nil); self?.timeout?.cancel(); self?.timeout = nil }
                self.session = session; webView = web
                web.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(web)
                NSLayoutConstraint.activate([web.leadingAnchor.constraint(equalTo: host.leadingAnchor), web.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                    web.topAnchor.constraint(equalTo: host.topAnchor), web.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
                host.addSubview(spinner, positioned: .above, relativeTo: web)
                web.load(URLRequest(url: document.url))
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    if !Task.isCancelled { self?.chapterFailed() }
                }
                chapterTask = nil
            } catch {
                guard let self, !Task.isCancelled, !stopped, self.revision == revision else { return }
                chapterTask = nil
                chapterFailed()
            }
        }
    }
    private func clearChapter() {
        revision += 1; chapterTask?.cancel(); chapterTask = nil
        timeout?.cancel(); timeout = nil
        spinner.stopAnimation(nil)
        session?.close(); session = nil
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        webView?.removeFromSuperview(); webView = nil
    }
    private func chapterFailed() { clearChapter(); problem.isHidden = false }
    @objc package func stop() { stopped = true; cancelLoad(); clearChapter() }
}
