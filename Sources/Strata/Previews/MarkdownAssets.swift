import AppKit

enum MarkdownAsset {
    case diagram(String)
    case equation(MarkdownMath.Equation)

    var isBlock: Bool {
        switch self { case .diagram: true; case .equation(let equation): equation.display }
    }
    var source: String {
        switch self { case .diagram(let source): source; case .equation(let equation): equation.source }
    }
    struct Placeholder {
        let id: String
        let range: NSRange
        let asset: MarkdownAsset
        let pointSize: CGFloat
        let color: [Double]
    }
    struct Image {
        let placeholder: Placeholder
        let image: NSImage
        let descent: CGFloat
    }

    static func placeholders(in storage: NSAttributedString) -> [Placeholder] {
        let whole = NSRange(location: 0, length: storage.length)
        var result: [Placeholder] = []
        func add(_ asset: MarkdownAsset, id: String, range: NSRange) {
            var range = range
            if asset.isBlock, storage.attribute(.attachment, at: range.location, effectiveRange: nil) != nil,
               NSMaxRange(range) < storage.length,
               (storage.string as NSString).substring(with: NSRange(location: NSMaxRange(range), length: 1)) == "\n" {
                range.length += 1
            }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let pointSize = asset.isBlock ? 13 : font?.pointSize ?? 13
            let color = storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
            let rgb = color?.usingColorSpace(.sRGB)
            let components: [Double]
            if let rgb { components = [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)] }
            else { components = [0, 0, 0] }
            result.append(Placeholder(id: id, range: range, asset: asset, pointSize: pointSize, color: components))
        }
        storage.enumerateAttribute(MarkdownRenderer.assetID, in: whole) { value, range, _ in
            guard let id = value as? String else { return }
            if let source = storage.attribute(MarkdownRenderer.mermaidSource, at: range.location, effectiveRange: nil) as? String {
                add(.diagram(source), id: id, range: range)
            } else if let equation = MarkdownMath.Equation(attribute: storage.attribute(MarkdownMath.sourceKey, at: range.location, effectiveRange: nil)) {
                add(.equation(equation), id: id, range: range)
            }
        }
        return result.sorted { $0.range.location > $1.range.location }
    }
}

/// One document request owns its renderers and its retained bitmap allowance.
@MainActor final class MarkdownAssetRenderers {
    private let mathTimeLimit: OfflineImageRenderer.TimeLimit
    private var diagrams: MermaidRenderer?
    private var math: MathRenderer?
    private var pixels = MathRenderer.pixelBudget

    init(mathTimeLimit: @escaping OfflineImageRenderer.TimeLimit) { self.mathTimeLimit = mathTimeLimit }

    func render(_ placeholder: MarkdownAsset.Placeholder, dark: Bool) async throws -> MarkdownAsset.Image {
        let image: NSImage
        var descent: CGFloat = 0
        switch placeholder.asset {
        case .diagram(let source):
            if diagrams == nil {
                let script = try await MermaidRenderer.script(), rules = try await HTMLWebSession.contentRules()
                try Task.checkCancellation()
                diagrams = MermaidRenderer(script: script, rules: rules)
            }
            guard let diagrams else { throw PreviewError.unsupported }
            image = try await diagrams.render(source, dark: dark)
            image.size = NSSize(width: image.size.width / 2, height: image.size.height / 2)
        case .equation(let equation):
            guard pixels > 0 else { throw PreviewError.unsupported }
            if math == nil {
                let script = try await MathRenderer.script(), rules = try await HTMLWebSession.contentRules()
                try Task.checkCancellation()
                math = MathRenderer(script: script, rules: rules, timeLimit: mathTimeLimit)
            }
            guard let math else { throw PreviewError.unsupported }
            let result = try await math.render(equation.source, display: equation.display, pointSize: placeholder.pointSize, color: placeholder.color)
            guard result.pixels <= pixels else { throw PreviewError.unsupported }
            pixels -= result.pixels; image = result.image; descent = result.descent
        }
        try Task.checkCancellation()
        return MarkdownAsset.Image(placeholder: placeholder, image: image, descent: descent)
    }

    func close() { diagrams?.close(); math?.close() }
}

nonisolated final class MathTextAttachment: NSTextAttachment {
    private let naturalWidth: CGFloat
    private let descent: CGFloat

    init?(image: NSImage, descent: CGFloat) {
        let size = image.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              descent.isFinite, descent >= 0, descent <= size.height else { return nil }
        naturalWidth = size.width; self.descent = descent
        super.init(data: nil, ofType: nil)
        self.image = image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    override var bounds: NSRect {
        get { super.bounds }
        set {
            var fitted = newValue
            fitted.origin.y = -descent * fitted.width / naturalWidth
            super.bounds = fitted
        }
    }
}
