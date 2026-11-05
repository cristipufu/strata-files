import AppKit
import CNativeReaders
import StrataSupport
import WebKit

/// One isolated, offline rendering request at a time, retired on cancellation or a WebKit failure.
@MainActor final class OfflineImageRenderer: NSObject, WKNavigationDelegate {
    typealias TimeLimit = @Sendable () async -> Void
    typealias WebViewFactory = @MainActor (WKWebViewConfiguration) -> WKWebView
    nonisolated static let outputByteLimit = 6_000_000
    private let webView: WKWebView
    private let document: String
    private let drawing: String
    private let timeLimit: TimeLimit
    private var ready = false
    private var closed = false
    private var revision = 0
    private var arguments: [String: Any] = [:]
    private var pending: CheckedContinuation<String, Error>?
    private var deadline: Task<Void, Never>?

    init(script: String, document: String, drawing: String, rules: WKContentRuleList,
         timeLimit: @escaping TimeLimit = PreviewWebPage.usualTimeLimit,
         makeWebView: WebViewFactory = { WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: $0) }) {
        self.document = document; self.drawing = drawing; self.timeLimit = timeLimit
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(rules)
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true, in: .defaultClient))
        webView = makeWebView(configuration)
        super.init()
        webView.navigationDelegate = self
    }

    isolated deinit { deadline?.cancel() }

    func render(arguments: [String: Any]) async throws -> String {
        guard !closed, pending == nil else { throw PreviewError.unsupported }
        revision &+= 1
        let revision = revision
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.arguments = arguments; pending = continuation
                let timeLimit = timeLimit
                deadline = Task { [weak self] in
                    await timeLimit()
                    if !Task.isCancelled { self?.close() }
                }
                if ready { draw() } else { webView.loadHTMLString(document, baseURL: nil) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.revision == revision else { return }
                close()
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true; revision &+= 1
        finish(.failure(CancellationError()))
        webView.stopLoading(); webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
        webView.loadHTMLString("", baseURL: nil)
    }

    private func finish(_ result: Result<String, Error>) {
        deadline?.cancel(); deadline = nil
        let continuation = pending
        pending = nil; arguments = [:]
        continuation?.resume(with: result)
    }

    private func draw() {
        let revision = revision
        webView.callAsyncJavaScript(drawing, arguments: arguments, in: nil, in: .defaultClient) { [weak self] result in
            guard let self, !closed, self.revision == revision, pending != nil else { return }
            guard case .success(let value) = result, let value = value as? String, value.utf8.count <= Self.outputByteLimit else {
                finish(.failure(PreviewError.unsupported)); return
            }
            finish(.success(value))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed, pending != nil else { return }
        ready = true; draw()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { close() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { close() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { close() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        !closed && !ready && navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel
    }

    @concurrent static func decodePNG(_ encoded: String) async throws -> Handoff<NSImage> {
        try Task.checkCancellation()
        let prefix = "data:image/png;base64,"
        guard encoded.utf8.count <= outputByteLimit, encoded.hasPrefix(prefix),
              let data = Data(base64Encoded: String(encoded.dropFirst(prefix.count))),
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw PreviewError.unsupported }
        let reader = try STImageReader.open(data, byteLimit: UInt(outputByteLimit), pixelLimit: 4_000_000, frameLimit: 1)
        let bitmap = try reader.thumbnail(maximumSide: 2000)
        try Task.checkCancellation()
        return Handoff(value: NSImage(cgImage: bitmap.image, size: NSSize(width: bitmap.image.width, height: bitmap.image.height)))
    }
}
