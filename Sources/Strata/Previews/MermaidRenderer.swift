import AppKit
import WebKit
import StrataSupport

private final class PreviewBundleMarker {}

/// Only the bundled library executes here. Document text crosses the JavaScript boundary as an argument.
@MainActor package final class MermaidRenderer: NSObject, WKNavigationDelegate {
    nonisolated package static let textLimit = 50_000
    nonisolated package static let diagramLimit = 12
    private let webView: WKWebView
    private var ready = false
    private var closed = false
    private var source = ""
    private var dark = false
    private var pending: CheckedContinuation<Data, Error>?
    private var deadline: Task<Void, Never>?

    package init(script: String, rules: WKContentRuleList) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(rules)
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    isolated deinit { deadline?.cancel() }

    @concurrent package static func script() async throws -> String {
        let bundle = try ResourceBundle.named("Strata_StrataPreviews", in: .main, linkedTo: Bundle(for: PreviewBundleMarker.self))
        guard let url = bundle.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Mermaid") else {
            throw PreviewError.unsupported
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    package func render(_ source: String, dark: Bool) async throws -> NSImage {
        guard !closed, pending == nil, source.utf8.count <= Self.textLimit else { throw PreviewError.unsupported }
        let data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.source = source; self.dark = dark; pending = continuation
                deadline = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { return }
                    self?.close()
                }
                if ready { draw() }
                else {
                    webView.loadHTMLString(Self.document, baseURL: nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.close() }
        }
        try Task.checkCancellation()
        guard let image = NSImage(data: data) else { throw PreviewError.unsupported }
        return image
    }

    package func close() {
        guard !closed else { return }
        closed = true
        finish(.failure(CancellationError()))
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
        webView.loadHTMLString("", baseURL: nil)
    }

    private func finish(_ result: Result<Data, Error>) {
        deadline?.cancel(); deadline = nil
        let continuation = pending
        pending = nil; source = ""
        continuation?.resume(with: result)
    }

    package func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed, pending != nil else { return }
        ready = true
        draw()
    }
    package func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { close() }
    package func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { close() }
    package func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { close() }
    package func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        !closed && !ready && navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel
    }

    private func draw() {
        webView.callAsyncJavaScript(Self.drawing, arguments: ["source": source, "dark": dark], in: nil, in: .page) { [weak self] result in
            guard let self, !closed, pending != nil else { return }
            guard case .success(let value) = result, let encoded = value as? String, encoded.utf8.count <= 6_000_000,
                  let comma = encoded.firstIndex(of: ","), let data = Data(base64Encoded: String(encoded[encoded.index(after: comma)...])) else {
                finish(.failure(PreviewError.unsupported)); return
            }
            finish(.success(data))
        }
    }

    private static let document = """
        <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
        <style>body { margin: 0; font-family: sans-serif; }</style><body></body>
        """
    private static let drawing = #"""
        const config = { startOnLoad: false, securityLevel: 'strict', maxTextSize: 50000, maxEdges: 500,
            suppressErrorRendering: true, theme: dark ? 'dark' : 'default', htmlLabels: false,
            flowchart: { htmlLabels: false }, fontFamily: 'sans-serif' };
        config.secure = [...new Set(['secure', ...Object.keys(config)])];
        mermaid.initialize(config);
        try {
            const result = await mermaid.render('strataDiagram', source);
            if (result.svg.length > 2000000) throw new Error('Diagram too large');
            const holder = document.createElement('div');
            holder.innerHTML = result.svg;
            const svg = holder.querySelector('svg');
            if (!svg) throw new Error('Invalid diagram');
            const box = svg.viewBox.baseVal;
            if (!(box.width > 0 && box.height > 0 && Number.isFinite(box.width + box.height))) throw new Error('Invalid size');
            const scale = Math.min(2, 2000 / box.width, 2000 / box.height);
            const width = Math.max(1, Math.ceil(box.width * scale)), height = Math.max(1, Math.ceil(box.height * scale));
            svg.setAttribute('width', width); svg.setAttribute('height', height);
            svg.style.maxWidth = 'none';
            const image = new Image();
            await new Promise((resolve, fail) => { image.onload = resolve; image.onerror = fail;
                image.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(new XMLSerializer().serializeToString(svg)); });
            const canvas = document.createElement('canvas'); canvas.width = width; canvas.height = height;
            const context = canvas.getContext('2d');
            context.fillStyle = dark ? '#1f2020' : '#ffffff'; context.fillRect(0, 0, width, height);
            context.drawImage(image, 0, 0, width, height);
            const png = canvas.toDataURL('image/png');
            if (png.length > 6000000) throw new Error('Diagram too large');
            return png;
        } finally { document.body.replaceChildren(); }
        """#
}
