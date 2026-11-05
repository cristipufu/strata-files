import AppKit
import WebKit
import StrataSupport

private final class PreviewBundleMarker {}

@MainActor package final class MermaidRenderer {
    nonisolated package static let textLimit = 50_000
    nonisolated package static let diagramLimit = 12
    private let renderer: OfflineImageRenderer

    package init(script: String, rules: WKContentRuleList) {
        renderer = OfflineImageRenderer(script: script, document: Self.document, drawing: Self.drawing, rules: rules)
    }

    @concurrent package static func script() async throws -> String {
        let bundle = try ResourceBundle.named("Strata_StrataPreviews", in: .main, linkedTo: Bundle(for: PreviewBundleMarker.self))
        guard let url = bundle.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Mermaid") else {
            throw PreviewError.unsupported
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    package func render(_ source: String, dark: Bool) async throws -> NSImage {
        guard source.utf8.count <= Self.textLimit else { throw PreviewError.unsupported }
        let encoded = try await renderer.render(arguments: ["source": source, "dark": dark])
        try Task.checkCancellation()
        return try await OfflineImageRenderer.decodePNG(encoded).value
    }

    package func close() { renderer.close() }

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
