import AppKit
import StrataSupport
import WebKit

private final class MathBundleMarker {}

@MainActor package final class MathRenderer {
    static let usualTimeLimit: OfflineImageRenderer.TimeLimit = { try? await Task.sleep(for: .seconds(2)) }
    nonisolated static let textLimit = 8192
    nonisolated static let equationLimit = 64
    nonisolated static let pixelBudget = 8_000_000
    struct Image {
        let image: NSImage
        let descent: CGFloat
        let pixels: Int
    }
    nonisolated private struct Response: Decodable, Sendable {
        let png: String
        let width: Double
        let height: Double
        let descent: Double
    }
    private let renderer: OfflineImageRenderer

    init(script: String, rules: WKContentRuleList,
         timeLimit: @escaping OfflineImageRenderer.TimeLimit = usualTimeLimit) {
        renderer = OfflineImageRenderer(script: script, document: Self.document, drawing: Self.drawing, rules: rules,
            timeLimit: timeLimit)
    }

    @concurrent package static func script() async throws -> String {
        let bundle = try ResourceBundle.named("Strata_StrataPreviews", in: .main, linkedTo: Bundle(for: MathBundleMarker.self))
        guard let url = bundle.url(forResource: "katex.min", withExtension: "js", subdirectory: "Math") else {
            throw PreviewError.unsupported
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func render(_ source: String, display: Bool, pointSize: CGFloat, color: [Double]) async throws -> Image {
        guard source.utf8.count <= Self.textLimit, pointSize.isFinite, (1...64).contains(pointSize),
              color.count == 3, color.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw PreviewError.unsupported }
        let result = try await renderer.render(arguments: ["source": source, "display": display, "pointSize": Double(pointSize), "color": color])
        try Task.checkCancellation()
        let response = try await Self.response(result)
        let image = try await OfflineImageRenderer.decodePNG(response.png).value
        try Task.checkCancellation()
        let pixels = Int(image.size.width) * Int(image.size.height)
        image.size = NSSize(width: response.width, height: response.height)
        return Image(image: image, descent: response.descent, pixels: pixels)
    }

    @concurrent private static func response(_ value: String) async throws -> Response {
        guard value.utf8.count <= OfflineImageRenderer.outputByteLimit else { throw PreviewError.unsupported }
        let response = try JSONDecoder().decode(Response.self, from: Data(value.utf8))
        guard response.width.isFinite, response.height.isFinite, response.descent.isFinite,
              (1...2000).contains(response.width), (1...2000).contains(response.height),
              (0...response.height).contains(response.descent) else { throw PreviewError.unsupported }
        return response
    }

    func close() { renderer.close() }

    private static let document = """
    <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
    <style>body { margin:0; background:transparent; line-height:normal; } #math {display:inline-block;}
    #baseline {display:inline-block;width:0;height:0;vertical-align:baseline;}</style><span id="math"></span><span id="baseline"></span>
    """
    private static let drawing = #"""
    const holder = document.querySelector('#math');
    try {
        document.body.style.fontSize = pointSize + 'px';
        const foreground = 'rgb(' + color.map(value => Math.round(value * 255)).join(',') + ')';
        document.body.style.color = foreground;
        holder.innerHTML = katex.renderToString(source, {output:'mathml', displayMode:display,
            trust: () => { throw new Error('Unsupported TeX command'); },
            throwOnError:true, maxSize:20, maxExpand:1000, strict:'error', macros:Object.create(null)});
        if (holder.innerHTML.length > 500000) throw new Error('Equation too large');
        const box = holder.getBoundingClientRect(), baseline = document.querySelector('#baseline').getBoundingClientRect().top;
        const width = Math.ceil(box.width) + 4, height = Math.ceil(box.height) + 4;
        const descent = Math.max(0, Math.min(height, box.bottom - baseline + 2));
        if (!(width > 0 && height > 0 && width <= 2000 && height <= 2000 && Number.isFinite(width + height + descent))) throw new Error('Invalid size');
        const scale = Math.min(2, 2000 / width, 2000 / height);
        const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="' + width + '" height="' + height + '">'
            + '<foreignObject width="100%" height="100%"><div xmlns="http://www.w3.org/1999/xhtml" style="padding:2px;font-size:'
            + pointSize + 'px;color:' + foreground + '">' + holder.innerHTML + '</div></foreignObject></svg>';
        const image = new Image();
        await new Promise((resolve, fail) => { image.onload = resolve; image.onerror = fail;
            image.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg); });
        const canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.ceil(width * scale)); canvas.height = Math.max(1, Math.ceil(height * scale));
        const context = canvas.getContext('2d');
        context.scale(scale, scale); context.drawImage(image, 0, 0);
        const png = canvas.toDataURL('image/png');
        if (png.length > 5900000) throw new Error('Equation too large');
        return JSON.stringify({png, width, height, descent});
    } finally { holder.replaceChildren(); }
    """#
}
