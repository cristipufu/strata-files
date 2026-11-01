import AppKit
import ImageIO
import StrataModel
import StrataTheme

/// Turns parsed Markdown blocks into an attributed string for a TextKit 1 text view: text blocks draw code
/// backgrounds, quote bars, heading rules and tables; `AttributedString(markdown:)` handles inline runs.
nonisolated package final class MarkdownRenderer {
    private let baseURL: URL
    private var imageBudget = 12
    private(set) var tables: [MarkdownTable] = []
    private var diagrams = 0
    static let mermaidSource = NSAttributedString.Key("StrataMermaidSource")

    private let bodySize: CGFloat = 13
    private let blockSpacing: CGFloat = 10
    private let listColumn: CGFloat = 20
    private let maxImageSize = NSSize(width: 320, height: 240)

    /// `baseURL` resolves relative links and images (the Markdown file's folder).
    package init(baseURL: URL) {
        self.baseURL = baseURL
    }

    package func render(_ blocks: [MarkdownBlock]) -> NSMutableAttributedString {
        let output = NSMutableAttributedString()
        render(blocks, into: output, context: Context())
        if output.string.hasSuffix("\n") { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }
        return output
    }

    private struct Context {
        var textBlocks: [NSTextBlock] = []
        var indent: CGFloat = 0
        var quoted = false
        var listDepth = 0
    }

    // MARK: - Blocks

    private func render(_ blocks: [MarkdownBlock], into output: NSMutableAttributedString, context: Context) {
        for block in blocks {
            switch block {
            case .heading(let level, let text):
                heading(level: level, text: text, into: output, context: context)
            case .paragraph(let text):
                let style = paragraphStyle(context)
                output.append(inline(text, size: bodySize, color: textColor(context), paragraph: style))
                output.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
            case .code(let language, let text):
                code(text, language: language, into: output, context: context)
            case .quote(let children):
                let start = output.length
                let bar = QuoteBlock()
                bar.setValue(100, type: .percentageValueType, for: .width)
                bar.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
                bar.setWidth(2, type: .absoluteValueType, for: .padding, edge: .minY)
                bar.setWidth(2, type: .absoluteValueType, for: .padding, edge: .maxY)
                bar.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
                bar.setWidth(blockSpacing, type: .absoluteValueType, for: .margin, edge: .maxY)
                var inner = context
                inner.textBlocks.append(bar)
                inner.indent = 0
                inner.quoted = true
                render(children, into: output, context: inner)
                setTrailingSpacing(0, in: output, from: start)
            case .list(let ordered, let start, let items):
                list(ordered: ordered, start: start, items: items, into: output, context: context)
            case .rule:
                let line = NSTextBlock()
                line.setValue(100, type: .percentageValueType, for: .width)
                line.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
                line.setBorderColor(.separatorColor, for: .minY)
                line.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
                line.setWidth(6, type: .absoluteValueType, for: .margin, edge: .minY)
                line.setWidth(blockSpacing + 4, type: .absoluteValueType, for: .margin, edge: .maxY)
                let style = NSMutableParagraphStyle()
                style.textBlocks = context.textBlocks + [line]
                style.minimumLineHeight = 1
                style.maximumLineHeight = 1
                output.append(NSAttributedString(string: "\u{200B}\n", attributes: [
                    .paragraphStyle: style, .font: NSFont.systemFont(ofSize: 1),
                ]))
            case .table(let header, let alignments, let rows):
                table(header: header, alignments: alignments, rows: rows, into: output, context: context)
            case .html(let html):
                render(htmlBlocks(html), into: output, context: context)
            }
        }
    }

    private func heading(level: Int, text: String, into output: NSMutableAttributedString, context: Context) {
        let sizes: [CGFloat] = [21, 17, 15, 13, 12, 12]
        let clamped = min(max(level, 1), 6)
        let size = sizes[clamped - 1]
        let style = paragraphStyle(context, after: clamped <= 2 ? 10 : 6, before: output.length == 0 ? 0 : (clamped <= 2 ? 12 : 8))
        style.lineHeightMultiple = 1.05
        if clamped <= 2 {
            let rule = NSTextBlock()
            rule.setValue(100, type: .percentageValueType, for: .width)
            rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            rule.setBorderColor(.separatorColor, for: .maxY)
            rule.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
            rule.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
            style.textBlocks = context.textBlocks + [rule]
            style.headIndent = 0
            style.firstLineHeadIndent = 0
        }
        let color: NSColor = level == 6 ? .secondaryLabelColor : textColor(context)
        output.append(inline(text, size: size, weight: level <= 2 ? .bold : .semibold, color: color, paragraph: style))
        output.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style, .font: NSFont.systemFont(ofSize: size)]))
    }

    private func code(_ text: String, language: String, into output: NSMutableAttributedString, context: Context) {
        let background = CodeBlockBackground()
        background.setValue(100, type: .percentageValueType, for: .width)
        background.setWidth(9, type: .absoluteValueType, for: .padding)
        background.setWidth(11, type: .absoluteValueType, for: .padding, edge: .minX)
        background.setWidth(11, type: .absoluteValueType, for: .padding, edge: .maxX)
        background.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
        background.setWidth(2, type: .absoluteValueType, for: .margin, edge: .minY)
        background.setWidth(blockSpacing, type: .absoluteValueType, for: .margin, edge: .maxY)
        let size: CGFloat = 11.5
        var attributes = CodeTheme.baseAttributes(size: size)
        let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.textBlocks = context.textBlocks + [background]
        style.minimumLineHeight = 16
        style.maximumLineHeight = 16
        attributes[.paragraphStyle] = style
        let body = text.isEmpty ? " " : text
        let start = output.length
        output.append(NSAttributedString(string: body + "\n", attributes: attributes))
        if language.lowercased() == "mermaid", diagrams < MermaidRenderer.diagramLimit, text.utf8.count <= MermaidRenderer.textLimit {
            diagrams += 1
            output.addAttribute(Self.mermaidSource, value: text, range: NSRange(location: start, length: output.length - start))
        }
        if let language = Languages.detect(fenceInfo: language) {
            CodeTheme.apply(SyntaxHighlighter.tokens(in: body, lexer: language.lexer), to: output, offset: start, size: size)
        }
    }

    private func list(ordered: Bool, start: Int, items: [MarkdownListItem], into output: NSMutableAttributedString, context: Context) {
        let start = max(0, min(start, 999_999_999))
        let listStart = output.length
        let bullets = ["•", "◦", "▪"]
        let markerFont = NSFont.monospacedDigitSystemFont(ofSize: bodySize, weight: .regular)
        let widest = ordered ? ("\(start + items.count - 1)." as NSString).size(withAttributes: [.font: markerFont]).width : 0
        let column = max(listColumn, ceil(widest) + 8)
        for (index, item) in items.enumerated() {
            var inner = context
            inner.indent = context.indent + column
            inner.listDepth += 1
            let style = paragraphStyle(context, after: 4)
            style.headIndent = inner.indent
            style.tabStops = [
                NSTextTab(textAlignment: ordered ? .right : .center, location: context.indent + (ordered ? column - 6 : column / 2 - 2)),
                NSTextTab(textAlignment: .left, location: inner.indent),
            ]
            let line = NSMutableAttributedString(string: "\t", attributes: [.paragraphStyle: style, .font: NSFont.systemFont(ofSize: bodySize)])
            if let checked = item.checked {
                line.append(checkbox(checked, paragraph: style))
            } else {
                let marker = ordered ? "\(start + index)." : bullets[min(context.listDepth, bullets.count - 1)]
                line.append(NSAttributedString(string: marker, attributes: [
                    .font: ordered ? markerFont : NSFont.systemFont(ofSize: bodySize), .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: style,
                ]))
            }
            line.append(NSAttributedString(string: "\t", attributes: [.paragraphStyle: style]))
            var rest = item.blocks
            if case .paragraph(let text)? = rest.first {
                rest.removeFirst()
                line.append(inline(text, size: bodySize, color: textColor(context), paragraph: style))
            }
            line.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
            output.append(line)
            if !rest.isEmpty {
                let nestedStart = output.length
                render(rest, into: output, context: inner)
                setTrailingSpacing(4, in: output, from: nestedStart)
            }
        }
        setTrailingSpacing(context.listDepth == 0 ? blockSpacing : 4, in: output, from: listStart)
    }

    private func table(header: [String], alignments: [NSTextAlignment], rows: [[String]],
                       into output: NSMutableAttributedString, context: Context) {
        guard !header.isEmpty else { return }
        let table = MarkdownTable()
        table.indent = context.indent
        table.preferredWidths = Array(repeating: 28, count: header.count)
        tables.append(table)
        table.numberOfColumns = header.count
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
        table.setWidth(2, type: .absoluteValueType, for: .margin, edge: .minY)
        table.setWidth(blockSpacing, type: .absoluteValueType, for: .margin, edge: .maxY)
        for (rowIndex, row) in ([header] + rows).enumerated() {
            for (column, text) in row.enumerated() where column < header.count {
                let cell = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                table.add(cell)
                cell.setWidth(1, type: .absoluteValueType, for: .border)
                cell.setBorderColor(.separatorColor)
                cell.setWidth(5, type: .absoluteValueType, for: .padding)
                cell.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)
                if rowIndex == 0 { cell.backgroundColor = MarkdownColors.tableHeader }
                let style = NSMutableParagraphStyle()
                style.textBlocks = context.textBlocks + [cell]
                style.alignment = alignments.indices.contains(column) ? alignments[column] : .left
                style.lineHeightMultiple = 1.1
                let size: CGFloat = 12
                let content = inline(text, size: size, weight: rowIndex == 0 ? .semibold : .regular, color: textColor(context), paragraph: style)
                let measurement = NSMutableAttributedString(attributedString: content)
                measurement.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: measurement.length))
                let measured = measurement.size().width
                table.preferredWidths[column] = max(table.preferredWidths[column], ceil(measured) + 18)
                output.append(content)
                output.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style, .font: NSFont.systemFont(ofSize: size)]))
            }
        }
    }

    /// Raw HTML blocks, reduced to what reads well as text: headings stay headings, tags and comments go.
    /// One linear pass over the bytes (regexes here went quadratic on unclosed comments, headings or tags).
    private func htmlBlocks(_ html: String) -> [MarkdownBlock] {
        let bytes = Array(html.utf8)
        let n = bytes.count
        let open = UInt8(ascii: "<"), close = UInt8(ascii: ">")
        // The next ">" at or after the last position asked about; positions only increase, so this is one pass.
        var nextClose = -1
        func closeIndex(from i: Int) -> Int? {
            if nextClose < i { nextClose = bytes[i...].firstIndex(of: close) ?? n }
            return nextClose < n ? nextClose : nil
        }
        func isLetter(_ byte: UInt8) -> Bool { (byte | 0x20) >= UInt8(ascii: "a") && (byte | 0x20) <= UInt8(ascii: "z") }
        func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
        func trimmed(_ text: [UInt8]) -> String {
            String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var text: [UInt8] = []
        var heading: (level: Int, text: [UInt8])?
        var i = 0
        while i < n {
            if bytes[i] == open {
                if i + 3 < n, bytes[i + 1] == UInt8(ascii: "!"), bytes[i + 2] == UInt8(ascii: "-"), bytes[i + 3] == UInt8(ascii: "-") {
                    var j = i + 4
                    while j + 2 < n, !(bytes[j] == UInt8(ascii: "-") && bytes[j + 1] == UInt8(ascii: "-") && bytes[j + 2] == close) { j += 1 }
                    i = j + 2 < n ? j + 3 : n
                    continue
                }
                var j = i + 1
                let closing = j < n && bytes[j] == UInt8(ascii: "/")
                if closing { j += 1 }
                let nameStart = j
                while j < n, isLetter(bytes[j]) || (j > nameStart && isDigit(bytes[j])) { j += 1 }
                if j > nameStart, let end = closeIndex(from: j) {
                    let name = String(decoding: bytes[nameStart..<j], as: UTF8.self).lowercased()
                    if name.count == 2, name.first == "h", let level = Int(name.dropFirst()), (1...6).contains(level) {
                        if !closing, heading == nil {
                            heading = (level, [])
                        } else if closing, let current = heading, current.level == level {
                            let inner = trimmed(current.text)
                            if !inner.isEmpty { return [.heading(level: level, text: inner)] }
                            heading = nil
                        }
                    } else if name == "br" {
                        text.append(contentsOf: Array("  \n".utf8))
                    }
                    i = end + 1
                    continue
                }
            }
            text.append(bytes[i])
            heading?.text.append(bytes[i])
            i += 1
        }
        let lines = String(decoding: text, as: UTF8.self).components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.isEmpty ? [] : [.paragraph(lines.joined(separator: "\n"))]
    }

    // MARK: - Inline

    private func inline(_ markdown: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor,
                        paragraph: NSParagraphStyle) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        let parsed = (try? AttributedString(markdown: markdown, options: options, baseURL: baseURL)) ?? AttributedString(markdown)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var text = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.inlineHTML) {
                guard text.lowercased().hasPrefix("<br") else { continue }
                text = "\u{2028}"
            } else if intent.contains(.lineBreak) {
                text = "\u{2028}"
            } else {
                text = text.replacingOccurrences(of: "\n", with: " ")
            }
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color, .paragraphStyle: paragraph]
            if intent.contains(.code) {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: (size * 0.88).rounded(), weight: weight)
                attributes[.backgroundColor] = MarkdownColors.inlineCode
            } else {
                attributes[.font] = Self.font(size: size, weight: intent.contains(.stronglyEmphasized) ? .bold : weight,
                                              italic: intent.contains(.emphasized))
            }
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            }
            if let link = run.link {
                attributes[.link] = link.relativeString.hasPrefix("#") ? link.relativeString : link.absoluteURL
                // Show where a link really goes; the visible text can say anything.
                attributes[.toolTip] = link.relativeString.hasPrefix("#") ? nil : link.absoluteURL.absoluteString
            }
            if let imageURL = run.imageURL {
                result.append(image(imageURL.absoluteURL, alt: text, attributes: attributes))
                continue
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }

    /// Local images inline (scaled down to fit); remote ones as their alt text, since previews never hit the network.
    private func image(_ url: URL, alt: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let image: NSImage?
        if imageBudget > 0 {
            imageBudget -= 1
            image = localImage(url)
        } else {
            image = nil
        }
        if let image {
            let scale = min(1, maxImageSize.width / image.size.width, maxImageSize.height / image.size.height)
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: 0, width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
            let result = NSMutableAttributedString(attachment: attachment)
            result.addAttributes(attributes, range: NSRange(location: 0, length: result.length))
            return result
        }
        guard !alt.isEmpty else { return NSAttributedString() }
        var quiet = attributes
        if quiet[.link] == nil { quiet[.foregroundColor] = NSColor.secondaryLabelColor }
        return NSAttributedString(string: alt, attributes: quiet)
    }

    /// Read only regular files below the document's folder, without following any links. Decode a thumbnail
    /// after checking the dimensions; neither compressed file size nor display scaling bounds a full decode.
    package func localImage(_ url: URL, pixelLimit: Int = 40_000_000) -> NSImage? {
        guard url.isFileURL else { return nil }
        let base = baseURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return nil }
        let parts = path.dropFirst(base.count + 1).split(separator: "/").map(String.init)
        guard !parts.isEmpty, let root = try? ChosenFile.openDirectory(baseURL.resolvingSymlinksInPath().path) else { return nil }
        var folder = root
        defer { close(folder) }
        for part in parts.dropLast() {
            let next = openat(folder, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return nil }
            close(folder)
            folder = next
        }
        let fd = openat(folder, parts[parts.count - 1], O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        let limit = 8 << 20
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
              let data = try? handle.read(upToCount: limit + 1), data.count <= limit,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= pixelLimit / height,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 640,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
    }

    private func checkbox(_ checked: Bool, paragraph: NSParagraphStyle) -> NSAttributedString {
        let name = checked ? "checkmark.square.fill" : "square"
        let colors: [NSColor] = checked ? [.white, .controlAccentColor] : [.secondaryLabelColor]
        let configuration = NSImage.SymbolConfiguration(pointSize: bodySize, weight: .regular)
            .applying(.init(paletteColors: colors))
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: name, accessibilityDescription: checked
            ? String(localized: "Done", comment: "Accessibility: a checked task-list item in a Markdown preview")
            : String(localized: "To do", comment: "Accessibility: an unchecked task-list item in a Markdown preview"))?
            .withSymbolConfiguration(configuration)
        if let size = attachment.image?.size { attachment.bounds = CGRect(x: 0, y: -2, width: size.width, height: size.height) }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: - Helpers

    private func paragraphStyle(_ context: Context, after: CGFloat? = nil, before: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.textBlocks = context.textBlocks
        style.firstLineHeadIndent = context.indent
        style.headIndent = context.indent
        style.lineHeightMultiple = 1.18
        style.paragraphSpacing = after ?? blockSpacing
        style.paragraphSpacingBefore = before
        return style
    }

    private func textColor(_ context: Context) -> NSColor {
        context.quoted ? .secondaryLabelColor : .labelColor
    }

    /// Sets the space after the last paragraph appended since `start`, so nested blocks don't stack their spacing.
    private func setTrailingSpacing(_ spacing: CGFloat, in output: NSMutableAttributedString, from start: Int) {
        guard output.length > start else { return }
        let last = (output.string as NSString).paragraphRange(for: NSRange(location: output.length - 1, length: 0))
        output.enumerateAttribute(.paragraphStyle, in: last) { value, range, _ in
            guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            style.paragraphSpacing = spacing
            output.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    private static func font(size: CGFloat, weight: NSFont.Weight, italic: Bool) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        guard italic else { return font }
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? font
    }
}

