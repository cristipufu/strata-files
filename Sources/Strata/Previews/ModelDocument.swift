import Foundation
import StrataSupport

nonisolated package struct ModelDocument: Sendable {
    package enum Format: Sendable {
        case stl, threeMF
        package var label: String { self == .stl ? "STL" : "3MF" }
        var parser: String { self == .stl ? "stl" : "three-mf" }
    }
    nonisolated package struct Settings: Encodable, Sendable {
        package let background: [Double]
        package let color: [Double]
        package let foreground: [Double]
        package let triangles: String
        package let bounds: String
        package let reset: String
        package let help: String
        package let large: String
        package let unavailable: String
        package var format = "STL"
    }
    package static let byteLimit = 16 << 20
    private static let reads = WorkAllowance(limit: 2)
    package let encoded: String
    package let script: String

    @concurrent package func page(settings: Settings) async throws -> PreviewWebPage.Document {
        let arguments = try JSONEncoder().encode(settings)
        guard let arguments = String(data: arguments, encoding: .utf8),
              let origin = URL(string: "strata-html://\(UUID().uuidString.lowercased())/model.html") else { throw PreviewError.unsupported }
        try Task.checkCancellation()
        // Deliver large input as bytes through the existing resource session, never as a main-thread script string.
        let script = script + "\n{ const options = " + arguments + ";" + """
        try {
            const input = document.getElementById('mesh');
            if (!input) throw new Error('input');
            options.data = input.textContent;
            input.remove();
            StrataModel.start(options);
        } catch (error) {
            StrataModel.status = 'failed';
            StrataModel.failure = String(error.message).slice(0, 120);
            document.body.textContent = options.unavailable;
        }}
        """
        let html = Data((Self.html + "<div id=\"mesh\" hidden>" + encoded + "</div>").utf8)
        return PreviewWebPage.Document(url: origin, read: { requested in
            guard requested == origin else { throw URLError(.noPermissionsToReadFile) }
            return HTMLPreviewResource(data: html, mime: "text/html; charset=utf-8")
        }, limits: .init(requests: 1, bytes: html.count), trustedScript: script)
    }

    @concurrent package static func open(_ url: URL, format: Format = .stl) async throws -> Self {
        let result = await reads.run { () -> Result<Data, Error> in
            do {
                let data = switch format {
                case .stl: try await readSTL(url)
                case .threeMF: try await ThreeMFPackage.read(url)
                }
                return .success(data)
            } catch { return .failure(error) }
        }
        guard let result else { throw CancellationError() }
        let data = try result.get()
        guard !data.isEmpty else { throw PreviewError.empty }
        let script = try bundledScript("mesh") + "\n" + bundledScript(format.parser) + "\n" + bundledScript("renderer")
        try Task.checkCancellation()
        return Self(encoded: data.base64EncodedString(), script: script)
    }

    @concurrent private static func readSTL(_ url: URL) async throws -> Data {
        let (data, truncated) = try (await OwnThread.run { Result { try TextFile.readPrefix(url, limit: byteLimit) } }).get()
        guard !truncated else { throw PreviewError.message(String(localized: "This model is too large to preview.")) }
        return data
    }

    package static func bundledScript(_ name: String) throws -> String {
        let bundle = try ResourceBundle.named("Strata_StrataPreviews", in: .main, linkedTo: Bundle(for: ModelPreviewView.self))
        guard let url = bundle.url(forResource: name, withExtension: "js", subdirectory: "Models") else { throw PreviewError.unsupported }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static let html = HTMLPreviewDocument.head + """
    <style>
    body { margin: 0; font: 12px -apple-system, sans-serif; display: flex; flex-direction: column; height: 100vh; }
    canvas { display: block; width: 100%; flex: 1; min-height: 0; touch-action: none; outline-offset: -2px; }
    header { display: flex; align-items: center; gap: 8px; padding: 8px; }
    output { flex: 1; } aside { padding: 0 8px 8px; } p { margin: auto; padding: 24px; }
    button { font: inherit; } </style>
    <canvas tabindex="0"></canvas><header><output></output><button></button></header><aside></aside>
    """
}
