import AppKit

/// Block structure of a Markdown document (CommonMark plus GitHub tables, task lists and front matter).
/// Inline markup is left as source text for `AttributedString(markdown:)`.
nonisolated package indirect enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String, text: String)
    case quote([MarkdownBlock])
    case list(ordered: Bool, start: Int, items: [MarkdownListItem])
    case rule
    case table(header: [String], alignments: [NSTextAlignment], rows: [[String]])
    case html(String)
}

nonisolated package struct MarkdownListItem {
    /// nil for plain items, otherwise whether the task box is checked.
    package var checked: Bool?
    package var blocks: [MarkdownBlock]
}

nonisolated package enum MarkdownParser {
    package static func parse(_ text: String) -> [MarkdownBlock] {
        var lines = text.replacingOccurrences(of: "\t", with: "    ").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        // YAML front matter shows as a code block.
        if lines.first == "---", let end = lines.dropFirst().prefix(100).firstIndex(where: { $0 == "---" || $0 == "..." }) {
            blocks.append(.code(language: "yaml", text: lines[1..<end].joined(separator: "\n")))
            lines.removeSubrange(0...end)
        }
        return blocks + parse(lines: lines)
    }

    /// Each quote or list level recurses; a crafted file with thousands of `>` or list markers would exhaust the stack.
    /// Nesting deeper than any real document uses shows as plain text instead.
    private static let maxDepth = 16
    /// NSTextTable lays out every cell eagerly; a table this big is shown cut off.
    private static let maxTableColumns = 20
    private static let maxTableRows = 200

    package static func parse(lines: [String], depth: Int = 0) -> [MarkdownBlock] {
        guard depth < maxDepth else { return lines.isEmpty ? [] : [.code(language: "", text: lines.joined(separator: "\n"))] }
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let indent = indentation(line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); i += 1; continue }

            if indent >= 4, paragraph.isEmpty {
                blocks.append(indentedCode(lines, from: &i))
                continue
            }
            if let fence = fence(trimmed) {
                flush()
                blocks.append(fencedCode(lines, from: &i, fence: fence, indent: indent))
                continue
            }
            if let (level, text) = atxHeading(trimmed) {
                flush()
                blocks.append(.heading(level: level, text: text))
                i += 1; continue
            }
            if !paragraph.isEmpty, trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" }) {
                blocks.append(.heading(level: trimmed.first == "=" ? 1 : 2, text: paragraph.joined(separator: "\n")))
                paragraph = []
                i += 1; continue
            }
            if isRule(trimmed) {
                flush()
                blocks.append(.rule)
                i += 1; continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                blocks.append(quote(lines, from: &i, depth: depth))
                continue
            }
            if let marker = listMarker(line), paragraph.isEmpty || marker.canInterruptParagraph {
                flush()
                blocks.append(parseList(lines, from: &i, depth: depth))
                continue
            }
            if trimmed.contains("|"), let table = table(lines, from: &i) {
                flush()
                blocks.append(table)
                continue
            }
            if paragraph.isEmpty, isHTMLBlockStart(trimmed) {
                blocks.append(htmlBlock(lines, from: &i))
                continue
            }
            paragraph.append(trimmed + (line.hasSuffix("  ") ? "  " : ""))
            i += 1
        }
        flush()
        return blocks
    }

    // MARK: - Blocks

    /// Lines indented four spaces or more, blank ones between them included, as code.
    private static func indentedCode(_ lines: [String], from i: inout Int) -> MarkdownBlock {
        var code: [String] = []
        while i < lines.count, indentation(lines[i]) >= 4 || isBlank(lines[i]) {
            code.append(String(lines[i].dropFirst(min(4, lines[i].count))))
            i += 1
        }
        while code.last?.isEmpty == true { code.removeLast() }
        return .code(language: "", text: code.joined(separator: "\n"))
    }

    /// From the opening fence (at line `i`) to the closing one, or the end.
    private static func fencedCode(_ lines: [String], from i: inout Int, fence: (marker: String, info: String),
                                   indent: Int) -> MarkdownBlock {
        var code: [String] = []
        i += 1
        while i < lines.count {
            let candidate = lines[i].trimmingCharacters(in: .whitespaces)
            if candidate.hasPrefix(fence.marker), candidate.allSatisfy({ $0 == fence.marker.first }) { i += 1; break }
            code.append(String(lines[i].dropFirst(min(indent, indentation(lines[i])))))
            i += 1
        }
        return .code(language: fence.info, text: code.joined(separator: "\n"))
    }

    /// `>` lines, and the lines that continue their paragraph, parsed as blocks of their own one level down.
    private static func quote(_ lines: [String], from i: inout Int, depth: Int) -> MarkdownBlock {
        var quoted: [String] = []
        while i < lines.count {
            let current = lines[i].trimmingCharacters(in: .whitespaces)
            if current.hasPrefix(">") {
                var content = current.dropFirst()
                if content.first == " " { content = content.dropFirst() }
                quoted.append(String(content))
            } else if !current.isEmpty, !startsBlock(lines[i]), quoted.last?.isEmpty == false {
                quoted.append(current)
            } else {
                break
            }
            i += 1
        }
        return .quote(parse(lines: quoted, depth: depth + 1))
    }

    /// A GitHub table: a header row, then its alignment row, then rows until a blank or pipeless line. nil, with `i`
    /// left alone, when line `i` doesn't start one.
    private static func table(_ lines: [String], from i: inout Int) -> MarkdownBlock? {
        guard i + 1 < lines.count, let alignments = tableAlignments(lines[i + 1]) else { return nil }
        let allHeaders = cells(lines[i].trimmingCharacters(in: .whitespaces))
        guard allHeaders.count == alignments.count else { return nil }
        let header = Array(allHeaders.prefix(maxTableColumns))
        var rows: [[String]] = []
        i += 2
        while i < lines.count, !isBlank(lines[i]), lines[i].contains("|") {
            if rows.count < maxTableRows {
                var row = cells(lines[i].trimmingCharacters(in: .whitespaces))
                row = Array(row.prefix(header.count)) + Array(repeating: "", count: max(0, header.count - row.count))
                rows.append(row)
            }
            i += 1
        }
        return .table(header: header, alignments: Array(alignments.prefix(header.count)), rows: rows)
    }

    /// Raw HTML up to the next blank line.
    private static func htmlBlock(_ lines: [String], from i: inout Int) -> MarkdownBlock {
        var html: [String] = []
        while i < lines.count, !isBlank(lines[i]) {
            html.append(lines[i])
            i += 1
        }
        return .html(html.joined(separator: "\n"))
    }

    // MARK: - Lists

    private struct ListMarker {
        var indent: Int
        var ordered: Bool
        var number: Int
        var delimiter: Character
        /// Column where the item's content starts.
        var contentOffset: Int
        var isEmpty: Bool

        var canInterruptParagraph: Bool { !isEmpty && (!ordered || number == 1) }
    }

    private static func listMarker(_ line: String) -> ListMarker? {
        let indent = indentation(line)
        guard indent < 4 else { return nil }
        let rest = line.dropFirst(indent)
        var ordered = false
        var number = 0
        var markerWidth = 1
        var delimiter: Character
        if let first = rest.first, "-*+".contains(first) {
            delimiter = first
        } else {
            let digits = rest.prefix(while: \.isASCIIDigit)
            guard (1...9).contains(digits.count), let next = rest.dropFirst(digits.count).first, next == "." || next == ")" else { return nil }
            ordered = true
            number = Int(digits) ?? 1
            markerWidth = digits.count + 1
            delimiter = next
        }
        let afterMarker = rest.dropFirst(markerWidth)
        if afterMarker.isEmpty {
            return ListMarker(indent: indent, ordered: ordered, number: number, delimiter: delimiter,
                              contentOffset: indent + markerWidth + 1, isEmpty: true)
        }
        guard afterMarker.first == " " else { return nil }
        let spaces = afterMarker.prefix(while: { $0 == " " }).count
        let gap = spaces > 4 ? 1 : spaces
        return ListMarker(indent: indent, ordered: ordered, number: number, delimiter: delimiter,
                          contentOffset: indent + markerWidth + gap, isEmpty: afterMarker.allSatisfy { $0 == " " })
    }

    private static func parseList(_ lines: [String], from i: inout Int, depth: Int) -> MarkdownBlock {
        guard let first = listMarker(lines[i]) else { return .paragraph(lines[i]) }
        var items: [MarkdownListItem] = []
        while i < lines.count, let marker = listMarker(lines[i]), marker.ordered == first.ordered,
              marker.delimiter == first.delimiter, marker.indent < first.contentOffset, !isRule(lines[i].trimmingCharacters(in: .whitespaces)) {
            var content = [String(lines[i].dropFirst(marker.contentOffset))]
            i += 1
            while i < lines.count {
                let line = lines[i]
                if isBlank(line) {
                    // A blank line continues the item only if indented content follows.
                    var next = i + 1
                    while next < lines.count, isBlank(lines[next]) { next += 1 }
                    guard next < lines.count, indentation(lines[next]) >= marker.contentOffset else { break }
                    content.append("")
                    i += 1
                    continue
                }
                if indentation(line) >= marker.contentOffset {
                    content.append(String(line.dropFirst(marker.contentOffset)))
                } else if listMarker(line) != nil || startsBlock(line) || content.last?.isEmpty == true {
                    break
                } else {
                    content.append(line.trimmingCharacters(in: .whitespaces))
                }
                i += 1
            }
            var checked: Bool?
            if let head = content.first, head.hasPrefix("[ ] ") || head.lowercased().hasPrefix("[x] ") {
                checked = head.lowercased().hasPrefix("[x]")
                content[0] = String(head.dropFirst(4))
            }
            items.append(MarkdownListItem(checked: checked, blocks: parse(lines: content, depth: depth + 1)))
            // Blank lines between items keep the list going.
            var next = i
            while next < lines.count, isBlank(lines[next]) { next += 1 }
            if next > i, next < lines.count, let following = listMarker(lines[next]), following.ordered == first.ordered,
               following.delimiter == first.delimiter, following.indent < first.contentOffset {
                i = next
            }
        }
        return .list(ordered: first.ordered, start: first.number, items: items)
    }

    // MARK: - Line classification

    private static func indentation(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " }
    }

    private static func fence(_ trimmed: String) -> (marker: String, info: String)? {
        for char in ["`", "~"] where trimmed.hasPrefix(String(repeating: char, count: 3)) {
            let marker = String(trimmed.prefix(while: { String($0) == char }))
            let info = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            if char == "`", info.contains("`") { return nil }
            return (marker, info)
        }
        return nil
    }

    private static func atxHeading(_ trimmed: String) -> (Int, String)? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Closing hashes (`## Title ##`) are decoration. (Checked by hand: a regex for this backtracked quadratically
        // over a long run of spaces inside the heading.)
        let closing = text.reversed().prefix(while: { $0 == "#" }).count
        if closing > 0, closing < text.count, text.dropLast(closing).last?.isWhitespace == true {
            text = text.dropLast(closing).trimmingCharacters(in: .whitespaces)
        }
        if text.allSatisfy({ $0 == "#" }) { text = "" }
        return (hashes, text)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, "-*_".contains(first) else { return false }
        let compact = trimmed.filter { $0 != " " }
        return compact.count >= 3 && compact.allSatisfy { $0 == first }
    }

    private static func startsBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return fence(trimmed) != nil || atxHeading(trimmed) != nil || isRule(trimmed) || trimmed.hasPrefix(">")
    }

    private static func isHTMLBlockStart(_ trimmed: String) -> Bool {
        trimmed.firstMatch(of: /^<(\/?[A-Za-z][A-Za-z0-9-]*[\s>\/]|\/?[A-Za-z][A-Za-z0-9-]*$|!--)/) != nil
    }

    private static func tableAlignments(_ line: String) -> [NSTextAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.allSatisfy({ "|:- ".contains($0) }) else { return nil }
        let parts = cells(trimmed)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.contains("-") }) else { return nil }
        return parts.map { part in
            switch (part.hasPrefix(":"), part.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .right
            default: .left
            }
        }
    }

    /// Cells of a table row, honoring `\|` escapes and outer pipes.
    private static func cells(_ row: String) -> [String] {
        var text = Substring(row)
        if text.hasPrefix("|") { text = text.dropFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text = text.dropLast() }
        var result: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for char in text {
            if escaped { current.append(char == "|" ? "|" : "\\\(char)"); escaped = false; continue }
            if char == "\\" { escaped = true; continue }
            if char == "`" { inCode.toggle() }
            if char == "|", !inCode {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }
}

private extension Character {
    nonisolated var isASCIIDigit: Bool { isASCII && isNumber }
}
