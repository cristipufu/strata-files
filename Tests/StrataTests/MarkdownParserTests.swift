import AppKit
import Testing
@testable import Strata

/// The block structure each kind of Markdown makes, so a change to the parser shows in what it reads.
struct MarkdownParserTests {
    private func described(_ blocks: [MarkdownBlock]) -> [String] {
        blocks.map { block in
            switch block {
            case let .heading(level, text): "h\(level) \(text)"
            case let .paragraph(text): "p \(text)"
            case let .code(language, text): "code[\(language)] \(text)"
            case let .quote(inner): "quote(\(described(inner).joined(separator: "; ")))"
            case let .list(ordered, start, items):
                "\(ordered ? "ol \(start)" : "ul")(" + items.map { item in
                    (item.checked.map { $0 ? "[x] " : "[ ] " } ?? "") + described(item.blocks).joined(separator: "; ")
                }.joined(separator: " | ") + ")"
            case .rule: "rule"
            case let .table(header, alignments, rows):
                "table \(header) \(alignments.map(\.rawValue)) \(rows)"
            case let .html(text): "html \(text)"
            }
        }
    }

    @Test func eachKindOfBlock() {
        let text = """
        ---
        title: Notes
        ---
        # Title
        Setext
        ===
        A paragraph
        that goes on.

            indented code

        ```swift
        let x = 1
        ```
        ***
        > quoted
        lazily
        > > deeper

        - one
        - [x] done
        3. three
        4. four

        | a | b |
        |:--|--:|
        | 1 | 2 | 3 |
        | 4 |

        <div>
        raw
        </div>
        Plain
        """
        #expect(described(MarkdownParser.parse(text)) == [
            "code[yaml] title: Notes",
            "h1 Title",
            "h1 Setext",
            "p A paragraph\nthat goes on.",
            "code[] indented code",
            "code[swift] let x = 1",
            "rule",
            "quote(p quoted\nlazily; quote(p deeper))",
            "ul(p one | [x] p done)",
            "ol 3(p three | p four)",
            "table [\"a\", \"b\"] [0, 2] [[\"1\", \"2\"], [\"4\", \"\"]]",
            "html <div>\nraw\n</div>\nPlain",
        ])
    }

    @Test func aTableNeedsAsManyHeadersAsAlignments() {
        #expect(described(MarkdownParser.parse("a | b | c\n|--|--|\nrest")) == ["p a | b | c\n|--|--|\nrest"])
    }
}
