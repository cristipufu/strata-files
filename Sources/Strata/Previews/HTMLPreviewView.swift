import AppKit
import WebKit
import StrataTheme
import StrataModel

/// Static HTML with the existing source reader one click away. Document colors stay with the document.
package final class HTMLPreviewView: PreviewView {
    package let modeControl = NSSegmentedControl(labels: [String(localized: "Preview"), String(localized: "Source")], trackingMode: .selectOne, target: nil, action: nil)
    private let browserButton = NSButton(title: String(localized: "Open in Browser"), target: nil, action: nil)
    private let host = NSView()
    private let url: URL
    private let selected: ChosenFile?
    private let spinner = NSProgressIndicator()
    private let openFile: (URL) -> Void
    private let openLink: (URL) -> Void
    private var source: CodePreviewView?
    private var document: HTMLPreviewDocument?
    private var session: HTMLWebSession?
    package private(set) var webView: WKWebView?
    package private(set) var renderTask: Task<Void, Never>?
    package private(set) var rendered = false
    private var timeout: Task<Void, Never>?
    private let timeLimit: @Sendable () async -> Void
    private var revision = 0
    private var stopped = false
    private weak var observedWindow: NSWindow?

    /// `timeLimit` ends when WebKit has had long enough to render the page: its source is shown instead.
    package init(url: URL, openFile: ((URL) -> Void)? = nil, openLink: ((URL) -> Void)? = nil,
                 timeLimit: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(8)) }) {
        self.url = url
        self.timeLimit = timeLimit
        selected = try? ChosenFile(url)
        self.openFile = openFile ?? Self.openInBrowser
        self.openLink = openLink ?? { NSWorkspace.shared.open($0) }
        super.init(frame: .zero)
        ThemeStyle.bind(self, to: .preview)
        ThemeStyle.bind(host, to: .preview)
        let bar = NSStackView(views: [modeControl, NSView(), browserButton])
        bar.orientation = .horizontal
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        bar.spacing = 8
        ThemeStyle.bind(bar, to: .preview)
        modeControl.controlSize = .small
        modeControl.selectedSegment = 0
        modeControl.target = self; modeControl.action = #selector(modeChanged(_:))
        browserButton.controlSize = .small
        browserButton.bezelStyle = .rounded
        browserButton.target = self; browserButton.action = #selector(openBrowser(_:))
        let separator = NSBox(); separator.boxType = .separator
        for view in [bar, separator, host] { view.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(view) }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bar.topAnchor.constraint(equalTo: contentView.topAnchor),
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separator.topAnchor.constraint(equalTo: bar.bottomAnchor),
            host.topAnchor.constraint(equalTo: separator.bottomAnchor), host.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), host.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: host.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: host.centerYAnchor)])
        footer.show(["HTML"], note: String(localized: "Scripts and online content are blocked."))
        prepare()
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }
    isolated deinit { stop(); NotificationCenter.default.removeObserver(self) }

    package override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window, window !== newWindow {
            stop()
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
            observedWindow = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }
    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window !== observedWindow else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        observedWindow = window
        NotificationCenter.default.addObserver(self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: window)
        if stopped { stopped = false; prepare() }
    }
    @objc private func windowClosed() { stop() }

    private func attach(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor), view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor), view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    private func prepare() {
        guard !stopped, webView == nil, renderTask == nil, modeControl.selectedSegment == 0 else { return }
        spinner.startAnimation(nil)
        let revision = revision, url = url, existing = document, selected = selected
        renderTask = Task { [weak self] in
            do {
                let document: HTMLPreviewDocument
                if let existing { document = existing }
                else {
                    guard let selected else { throw POSIXError(.ESTALE) }
                    document = try await HTMLPreviewDocument.open(url, chosen: selected)
                }
                let rules = try await HTMLWebSession.contentRules()
                try Task.checkCancellation()
                try await document.verify()
                guard let self, !stopped, self.revision == revision else { return }
                self.document = document
                let session = HTMLWebSession(url: document.url, read: { try await document.read($0) }, openLink: openLink)
                let web = WKWebView(frame: .zero, configuration: session.configuration(rules: rules))
                web.navigationDelegate = session; web.uiDelegate = session
                web.allowsBackForwardNavigationGestures = false
                web.allowsLinkPreview = false
                self.session = session; webView = web
                session.onFinish = { [weak self] in self?.finished() }
                session.onFailure = { [weak self] in self?.showSource(unavailable: true) }
                attach(web)
                host.addSubview(spinner, positioned: .above, relativeTo: web)
                web.load(URLRequest(url: document.url, cachePolicy: .reloadIgnoringLocalCacheData))
                renderTask = nil
                let timeLimit = timeLimit
                timeout = Task { [weak self] in
                    await timeLimit()
                    if !Task.isCancelled { self?.showSource(unavailable: true) }
                }
            } catch {
                guard let self, !Task.isCancelled, self.revision == revision else { return }
                renderTask = nil
                showSource(unavailable: true)
            }
        }
    }

    private func finished() {
        rendered = true
        spinner.stopAnimation(nil)
        timeout?.cancel(); timeout = nil
    }

    @objc package func modeChanged(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 1 { showSource(unavailable: false) }
        else {
            source?.isHidden = true
            webView?.isHidden = false
            if !rendered { prepare() }
            footer.show(["HTML"], note: String(localized: "Scripts and online content are blocked."))
        }
    }

    private func showSource(unavailable: Bool) {
        guard !stopped else { return }
        modeControl.selectedSegment = 1
        if !rendered { clearWeb() }
        webView?.isHidden = true
        if source == nil {
            let selected = selected
            let view = CodePreviewView(source: {
                guard let selected else { throw POSIXError(.ESTALE) }
                return try await HTMLPreviewDocument.source(selected)
            }, language: Languages.html)
            source = view; attach(view)
        }
        source?.isHidden = false
        footer.show(["HTML"], note: unavailable ? String(localized: "Preview unavailable. Showing source.") : nil)
        if !unavailable { footer.collapse(true) }
    }

    private func clearWeb() {
        spinner.stopAnimation(nil)
        revision += 1
        renderTask?.cancel(); renderTask = nil
        timeout?.cancel(); timeout = nil
        session?.close(); session = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        webView?.removeFromSuperview(); webView = nil
        rendered = false
    }

    package func stop() {
        stopped = true
        clearWeb()
    }

    @objc package func openBrowser(_ sender: Any?) {
        guard !stopped, let selected,
              (try? selected.withParent { _, _, info in info.st_mode & S_IFMT == S_IFREG }) == true else { return }
        openFile(url)
    }

    private static func openInBrowser(_ url: URL) {
        guard let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.invalid")!) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
    }
}
