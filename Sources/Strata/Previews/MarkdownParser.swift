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

nonisolated package final class MarkdownParser {
    private var budget = MarkdownBudget()
    private init() {}

    package static func parse(_ text: String) throws -> [MarkdownBlock] {
        try MarkdownParser().document(text)
    }

    private func document(_ text: String) throws -> [MarkdownBlock] {
        try Task.checkCancellation()
        var lines = text.replacingOccurrences(of: "\t", with: "    ").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        // YAML front matter shows as a code block.
        if lines.first == "---", let end = lines.dropFirst().prefix(100).firstIndex(where: { $0 == "---" || $0 == "..." }) {
            try budget.reserveNode()
            blocks.append(.code(language: "yaml", text: lines[1..<end].joined(separator: "\n")))
            lines.removeSubrange(0...end)
        }
        return try blocks + parse(lines: lines, depth: 0)
    }

    /// Each quote or list level recurses; a crafted file with thousands of `>` or list markers would exhaust the stack.
    /// Nesting deeper than any real document uses shows as plain text instead.
    private let maxDepth = 16
    private func parse(lines: [String], depth: Int) throws -> [MarkdownBlock] {
        guard depth < maxDepth else {
            guard !lines.isEmpty else { return [] }
            try budget.reserveNode()
            return [.code(language: "", text: lines.joined(separator: "\n"))]
        }
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0
        func flush() throws {
            if !paragraph.isEmpty {
                try budget.reserveNode()
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            }
            paragraph = []
        }

        while i < lines.count {
            try Task.checkCancellation()
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { try flush(); i += 1; continue }
            switch try start(lines, at: &i, depth: depth, inParagraph: !paragraph.isEmpty) {
            case .block(let block)?:
                try flush()
                try budget.reserveNode()
                blocks.append(block)
            case .underline(let level)?:
                try budget.reserveNode()
                blocks.append(.heading(level: level, text: paragraph.joined(separator: "\n")))
                paragraph = []
            case nil:
                paragraph.append(trimmed + (line.hasSuffix("  ") ? "  " : ""))
                i += 1
            }
        }
        try flush()
        return blocks
    }

    private enum Start {
        case block(MarkdownBlock)
        /// A line of `=` or `-` under a paragraph: the paragraph is a heading of this level.
        case underline(level: Int)
    }

    /// What starts at line `i`, which it reads past; nil for a paragraph's text. Indented code and HTML don't
    /// interrupt a paragraph, nor do most list markers.
    private func start(_ lines: [String], at i: inout Int, depth: Int, inParagraph: Bool) throws -> Start? {
        let line = lines[i]
        let indent = indentation(line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if indent >= 4, !inParagraph { return .block(indentedCode(lines, from: &i)) }
        if let fence = fence(trimmed) { return .block(fencedCode(lines, from: &i, fence: fence, indent: indent)) }
        if let math = displayMath(lines, from: &i) { return .block(math) }
        if let (level, text) = atxHeading(trimmed) {
            i += 1
            return .block(.heading(level: level, text: text))
        }
        if inParagraph, trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" }) {
            i += 1
            return .underline(level: trimmed.first == "=" ? 1 : 2)
        }
        if isRule(trimmed) {
            i += 1
            return .block(.rule)
        }
        if trimmed.hasPrefix(">") { return .block(try quote(lines, from: &i, depth: depth)) }
        if let marker = listMarker(line), !inParagraph || marker.canInterruptParagraph {
            return .block(try parseList(lines, from: &i, depth: depth))
        }
        if trimmed.contains("|"), let table = try table(lines, from: &i) { return .block(table) }
        if !inParagraph, isHTMLBlockStart(trimmed) { return .block(htmlBlock(lines, from: &i)) }
        return nil
    }

    // MARK: - Blocks

    private func displayMath(_ lines: [String], from index: inout Int) -> MarkdownBlock? {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("$$") else { return nil }
        if line.count > 4, line.hasSuffix("$$") {
            index += 1
            return .code(language: "math", text: String(line.dropFirst(2).dropLast(2)))
        }
        guard line == "$$", index + 1 < lines.count,
              let end = ((index + 1)..<lines.count).first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "$$" }) else { return nil }
        let source = lines[(index + 1)..<end].joined(separator: "\n")
        index = end + 1
        return .code(language: "math", text: source)
    }

    /// Lines indented four spaces or more, blank ones between them included, as code.
    private func indentedCode(_ lines: [String], from i: inout Int) -> MarkdownBlock {
        var code: [String] = []
        while i < lines.count, indentation(lines[i]) >= 4 || isBlank(lines[i]) {
            code.append(String(lines[i].dropFirst(min(4, lines[i].count))))
            i += 1
        }
        while code.last?.isEmpty == true { code.removeLast() }
        return .code(language: "", text: code.joined(separator: "\n"))
    }

    /// From the opening fence (at line `i`) to the closing one, or the end.
    private func fencedCode(_ lines: [String], from i: inout Int, fence: (marker: String, info: String),
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
    private func quote(_ lines: [String], from i: inout Int, depth: Int) throws -> MarkdownBlock {
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
        return .quote(try parse(lines: quoted, depth: depth + 1))
    }

    /// A GitHub table: a header row, then its alignment row, then rows until a blank or pipeless line. nil, with `i`
    /// left alone, when line `i` doesn't start one.
    private func table(_ lines: [String], from i: inout Int) throws -> MarkdownBlock? {
        guard i + 1 < lines.count, let alignments = try tableAlignments(lines[i + 1]) else { return nil }
        let header = try cells(lines[i].trimmingCharacters(in: .whitespaces))
        guard header.count == alignments.count else { return nil }
        try budget.reserveTable()
        try budget.reserveCells(header.count)
        var rows: [[String]] = []
        i += 2
        while i < lines.count, !isBlank(lines[i]), lines[i].contains("|") {
            guard rows.count < MarkdownLimits.tableRows else { throw MarkdownLimitExceeded() }
            try budget.reserveCells(header.count)
            var row = try cells(lines[i].trimmingCharacters(in: .whitespaces))
            row = Array(row.prefix(header.count)) + Array(repeating: "", count: max(0, header.count - row.count))
            rows.append(row)
            i += 1
        }
        return .table(header: header, alignments: alignments, rows: rows)
    }

    /// Raw HTML up to the next blank line.
    private func htmlBlock(_ lines: [String], from i: inout Int) -> MarkdownBlock {
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

    private func listMarker(_ line: String) -> ListMarker? {
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

    private func parseList(_ lines: [String], from i: inout Int, depth: Int) throws -> MarkdownBlock {
        guard let first = listMarker(lines[i]) else { return .paragraph(lines[i]) }
        var items: [MarkdownListItem] = []
        while i < lines.count, let marker = listMarker(lines[i]), marker.ordered == first.ordered,
              marker.delimiter == first.delimiter, marker.indent < first.contentOffset, !isRule(lines[i].trimmingCharacters(in: .whitespaces)) {
            try Task.checkCancellation()
            try budget.reserveNode()
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
            items.append(MarkdownListItem(checked: checked, blocks: try parse(lines: content, depth: depth + 1)))
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

    private func indentation(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " }
    }

    private func fence(_ trimmed: String) -> (marker: String, info: String)? {
        for char in ["`", "~"] where trimmed.hasPrefix(String(repeating: char, count: 3)) {
            let marker = String(trimmed.prefix(while: { String($0) == char }))
            let info = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            if char == "`", info.contains("`") { return nil }
            return (marker, info)
        }
        return nil
    }

    private func atxHeading(_ trimmed: String) -> (Int, String)? {
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

    private func isRule(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, "-*_".contains(first) else { return false }
        let compact = trimmed.filter { $0 != " " }
        return compact.count >= 3 && compact.allSatisfy { $0 == first }
    }

    private func startsBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return fence(trimmed) != nil || atxHeading(trimmed) != nil || isRule(trimmed) || trimmed.hasPrefix(">") || trimmed.hasPrefix("$$")
    }

    private func isHTMLBlockStart(_ trimmed: String) -> Bool {
        trimmed.firstMatch(of: /^<(\/?[A-Za-z][A-Za-z0-9-]*[\s>\/]|\/?[A-Za-z][A-Za-z0-9-]*$|!--)/) != nil
    }

    private func tableAlignments(_ line: String) throws -> [NSTextAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.allSatisfy({ "|:- ".contains($0) }) else { return nil }
        let parts = try cells(trimmed)
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
    private func cells(_ row: String) throws -> [String] {
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
                guard result.count < MarkdownLimits.tableColumns else { throw MarkdownLimitExceeded() }
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        guard result.count < MarkdownLimits.tableColumns else { throw MarkdownLimitExceeded() }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }
}

private extension Character {
    nonisolated var isASCIIDigit: Bool { isASCII && isNumber }
}