nonisolated package enum MarkdownColors {
    // Stronger with Increase Contrast, so code stands apart from prose.
    package static let inlineCode = NSColor(name: nil) { appearance in
        let alpha: CGFloat = appearance.isHighContrast ? 0.22 : appearance.isDark ? 0.1 : 0.06
        return NSColor(white: appearance.isDark ? 1 : 0, alpha: alpha)
    }
    package static let codeBlock = NSColor(name: nil) { appearance in
        let alpha: CGFloat = appearance.isHighContrast ? 0.15 : appearance.isDark ? 0.06 : 0.04
        return NSColor(white: appearance.isDark ? 1 : 0, alpha: alpha)
    }
    package static let tableHeader = codeBlock
}

/// Rounded background behind a fenced code block.
nonisolated final class CodeBlockBackground: NSTextBlock {
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange,
                                 layoutManager: NSLayoutManager) {
        let rect = contentFrame(frameRect)
        MarkdownColors.codeBlock.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    /// `frameRect` includes the margins; the background covers padding and content only.
    func contentFrame(_ frameRect: NSRect) -> NSRect {
        var rect = frameRect
        rect.origin.x += width(for: .margin, edge: .minX)
        rect.origin.y += width(for: .margin, edge: .minY)
        rect.size.width -= width(for: .margin, edge: .minX) + width(for: .margin, edge: .maxX)
        rect.size.height -= width(for: .margin, edge: .minY) + width(for: .margin, edge: .maxY)
        return rect
    }
}

/// The rounded bar to the left of a block quote.
nonisolated final class QuoteBlock: NSTextBlock {
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange,
                                 layoutManager: NSLayoutManager) {
        let left = frameRect.minX + width(for: .margin, edge: .minX)
        let top = frameRect.minY + width(for: .margin, edge: .minY)
        let bottom = frameRect.maxY - width(for: .margin, edge: .maxY)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: NSRect(x: left, y: top, width: 3, height: bottom - top), xRadius: 1.5, yRadius: 1.5).fill()
    }
}
