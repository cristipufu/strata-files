import AppKit
import CPreviewText

/// Produces only owned HTML elements. Document text and attributes are always escaped;
/// Foundation's inline parser stays behind the native exception boundary.
nonisolated final class MarkdownHTMLRenderer {
    private let baseURL: URL
    private var budget = MarkdownBudget()
    private var diagrams = 0
    private var equations = 0
    private var images = 0
    private var headings: [String: Int] = [:]
    private let escape = HTMLPreviewMarkup.escaped

    init(baseURL: URL) { self.baseURL = baseURL }

    func render(_ source: String) throws -> String {
        let body: String
        do { body = try blocks(MarkdownParser.parse(source)) }
        catch is MarkdownLimitExceeded { body = "<pre class=\"source\"><code>" + escape(source) + "</code></pre>" }
        try Task.checkCancellation()
        return "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><style>"
            + MarkdownWebStyle.css + "</style><main class=\"markdown-body\">" + body + "</main>"
    }

    private func blocks(_ blocks: [MarkdownBlock], tight: Bool = false) throws -> String {
        try blocks.map { block in
            try Task.checkCancellation()
            try budget.reserveNode()
            switch block {
            case .heading(let level, let text):
                let content = try inline(text)
                let id = try headingID(text)
                return "<h\(level) id=\"\(escape(id))\">\(content)</h\(level)>"
            case .paragraph(let text):
                let content = try inline(text)
                return tight ? content : "<p>\(content)</p>"
            case .code(let language, let text): return try code(text, language: language)
            case .quote(let children): return "<blockquote>\(try self.blocks(children))</blockquote>"
            case .list(let ordered, let start, let items, let loose):
                return try list(ordered: ordered, start: start, items: items, loose: loose)
            case .rule: return "<hr>"
            case .table(let header, let alignments, let rows):
                return try table(header: header, alignments: alignments, rows: rows)
            case .html(let text):
                // Raw HTML never enters the DOM. Preserve the existing reader's safe textual interpretation.
                return try self.blocks(MarkdownRenderer.htmlBlocks(text))
            }
        }.joined(separator: "\n")
    }

    private func list(ordered: Bool, start: Int, items: [MarkdownListItem], loose: Bool) throws -> String {
        let tag = ordered ? "ol" : "ul"
        let attribute = ordered ? " start=\"\(max(0, min(start, 999_999_999)))\"" : ""
        let content = try items.map { item in
            let checkbox = item.checked.map { "<input type=\"checkbox\" disabled\($0 ? " checked" : "")> " } ?? ""
            let style = item.checked == nil ? "" : " class=\"task-list-item\""
            let body: String
            if item.checked != nil, loose, case .paragraph(let first)? = item.blocks.first {
                body = "<p>\(checkbox)\(try inline(first))</p>" + (try blocks(Array(item.blocks.dropFirst())))
            } else { body = checkbox + (try blocks(item.blocks, tight: !loose)) }
            return "<li\(style)>\(body)</li>"
        }.joined()
        return "<\(tag)\(attribute)>\(content)</\(tag)>"
    }

    private func table(header: [String], alignments: [NSTextAlignment], rows: [[String]]) throws -> String {
        func row(_ cells: [String], tag: String) throws -> String {
            let content = try cells.enumerated().map { index, text in
                let alignment = alignments.indices.contains(index) ? alignments[index] : .left
                let value = alignment == .center ? "center" : alignment == .right ? "right" : "left"
                return "<\(tag) align=\"\(value)\">\(try inline(text))</\(tag)>"
            }.joined()
            return "<tr>\(content)</tr>"
        }
        return "<div class=\"table-scroll\"><table><thead>\(try row(header, tag: "th"))</thead><tbody>"
            + (try rows.map { try row($0, tag: "td") }.joined()) + "</tbody></table></div>"
    }

    private func code(_ text: String, language: String) throws -> String {
        try budget.reserveText(text)
        let language = language.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
        if language == "mermaid", diagrams < MermaidRenderer.diagramLimit, text.utf8.count <= MermaidRenderer.textLimit {
            diagrams += 1
            return "<div class=\"diagram\" data-diagram><pre><code>\(escape(text))</code></pre></div>"
        }
        if ["math", "latex"].contains(language), equations < MathRenderer.equationLimit, text.utf8.count <= MathRenderer.textLimit {
            equations += 1
            return "<div class=\"equation\" data-math=\"block\">\(escape(text))</div>"
        }
        guard text.utf16.count <= MarkdownLimits.formattingInputUnits, let language = Languages.detect(fenceInfo: language) else {
            return "<pre><code>\(escape(text))</code></pre>"
        }
        let tokens = SyntaxHighlighter.tokens(in: text, lexer: language.lexer)
        try budget.reserveRuns(tokens.count)
        let source = text as NSString
        var output = "", offset = 0
        for token in tokens.sorted(by: { $0.location < $1.location }) {
            guard token.location >= offset, token.length > 0, token.location <= source.length,
                  token.length <= source.length - token.location else { continue }
            output += escape(source.substring(with: NSRange(location: offset, length: token.location - offset)))
            output += "<span class=\"syntax-\(token.kind)\">"
                + escape(source.substring(with: NSRange(location: token.location, length: token.length))) + "</span>"
            offset = token.location + token.length
        }
        output += escape(source.substring(from: offset))
        return "<pre><code>\(output)</code></pre>"
    }

    private func inline(_ text: String) throws -> String {
        guard text.utf16.count <= MarkdownLimits.formattingInputUnits else { throw MarkdownLimitExceeded() }
        try budget.reserveText(text)
        let math = MarkdownMath.prepare(text, limit: MathRenderer.equationLimit - equations)
        equations += math.equations.count
        let parsed = try STPreviewTextBuilder.inlineMarkdown(math.markdown, baseURL: baseURL)
        let source = parsed.string as NSString
        var output = "", offset = 0
        while offset < parsed.length {
            try Task.checkCancellation()
            try budget.reserveRuns(1)
            var range = NSRange()
            let attributes = parsed.attributes(at: offset, effectiveRange: &range)
            offset = NSMaxRange(range)
            let intent = InlinePresentationIntent(rawValue: (attributes[.inlinePresentationIntent] as? NSNumber)?.uintValue ?? 0)
            let text = source.substring(with: range)
            if intent.contains(.inlineHTML) {
                if text.lowercased().hasPrefix("<br") { output += "<br>" }
                continue
            }
            if intent.contains(.lineBreak) { output += "<br>"; continue }
            var content = escape(text.replacingOccurrences(of: "\n", with: " "))
            for (token, equation) in math.equations where content.contains(token) {
                content = content.replacingOccurrences(of: token, with: "<span data-math=\"\(equation.display ? "block" : "inline")\">\(escape(equation.source))</span>")
            }
            if let url = attributes[.imageURL] as? URL { content = image(url.absoluteURL, alt: text) }
            if intent.contains(.code) { content = "<code>\(content)</code>" }
            if intent.contains(.stronglyEmphasized) { content = "<strong>\(content)</strong>" }
            if intent.contains(.emphasized) { content = "<em>\(content)</em>" }
            if intent.contains(.strikethrough) { content = "<del>\(content)</del>" }
            if let url = attributes[.link] as? URL, let href = linkDestination(url) {
                content = "<a href=\"\(escape(href))\">\(content)</a>"
            }
            output += content
        }
        return output
    }

    private func image(_ url: URL, alt: String) -> String {
        guard images < 12, url.isFileURL else { return escape(alt) }
        let base = baseURL.standardizedFileURL.path + "/", path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else { return escape(alt) }
        let relative = String(path.dropFirst(base.count))
        let encoded = relative.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? "" }.joined(separator: "/")
        guard !encoded.isEmpty else { return escape(alt) }
        images += 1
        return "<img src=\"\(escape(encoded))\" alt=\"\(escape(alt))\">"
    }

    private func linkDestination(_ url: URL) -> String? {
        if url.relativeString.hasPrefix("#") { return url.relativeString }
        let resolved = url.absoluteURL
        guard ["http", "https", "mailto", "file"].contains(resolved.scheme?.lowercased() ?? ""),
              resolved.user == nil, resolved.password == nil else { return nil }
        return resolved.absoluteString
    }

    private func headingID(_ text: String) throws -> String {
        let plain = try STPreviewTextBuilder.inlineMarkdown(text, baseURL: baseURL).string
        let id = plain.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" || $0 == "_"
        }.map(String.init).joined().replacingOccurrences(of: " ", with: "-")
        let count = headings[id, default: 0]
        headings[id] = count + 1
        return count == 0 ? id : "\(id)-\(count)"
    }
}
