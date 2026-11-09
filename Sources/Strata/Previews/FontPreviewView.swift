import AppKit
import CoreGraphics
import CoreText
import Foundation
import StrataModel
import StrataSupport

nonisolated package struct FontSpecimenFace: Sendable {
    package let descriptor: Handoff<CTFontDescriptor>
    package let title: String
    package let displayTitle: String
    package let summary: [String]
    package let note: String?
}

nonisolated package struct FontSpecimenPayload: Sendable {
    package let faces: [FontSpecimenFace]
}

package final class FontPreviewView: PreviewView {
    private let scrollView = NSScrollView()
    private let canvasView = FontSpecimenCanvasView()
    private let facePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let headerBar = NSStackView()
    private var faces: [FontSpecimenFace] = []

    package init(url: URL) {
        super.init(frame: .zero)
        configure()
        load({ try await Self.loadFaces(url) }) { [weak self] payload in
            self?.show(payload)
        }
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        facePicker.controlSize = .small
        facePicker.font = .systemFont(ofSize: 12)
        facePicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        facePicker.target = self
        facePicker.action = #selector(faceSelected(_:))
        headerBar.orientation = .horizontal
        headerBar.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        headerBar.addArrangedSubview(facePicker)
        headerBar.addArrangedSubview(NSView())
        headerBar.isHidden = true
        headerBar.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        canvasView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = canvasView

        let stack = NSStackView(views: [headerBar, scrollView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate(stack.fillingConstraints(in: contentView) + [
            headerBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            canvasView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])
    }

    private func show(_ payload: FontSpecimenPayload) {
        guard !payload.faces.isEmpty else {
            if let fallback { fallback() } else { showMessage(symbol: "eye.slash", String(localized: "No Preview Available")) }
            return
        }
        faces = payload.faces
        facePicker.removeAllItems()
        for face in faces {
            facePicker.addItem(withTitle: face.title)
        }
        headerBar.isHidden = faces.count <= 1
        selectFace(at: 0)
    }

    @objc private func faceSelected(_ sender: NSPopUpButton) {
        selectFace(at: sender.indexOfSelectedItem)
    }

    private func selectFace(at index: Int) {
        guard faces.indices.contains(index) else { return }
        let face = faces[index]
        canvasView.configure(descriptor: face.descriptor.value, title: face.displayTitle)
        footer.show(face.summary, note: face.note)
    }

    @concurrent private static func loadFaces(_ url: URL) async throws -> FontSpecimenPayload {
        try Task.checkCancellation()
        let (data, truncated) = try TextFile.readPrefix(url, limit: FontMetadata.byteLimit)
        guard !truncated, data.count >= 12 else {
            throw PreviewError.unsupported
        }
        let parsed = FontMetadata.read(data)
        guard !parsed.isEmpty else {
            throw PreviewError.unsupported
        }
        try Task.checkCancellation()
        let descriptors = (CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor]) ?? []
        guard !descriptors.isEmpty else {
            throw PreviewError.unsupported
        }

        var byPostScript: [String: FontMetadata.Face] = [:]
        for meta in parsed {
            if let ps = meta.postScriptName, !ps.isEmpty, byPostScript[ps] == nil {
                byPostScript[ps] = meta
            }
        }

        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        var result: [FontSpecimenFace] = []
        for (index, descriptor) in descriptors.prefix(16).enumerated() {
            try Task.checkCancellation()
            let psName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
            let ctDisplayName = CTFontDescriptorCopyAttribute(descriptor, kCTFontDisplayNameAttribute) as? String
            let ctFamily = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
            let ctStyle = CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String
            let matched = psName.flatMap { byPostScript[$0] }
                ?? (descriptors.count == parsed.count && parsed.indices.contains(index) ? parsed[index] : nil)

            let family = matched?.family ?? ctFamily ?? fallbackTitle
            let style = matched?.style ?? ctStyle
            let full = matched?.fullName ?? ctDisplayName ?? ([family, style].compactMap { $0 }.joined(separator: " "))
            let displayTitle = full.isEmpty ? fallbackTitle : full

            var summary: [String] = [family]
            if let style, !style.isEmpty { summary.append(style) }
            if let glyphs = matched?.glyphCount, glyphs > 0 {
                summary.append(String(localized: "\(glyphs) glyphs", comment: "plural"))
            }
            if let version = matched?.version { summary.append(version) }

            let pickerTitle = (style?.isEmpty == false ? style : nil) ?? displayTitle
            result.append(FontSpecimenFace(
                descriptor: Handoff(value: descriptor),
                title: pickerTitle,
                displayTitle: displayTitle,
                summary: summary,
                note: matched?.copyright
            ))
        }
        return FontSpecimenPayload(faces: result)
    }
}

private final class FontSpecimenCanvasView: NSView {
    private var descriptor: CTFontDescriptor?
    private var titleText: String = ""
    private var heightConstraint: NSLayoutConstraint?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let hc = heightAnchor.constraint(equalToConstant: 420)
        hc.isActive = true
        heightConstraint = hc
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(descriptor: CTFontDescriptor, title: String) {
        self.descriptor = descriptor
        self.titleText = title
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let requiredHeight = renderOrMeasure(in: nil, width: max(200, bounds.width))
        if abs((heightConstraint?.constant ?? 0) - requiredHeight) > 0.5 {
            heightConstraint?.constant = requiredHeight
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        _ = renderOrMeasure(in: context, width: max(200, bounds.width))
    }

    private func renderOrMeasure(in context: CGContext?, width: CGFloat) -> CGFloat {
        guard let descriptor else { return 200 }
        let insetX: CGFloat = 16
        let maxWidth = max(120, width - insetX * 2)
        var y: CGFloat = 16

        let textColor = NSColor.labelColor.cgColor
        let secondaryColor = NSColor.secondaryLabelColor.cgColor
        let labelFont = CTFontCreateUIFontForLanguage(.system, 11, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 11, nil)

        // 1. Header title (24 pt)
        let headerFont = CTFontCreateWithFontDescriptor(descriptor, 24, nil)
        y = drawGlyphWrappedLine(titleText, font: headerFont, color: textColor, x: insetX, y: y, maxWidth: maxWidth, in: context)
        y += 12

        // 2. Character sets (16 pt)
        let sampleFont = CTFontCreateWithFontDescriptor(descriptor, 16, nil)
        let sets = [
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
            "abcdefghijklmnopqrstuvwxyz",
            "0123456789 !@#$%^&*()_+-=[]{};':\",./<>?",
        ]
        for line in sets {
            y = drawGlyphWrappedLine(line, font: sampleFont, color: textColor, x: insetX, y: y, maxWidth: maxWidth, in: context)
            y += 4
        }
        y += 10

        // 3. Waterfall pangrams
        let pangram = "The quick brown fox jumps over the lazy dog."
        let sizes: [CGFloat] = [14, 18, 24, 36]
        for size in sizes {
            y = drawGlyphWrappedLine("\(Int(size)) pt", font: labelFont, color: secondaryColor, x: insetX, y: y, maxWidth: maxWidth, in: context)
            y += 2
            let sizeFont = CTFontCreateWithFontDescriptor(descriptor, size, nil)
            y = drawGlyphWrappedLine(pangram, font: sizeFont, color: textColor, x: insetX, y: y, maxWidth: maxWidth, in: context)
            y += 10
        }

        return y + 12
    }

    private func drawGlyphWrappedLine(
        _ string: String,
        font: CTFont,
        color: CGColor,
        x: CGFloat,
        y: CGFloat,
        maxWidth: CGFloat,
        in context: CGContext?
    ) -> CGFloat {
        let chars = Array(string.utf16)
        guard !chars.isEmpty else { return y }
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count)
        var advances = [CGSize](repeating: .zero, count: chars.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, chars.count)

        let rawAscent = CTFontGetAscent(font)
        let rawDescent = CTFontGetDescent(font)
        let rawLeading = CTFontGetLeading(font)
        let ascent = rawAscent.isFinite ? min(max(10, rawAscent), 200) : 16
        let descent = rawDescent.isFinite ? min(max(3, rawDescent), 100) : 5
        let leading = rawLeading.isFinite ? min(max(2, rawLeading), 80) : 3
        let lineHeight = ceil(ascent + descent + leading)

        var cursorX: CGFloat = 0
        var baselineY = y + ceil(ascent)
        var lineGlyphs: [CGGlyph] = []
        var linePositions: [CGPoint] = []

        func flushLine() {
            guard !lineGlyphs.isEmpty else { return }
            if let context {
                context.saveGState()
                context.setFillColor(color)
                context.translateBy(x: 0, y: baselineY)
                context.scaleBy(x: 1, y: -1)
                context.textMatrix = .identity
                CTFontDrawGlyphs(font, lineGlyphs, linePositions, lineGlyphs.count, context)
                context.restoreGState()
            }
            lineGlyphs.removeAll(keepingCapacity: true)
            linePositions.removeAll(keepingCapacity: true)
        }

        let fallbackAdvance = min(max(4, CTFontGetSize(font) * 0.45), 100)
        for i in 0..<chars.count {
            let g = glyphs[i]
            let rawAdv = advances[i].width
            let adv = (g != 0 && rawAdv.isFinite) ? min(max(2, rawAdv), 500) : fallbackAdvance
            if cursorX > 0, cursorX + adv > maxWidth {
                flushLine()
                cursorX = 0
                baselineY += lineHeight
            }
            if g != 0 {
                lineGlyphs.append(g)
                linePositions.append(CGPoint(x: x + cursorX, y: 0))
            }
            cursorX += adv
        }
        flushLine()
        return baselineY + ceil(descent + leading)
    }
}
