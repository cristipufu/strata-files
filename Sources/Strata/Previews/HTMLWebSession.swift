import AppKit
import WebKit
import StrataModel
import StrataSupport
import CPreviewWeb

/// One WebKit lifetime. Both resource delivery and navigation are refused after closure.
@MainActor package final class HTMLWebSession: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKUIDelegate {
    package enum Navigation: Equatable { case document, anchor, external, refuse }
    package typealias Reader = @Sendable (URL) async throws -> HTMLPreviewResource
    package typealias StreamReader = @Sendable (URL) async throws -> WebPreviewStream
    /// What one document's WebKit lifetime may ask for and be given in all.
    nonisolated package struct Limits: Sendable {
        package var requests: Int
        package var bytes: Int
        package init(requests: Int = HTMLPreviewDocument.requestLimit,
                     bytes: Int = 3 * TextFile.limit + HTMLPreviewDocument.assetLimit) {
            self.requests = requests
            self.bytes = bytes
        }
    }
    private let documentURL: URL
    /// Let go of once the session closes, and what it holds with it, such as a file.
    private var content: WebPreviewContent?
    private let openLink: (URL) -> Void
    private var requests: [ObjectIdentifier: WebResourceRequest] = [:]
    package var pendingTasks: [Task<Void, Never>] { requests.values.compactMap(\.work) }
    private var remainingRequests: Int
    private var remainingBytes: Int
    private var initial = true
    private var closed = false
    package var onFailure: (() -> Void)?
    /// When WebKit starts showing the document, before what it asks for besides has come.
    package var onCommit: (() -> Void)?
    private static var rules: Task<WKContentRuleList, Error>?

    private final class WebResourceRequest {
        let native: STWebResourceTask
        var work: Task<Void, Never>?
        var remainingBytes = 0
        init(_ task: any WKURLSchemeTask) { native = STWebResourceTask(task: task) }
        func stop() {
            native.stop()
            let previous = work
            work = nil
            previous?.cancel()
        }
    }

    package convenience init(url: URL, read: @escaping Reader, limits: Limits = Limits(), openLink: @escaping (URL) -> Void) {
        self.init(url: url, content: .buffered(read), limits: limits, openLink: openLink)
    }

    package convenience init(url: URL, stream: @escaping StreamReader, limits: Limits, openLink: @escaping (URL) -> Void) {
        self.init(url: url, content: .streamed(stream), limits: limits, openLink: openLink)
    }

    package init(url: URL, content: WebPreviewContent, limits: Limits = Limits(), openLink: @escaping (URL) -> Void) {
        documentURL = url; self.content = content; self.openLink = openLink
        remainingRequests = limits.requests; remainingBytes = limits.bytes
        super.init()
    }

    /// A link a click may open in the browser: to a web server, naming no account.
    nonisolated package static func isWebLink(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false && url.user == nil
            && url.password == nil
    }

    isolated deinit { close() }

    package static func contentRules() async throws -> WKContentRuleList {
        if let rules { return try await rules.value }
        let task = Task { @MainActor in
            let caches = SecureStorage.Context.shared.caches
            guard let store = WKContentRuleListStore(url: caches) else { throw PreviewError.unsupported }
            // Start with a closed network boundary, then permit only the private scheme handled below.
            let json = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^strata-html://"},"action":{"type":"ignore-previous-rules"}}]"#
            guard let list = try await store.compileContentRuleList(forIdentifier: "StrataOfflineHTML.v1", encodedContentRuleList: json) else {
                throw PreviewError.unsupported
            }
            return list
        }
        rules = task
        do { return try await task.value }
        catch { rules = nil; throw error }
    }

    package func configuration(rules: WKContentRuleList, trustedScript: String? = nil) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.add(rules)
        // Bundled rendering code runs in its own world; scripts in the document remain disabled.
        if let trustedScript {
            configuration.userContentController.addUserScript(WKUserScript(source: trustedScript,
                injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        }
        configuration.setURLSchemeHandler(self, forURLScheme: HTMLPreviewDocument.scheme)
        return configuration
    }

    package func close() {
        guard !closed else { return }
        closed = true
        let pending = requests.values
        requests = [:]
        pending.forEach { $0.stop() }
        onFailure = nil; onCommit = nil
        content = nil
    }

    package func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        guard requests[key] == nil else { return }
        let request = WebResourceRequest(urlSchemeTask)
        guard !closed, let content, let url = urlSchemeTask.request.url, urlSchemeTask.request.httpMethod == "GET"
        else { fail(request, error: URLError(.cancelled)); return }
        guard remainingRequests > 0 else { fail(request, error: URLError(.resourceUnavailable)); return }
        remainingRequests -= 1
        requests[key] = request
        request.work = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let resource = try await content.resource(url)
                guard let self, !Task.isCancelled, isActive(request, key: key) else { return }
                try await deliver(resource, url: url, to: request, key: key)
            } catch {
                self?.fail(request, key: key, error: error)
            }
        }
    }

    package func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        requests.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.stop()
    }

    private func isActive(_ request: WebResourceRequest, key: ObjectIdentifier) -> Bool {
        !closed && requests[key] === request
    }

    private func deliver(_ resource: WebPreviewContent.Resource, url: URL, to request: WebResourceRequest, key: ObjectIdentifier) async throws {
        guard !Task.isCancelled, isActive(request, key: key) else { return }
        guard resource.byteCount >= 0, resource.byteCount <= remainingBytes else { throw URLError(.dataLengthExceedsMaximum) }
        remainingBytes -= resource.byteCount
        request.remainingBytes = resource.byteCount
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": resource.mime, "Content-Length": String(resource.byteCount),
            "Content-Security-Policy": HTMLPreviewDocument.policy, "X-DNS-Prefetch-Control": "off",
            "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store",
        ]) else { throw URLError(.badServerResponse) }
        guard request.native.receive(response) else { retire(request, key: key); return }
        switch resource {
        case .buffered(let value):
            guard receive(value.data, request: request, key: key) else { return }
        case .streamed(let stream):
            try await stream.produce { [weak self] data in
                self?.receive(data, request: request, key: key) == true
            }
        }
        guard isActive(request, key: key) else { return }
        guard request.remainingBytes == 0 else { throw URLError(.cannotDecodeContentData) }
        requests.removeValue(forKey: key)
        request.work = nil
        if !request.native.finish(), request.native.failure != nil { onFailure?() }
    }

    private func receive(_ data: Data, request: WebResourceRequest, key: ObjectIdentifier) -> Bool {
        guard isActive(request, key: key) else { return false }
        guard data.count <= request.remainingBytes else {
            fail(request, key: key, error: URLError(.dataLengthExceedsMaximum))
            return false
        }
        request.remainingBytes -= data.count
        guard request.native.receive(data) else { retire(request, key: key); return false }
        return isActive(request, key: key)
    }

    private func fail(_ request: WebResourceRequest, key: ObjectIdentifier, error: Error) {
        guard isActive(request, key: key) else { return }
        requests.removeValue(forKey: key)
        request.work = nil
        fail(request, error: error)
    }

    private func fail(_ request: WebResourceRequest, error: Error) {
        request.native.fail(error as NSError)
        if !closed, request.native.failure != nil { onFailure?() }
    }

    private func retire(_ request: WebResourceRequest, key: ObjectIdentifier) {
        guard isActive(request, key: key) else { return }
        let failed = request.native.failure != nil
        requests.removeValue(forKey: key)
        request.stop()
        if failed { onFailure?() }
    }

    /// Only the first document load and clicked same-document anchors navigate inside this preview.
    package static func navigation(_ url: URL?, document: URL, method: String?, mainFrame: Bool, link: Bool, initial: Bool) -> Navigation {
        guard let url, method == "GET" else { return .refuse }
        if link, isWebLink(url) { return .external }
        guard mainFrame, var target = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var source = URLComponents(url: document, resolvingAgainstBaseURL: false) else { return .refuse }
        let fragment = target.fragment
        target.fragment = nil; source.fragment = nil
        guard target == source else { return .refuse }
        if link, fragment != nil { return .anchor }
        return initial && !link && fragment == nil ? .document : .refuse
    }

    package func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                         decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard !closed, !navigationAction.shouldPerformDownload else { decisionHandler(.cancel); return }
        let decision = Self.navigation(navigationAction.request.url, document: documentURL, method: navigationAction.request.httpMethod,
                                       mainFrame: navigationAction.targetFrame?.isMainFrame == true,
                                       link: navigationAction.navigationType == .linkActivated, initial: initial)
        switch decision {
        case .document: initial = false; decisionHandler(.allow)
        case .anchor: decisionHandler(.allow)
        case .external:
            decisionHandler(.cancel)
            if let url = navigationAction.request.url { openLink(url) }
        case .refuse: decisionHandler(.cancel)
        }
    }

    package func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                         decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(!closed && navigationResponse.isForMainFrame && navigationResponse.canShowMIMEType
                        && navigationResponse.response.url == documentURL ? .allow : .cancel)
    }

    package func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { if !closed { onCommit?() } }
    package func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if !closed { onFailure?() } }
    package func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if !closed { onFailure?() } }
    package func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if !closed { onFailure?() } }
    package func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                         for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    package func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                         completionHandler: @escaping @MainActor ([URL]?) -> Void) { completionHandler(nil) }
    package func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                         type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}
