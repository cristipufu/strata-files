import AppKit
import WebKit
import StrataTheme

/// One offline WebKit document at a time, for previews that page through a file: showing another, `clear` or a
/// failure ends the one before with its session, its load and its time limit, and a late result never shows.
package final class PreviewWebPage: NSView {
    package typealias TimeLimit = @Sendable () async -> Void
    package static let usualTimeLimit: TimeLimit = { try? await Task.sleep(for: .seconds(8)) }

    nonisolated package struct Document: Sendable {
        package let url: URL
        package let read: HTMLWebSession.Reader
        package let limits: HTMLWebSession.Limits
        package init(url: URL, read: @escaping HTMLWebSession.Reader, limits: HTMLWebSession.Limits = .init()) {
            self.url = url
            self.read = read
            self.limits = limits
        }
    }

    package private(set) var webView: WKWebView?
    package private(set) var task: Task<Void, Never>?
    package let problem = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let timeLimit: TimeLimit
    private let openLink: (URL) -> Void
    private var session: HTMLWebSession?
    private var timeout: Task<Void, Never>?
    /// What the shown document's failures say: nil for WebKit's own, or for its time running out.
    private var describe: ((Error?) -> String)?
    private var revision = 0

    /// `timeLimit` ends when WebKit has had long enough to start showing a document; one it hasn't by then fails.
    package init(timeLimit: @escaping TimeLimit = usualTimeLimit,
                 openLink: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.timeLimit = timeLimit
        self.openLink = openLink
        super.init(frame: .zero)
        ThemeStyle.bind(self, to: .preview)
        problem.font = .systemFont(ofSize: 12)
        problem.alignment = .center
        problem.isHidden = true
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        for item in [problem, spinner] {
            item.translatesAutoresizingMaskIntoConstraints = false; addSubview(item)
            NSLayoutConstraint.activate([item.centerXAnchor.constraint(equalTo: centerXAnchor),
                                         item.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
        problem.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48).isActive = true
    }
    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }
    isolated deinit { clear() }

    /// Shows the document `prepare` makes, or what `failure` says of why it couldn't be: the error that kept it from
    /// being made, or nil when WebKit couldn't show it, in time or at all.
    package func show(_ prepare: @escaping @Sendable () async throws -> Document,
                      failure describe: @escaping (Error?) -> String) {
        clear()
        self.describe = describe
        spinner.startAnimation(nil)
        let revision = revision
        task = Task { [weak self] in
            do {
                let document = try await prepare()
                let rules = try await HTMLWebSession.contentRules()
                try Task.checkCancellation()
                guard let self, self.revision == revision else { return }
                task = nil
                load(document, rules: rules)
            } catch {
                guard let self, !Task.isCancelled, self.revision == revision else { return }
                task = nil
                fail(error)
            }
        }
    }

    private func load(_ document: Document, rules: WKContentRuleList) {
        let session = HTMLWebSession(url: document.url, read: document.read, limits: document.limits,
                                     openLink: openLink)
        let web = WKWebView(frame: .zero, configuration: session.configuration(rules: rules))
        web.navigationDelegate = session; web.uiDelegate = session
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = false
        session.onFailure = { [weak self] in self?.fail(nil) }
        // Once the page shows, pictures still coming never end it.
        session.onCommit = { [weak self] in
            self?.spinner.stopAnimation(nil)
            self?.timeout?.cancel(); self?.timeout = nil
        }
        self.session = session; webView = web
        web.translatesAutoresizingMaskIntoConstraints = false
        addSubview(web, positioned: .below, relativeTo: spinner)
        NSLayoutConstraint.activate([web.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     web.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     web.topAnchor.constraint(equalTo: topAnchor),
                                     web.bottomAnchor.constraint(equalTo: bottomAnchor)])
        web.load(URLRequest(url: document.url))
        let timeLimit = timeLimit
        timeout = Task { [weak self] in
            await timeLimit()
            if !Task.isCancelled { self?.fail(nil) }
        }
    }

    package func clear() {
        revision += 1; task?.cancel(); task = nil
        timeout?.cancel(); timeout = nil
        spinner.stopAnimation(nil)
        problem.isHidden = true
        session?.close(); session = nil
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        webView?.removeFromSuperview(); webView = nil
    }

    private func fail(_ error: Error?) {
        let text = describe?(error) ?? ""
        clear()
        problem.stringValue = text
        problem.isHidden = false
    }
}
