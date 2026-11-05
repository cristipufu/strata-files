import AppKit
import Testing
import WebKit
@testable import StrataPreviews

@MainActor enum ModelPreviewTestSupport {
    static func parser(_ name: String, fixture: String = "") async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let script = try ModelDocument.bundledScript("mesh") + "\n" + ModelDocument.bundledScript(name) + "\n" + fixture
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true, in: .defaultClient))
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.loadHTMLString("<!doctype html><p>Model parser</p>", baseURL: nil)
        try await wait { (try? await javascript(web, "return typeof StrataModel")) == "object" }
        return web
    }

    static func javascript(_ web: WKWebView, _ script: String, arguments: [String: Any] = [:]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value):
                    guard let text = value as? String else { continuation.resume(throwing: PreviewError.unsupported); return }
                    continuation.resume(returning: text)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    static func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(25)
        while await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await condition())
    }
}
