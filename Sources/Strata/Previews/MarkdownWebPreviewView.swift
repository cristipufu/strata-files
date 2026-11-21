import AppKit
import WebKit
import StrataSupport
import StrataModel

/// Markdown's document layout belongs to WebKit; this view owns loading, search and failure recovery.
package final class MarkdownWebPreviewView: WebPreviewView, PreviewDocumentSearch {
    private let url: URL
    private let preferences: any PreviewTextSettings
    private let assetTimeLimit: PreviewWebPage.TimeLimit
    private var document: MarkdownWebDocument?
    private var sourceView: CodePreviewView?
    private var sourceFallback = false
    private var assetTimeout: Task<Void, Never>?
    private var revision = 0
    private var query = ""
    private var searchPending = false
    package private(set) var isReady = false

    package init(url: URL, preferences: any PreviewTextSettings,
                 timeLimit: @escaping PreviewWebPage.TimeLimit = PreviewWebPage.usualTimeLimit) {
        self.url = url; self.preferences = preferences; assetTimeLimit = timeLimit
        super.init(page: PreviewWebPage(timeLimit: timeLimit, openLink: Self.openLink))
        page.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(page)
        NSLayoutConstraint.activate(page.fillingConstraints(in: contentView))
        open()
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { return nil }

    isolated deinit { assetTimeout?.cancel() }

    package override var isOpen: Bool { document != nil || sourceFallback }

    package override func open() {
        guard !stopped else { return }
        let url = url
        load({ try await MarkdownWebDocument.open(url) }, failed: { [weak self] _ in self?.showSource() }) { [weak self] document in
            guard let self, !stopped else { return }
            self.document = document
            footer.show(["Markdown", String(localized: "\(document.wordCount) words", comment: "plural")])
            showPage()
        }
    }

    package override func showPage() {
        guard !stopped else { return }
        if sourceFallback { showSource(); return }
        guard let document else { return }
        retireAssets()
        searchPending = !query.isEmpty
        page.show({
            try await document.resources.verify()
            return document.page()
        }, loaded: { [weak self] in self?.finishAssets(refresh: false) }, failed: { [weak self] _ in self?.showSource() })
    }

    private func finishAssets(refresh: Bool) {
        guard !stopped, let web = webView else { return }
        retireAssets()
        let revision = revision, timeLimit = assetTimeLimit
        assetTimeout = Task { [weak self] in
            await timeLimit()
            guard !Task.isCancelled, let self, self.revision == revision else { return }
            showSource()
        }
        let script = refresh ? "await globalThis.strataRenderMarkdown?.(); return true;"
            : "await globalThis.strataMarkdownReady; return true;"
        web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { [weak self, weak web] result in
            guard let self, !stopped, self.revision == revision, let web, web === webView else { return }
            assetTimeout?.cancel(); assetTimeout = nil
            switch result {
            case .success:
                isReady = true
                if searchPending { find(query) }
            case .failure: showSource()
            }
        }
    }

    private func retireAssets() {
        revision &+= 1; isReady = false
        assetTimeout?.cancel(); assetTimeout = nil
    }

    private func showSource() {
        guard !stopped, sourceView == nil else { return }
        sourceFallback = true
        retireAssets(); page.clear(); page.isHidden = true
        let snapshot = document?.resources.sourceText, url = url
        let view = CodePreviewView(source: {
            try await Self.readSource(snapshot: snapshot, url: url)
        }, language: Language(name: "Markdown", lexer: .plain), preferences: preferences)
        sourceView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)
        NSLayoutConstraint.activate(view.fillingConstraints(in: contentView))
        view.find(query)
        footer.show(["Markdown"], note: String(localized: "Preview unavailable. Showing source."))
    }

    @concurrent private static func readSource(snapshot: String?, url: URL) async throws -> TextFile {
        if let snapshot { return TextFile(text: TextFile.normalizeNewlines(snapshot), isTruncated: false) }
        return try TextFile.read(url)
    }

    package func find(_ query: String) {
        self.query = query
        searchPending = true
        if let sourceView { sourceView.find(query); searchPending = false; return }
        guard isReady, let webView else { return }
        searchPending = false
        let configuration = WKFindConfiguration()
        configuration.wraps = true
        webView.find(query, configuration: configuration) { _ in }
    }

    package func findNext(backwards: Bool) {
        if let sourceView { sourceView.findNext(backwards: backwards); return }
        guard isReady, !query.isEmpty, let webView else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards; configuration.wraps = true
        webView.find(query, configuration: configuration) { _ in }
    }

    package override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if isReady { finishAssets(refresh: true) }
    }

    package override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { stop() }
    }

    @objc package override func stop() {
        retireAssets()
        sourceView?.stop()
        sourceView?.removeFromSuperview(); sourceView = nil
        super.stop()
    }

    /// Native clicks only. A local link reveals its item, never executes a file.
    private static func openLink(_ url: URL) {
        if url.isFileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
    }
}
