import Foundation

/// What a highlighted run of source is; `CodeTheme` gives each kind its color.
nonisolated package enum TokenKind: UInt8, Sendable {
    case comment, string, number, keyword, type, function, declaration, attribute, preprocessor, key, tag
    case inserted, deleted, meta
}

/// A highlighted run in UTF-16 offsets, so it maps straight onto `NSRange`.
nonisolated package struct Token: Sendable {
    package var location: Int
    package var length: Int
    package var kind: TokenKind
}

/// A quoted literal: its delimiters, whether it may span lines and whether backslash escapes the next character.
nonisolated package struct StringRule: Sendable {
    package var open: String
    package var close: String
    package var multiline = false
    package var escapes = true
    package var kind = TokenKind.string

    package static let double = StringRule(open: "\"", close: "\"")
    package static let single = StringRule(open: "'", close: "'")
    package static let backtick = StringRule(open: "`", close: "`", multiline: true)
    package static let tripleDouble = StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true)
    package static let tripleSingle = StringRule(open: "'''", close: "'''", multiline: true)
}

/// Lexical rules for the generic, C/script/config-style lexer. Every switch is off by default.
nonisolated package struct LexRules: Sendable {
    package var lineComments: [String] = []
    package var blockComments: [(open: String, close: String)] = []
    package var nestedComments = false
    /// `#`-style comments start only at the beginning of a line or after whitespace (shells, YAML values).
    package var commentNeedsBoundary = false
    /// Longest delimiters first.
    package var strings: [StringRule] = [.double, .single]
    /// Identifiers that, directly followed by a quote, belong to the string (`f"…"`, `r#"…"`, `@"…"`).
    package var stringPrefixes: Set<String> = []
    package var keywords: Set<String> = []
    /// Keywords only when they are the first word on a line (Dockerfile instructions).
    package var lineStartKeywords: Set<String> = []
    package var types: Set<String> = []
    /// Keywords after which the next identifier is being declared (`func name`, `class Name`).
    package var declarationKeywords: Set<String> = []
    package var caseInsensitive = false
    package var capitalizedTypes = false
    package var functionCalls = false
    /// `ALL_CAPS` identifiers look like macros (C family).
    package var allCapsMacros = false
    /// `ALL_CAPS` identifiers are types (Swift's `URL`, `UUID`).
    package var allCapsTypes = false
    package var identifierExtras = ""
    /// `@name` is an attribute or decorator (or a keyword, when `@name` is in `keywords`).
    package var attributePrefix: Character?
    /// `#name` is a preprocessor directive, at the start of a line unless `preprocessorAnywhere`.
    package var preprocessorPrefix: Character?
    package var preprocessorAnywhere = false
    /// `$name`, `${…}` and `$1` are variables; `variableParens` also makes `$(…)` one.
    package var variablePrefix: Character?
    package var variableParens = false
    /// A leading identifier followed by one of these is a key (`key = value`, `KEY: value`, `target:`).
    package var keyAssignment = ""
    /// `[section]` lines (INI, TOML).
    package var sectionHeaders = false
    /// Rust: `name!` macros, `'a` lifetimes and `#[attributes]`.
    package var rustSyntax = false
    /// Ruby/Elixir `:symbols`.
    package var symbols = false
}

/// How a language is tokenized.
nonisolated package enum Lexer: Sendable {
    case generic(LexRules)
    case markup
    case css(lineComments: Bool)
    case yaml
    case json
    case diff
    case plain
}

/// Fast, regex-free tokenizer for syntax highlighting. Works on UTF-16 so token ranges are `NSRange`-compatible.
nonisolated package enum SyntaxHighlighter {
    package static func tokens(in text: String, lexer: Lexer) -> [Token] {
        let units = Array(text.utf16)
        var tokens: [Token] = []
        tokens.reserveCapacity(units.count / 8)
        units.withUnsafeBufferPointer { buffer in
            let scanner = Scanner(u: buffer)
            scanner.lex(lexer, range: 0..<buffer.count, into: &tokens)
        }
        return tokens
    }
}

// MARK: - Characters

nonisolated private enum Ch {
    static let tab: UInt16 = 0x09, newline: UInt16 = 0x0A, space: UInt16 = 0x20
    static let bang: UInt16 = 0x21, quote: UInt16 = 0x22, hash: UInt16 = 0x23, dollar: UInt16 = 0x24
    static let percent: UInt16 = 0x25, amp: UInt16 = 0x26, apostrophe: UInt16 = 0x27
    static let lparen: UInt16 = 0x28, rparen: UInt16 = 0x29, star: UInt16 = 0x2A, plus: UInt16 = 0x2B
    static let minus: UInt16 = 0x2D, dot: UInt16 = 0x2E, slash: UInt16 = 0x2F
    static let colon: UInt16 = 0x3A, semicolon: UInt16 = 0x3B, lt: UInt16 = 0x3C, equal: UInt16 = 0x3D
    static let gt: UInt16 = 0x3E, question: UInt16 = 0x3F, at: UInt16 = 0x40
    static let lbracket: UInt16 = 0x5B, backslash: UInt16 = 0x5C, rbracket: UInt16 = 0x5D
    static let underscore: UInt16 = 0x5F, lbrace: UInt16 = 0x7B, pipe: UInt16 = 0x7C, rbrace: UInt16 = 0x7D

    @inline(__always) static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    @inline(__always) static func isUpper(_ c: UInt16) -> Bool { c >= 0x41 && c <= 0x5A }
    @inline(__always) static func isLower(_ c: UInt16) -> Bool { c >= 0x61 && c <= 0x7A }
    @inline(__always) static func isHexDigit(_ c: UInt16) -> Bool {
        isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }
    @inline(__always) static func isIdentStart(_ c: UInt16) -> Bool { isUpper(c) || isLower(c) || c == underscore || c >= 0x80 }
    @inline(__always) static func isIdentChar(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) }
    @inline(__always) static func isSpace(_ c: UInt16) -> Bool { c == space || c == tab || c == newline }
}

// MARK: - Scanner

nonisolated private struct Scanner {
    let u: UnsafeBufferPointer<UInt16>

    func lex(_ lexer: Lexer, range: Range<Int>, into tokens: inout [Token]) {
        switch lexer {
        case .generic(let rules): GenericLexer(s: self, rules: rules).lex(range, into: &tokens)
        case .markup: lexMarkup(range, into: &tokens)
        case .css(let lineComments): lexCSS(range, lineComments: lineComments, into: &tokens)
        case .yaml: lexYAML(range, into: &tokens)
        case .json: lexJSON(range, into: &tokens)
        case .diff: lexDiff(range, into: &tokens)
        case .plain: break
        }
    }

    @inline(__always) func at(_ i: Int, _ end: Int) -> UInt16 { i < end ? u[i] : 0 }

    func matches(_ pattern: [UInt16], at i: Int, end: Int) -> Bool {
        guard i + pattern.count <= end else { return false }
        for (offset, c) in pattern.enumerated() where u[i + offset] != c { return false }
        return true
    }

    func matchesCaseInsensitive(_ pattern: String, at i: Int, end: Int) -> Bool {
        let pattern = Array(pattern.utf16)
        guard i + pattern.count <= end else { return false }
        for (offset, c) in pattern.enumerated() {
            var d = u[i + offset]
            if Ch.isUpper(d) { d += 0x20 }
            if d != c { return false }
        }
        return true
    }

    func endOfLine(from i: Int, end: Int) -> Int {
        var j = i
        while j < end, u[j] != Ch.newline { j += 1 }
        return j
    }

    func skipSpaces(from i: Int, end: Int) -> Int {
        var j = i
        while j < end, u[j] == Ch.space || u[j] == Ch.tab { j += 1 }
        return j
    }

    func identifierEnd(from i: Int, end: Int, extras: Set<UInt16> = []) -> Int {
        var j = i
        while j < end, Ch.isIdentChar(u[j]) || extras.contains(u[j]) { j += 1 }
        return j
    }

    func word(_ start: Int, _ end: Int) -> String {
        guard end > start, let base = u.baseAddress else { return "" }
        return String(utf16CodeUnits: base + start, count: end - start)
    }

    /// End of the text closed by `close`, honoring backslash escapes; stops at a newline unless `multiline`.
    func quotedEnd(from i: Int, close: [UInt16], escapes: Bool, multiline: Bool, end: Int) -> Int {
        var j = i
        while j < end {
            let c = u[j]
            if escapes, c == Ch.backslash { j += 2; continue }
            if c == close[0], matches(close, at: j, end: end) { return j + close.count }
            if c == Ch.newline, !multiline { return j }
            j += 1
        }
        return end
    }

    /// End of a number literal starting at `i`: hex/binary prefixes, `_` separators, fractions, exponents and unit suffixes.
    func numberEnd(from i: Int, end: Int) -> Int {
        var j = i
        if u[j] == 0x30, j + 1 < end, [0x78, 0x58, 0x62, 0x42, 0x6F].contains(u[j + 1]) {
            j += 2
            while j < end, Ch.isHexDigit(u[j]) || u[j] == Ch.underscore { j += 1 }
        } else {
            while j < end {
                let c = u[j]
                if Ch.isDigit(c) || c == Ch.underscore {
                    j += 1
                } else if c == Ch.dot, Ch.isDigit(at(j + 1, end)) {
                    j += 1
                } else if (c == 0x65 || c == 0x45), Ch.isDigit(at(j + 1, end))
                            || ((at(j + 1, end) == Ch.plus || at(j + 1, end) == Ch.minus) && Ch.isDigit(at(j + 2, end))) {
                    j += 2
                } else {
                    break
                }
            }
        }
        // Type suffixes and CSS units (`10u32`, `1.5f`, `12px`, `50%`).
        while j < end, Ch.isIdentChar(u[j]) || u[j] == Ch.percent { j += 1 }
        return j
    }

    // MARK: Markup

    func lexMarkup(_ range: Range<Int>, into tokens: inout [Token]) {
        let end = range.upperBound
        var i = range.lowerBound
        func add(_ from: Int, _ to: Int, _ kind: TokenKind) {
            if to > from { tokens.append(Token(location: from, length: to - from, kind: kind)) }
        }
        let commentOpen = Array("<!--".utf16), commentClose = Array("-->".utf16)
        let cdataOpen = Array("<![CDATA[".utf16), cdataClose = Array("]]>".utf16)
        let piClose = Array("?>".utf16)
        while i < end {
            let c = u[i]
            if c == Ch.lt {
                if matches(commentOpen, at: i, end: end) {
                    let j = quotedEnd(from: i + 4, close: commentClose, escapes: false, multiline: true, end: end)
                    add(i, j, .comment); i = j; continue
                }
                if matches(cdataOpen, at: i, end: end) {
                    let j = quotedEnd(from: i + 9, close: cdataClose, escapes: false, multiline: true, end: end)
                    add(i, j, .string); i = j; continue
                }
                if at(i + 1, end) == Ch.question {
                    let j = quotedEnd(from: i + 2, close: piClose, escapes: false, multiline: true, end: end)
                    add(i, j, .preprocessor); i = j; continue
                }
                if at(i + 1, end) == Ch.bang {
                    let j = quotedEnd(from: i + 2, close: [Ch.gt], escapes: false, multiline: true, end: end)
                    add(i, j, .preprocessor); i = j; continue
                }
                let closing = at(i + 1, end) == Ch.slash
                let nameStart = closing ? i + 2 : i + 1
                guard Ch.isIdentStart(at(nameStart, end)) else { i += 1; continue }
                let nameEnd = identifierEnd(from: nameStart, end: end, extras: [Ch.colon, Ch.minus, Ch.dot])
                add(i, nameEnd, .tag)
                let name = word(nameStart, nameEnd).lowercased()
                var j = nameEnd
                var selfClosing = false
                while j < end {
                    let d = u[j]
                    if d == Ch.gt { add(j, j + 1, .tag); j += 1; break }
                    if d == Ch.slash, at(j + 1, end) == Ch.gt { add(j, j + 2, .tag); j += 2; selfClosing = true; break }
                    if d == Ch.quote || d == Ch.apostrophe {
                        let k = quotedEnd(from: j + 1, close: [d], escapes: false, multiline: true, end: end)
                        add(j, k, .string); j = k; continue
                    }
                    if Ch.isIdentStart(d) {
                        let k = identifierEnd(from: j, end: end, extras: [Ch.colon, Ch.minus, Ch.dot])
                        add(j, k, .attribute); j = k; continue
                    }
                    j += 1
                }
                i = j
                // Script and style bodies get their own language.
                if !closing, !selfClosing, name == "script" || name == "style" {
                    var k = i
                    while k < end, !(u[k] == Ch.lt && at(k + 1, end) == Ch.slash && matchesCaseInsensitive(name, at: k + 2, end: end)) { k += 1 }
                    let inner: Lexer = name == "script" ? Languages.javaScript.lexer : .css(lineComments: false)
                    lex(inner, range: i..<k, into: &tokens)
                    i = k
                }
                continue
            }
            if c == Ch.amp {
                var j = i + 1
                while j < end, j - i < 12, Ch.isIdentChar(u[j]) || u[j] == Ch.hash { j += 1 }
                if at(j, end) == Ch.semicolon, j > i + 1 { add(i, j + 1, .number); i = j + 1; continue }
            }
            i += 1
        }
    }

    // MARK: CSS

    func lexCSS(_ range: Range<Int>, lineComments: Bool, into tokens: inout [Token]) {
        let end = range.upperBound
        var i = range.lowerBound
        var depth = 0, parens = 0
        var inValue = false, afterProperty = false
        func add(_ from: Int, _ to: Int, _ kind: TokenKind) {
            if to > from { tokens.append(Token(location: from, length: to - from, kind: kind)) }
        }
        let dash: Set<UInt16> = [Ch.minus]
        while i < end {
            let c = u[i]
            let next = at(i + 1, end)
            if Ch.isSpace(c) { i += 1; continue }
            if c == Ch.slash, next == Ch.star {
                let j = quotedEnd(from: i + 2, close: [Ch.star, Ch.slash], escapes: false, multiline: true, end: end)
                add(i, j, .comment); i = j; continue
            }
            if lineComments, parens == 0, c == Ch.slash, next == Ch.slash {
                let j = endOfLine(from: i, end: end)
                add(i, j, .comment); i = j; continue
            }
            if c == Ch.quote || c == Ch.apostrophe {
                let j = quotedEnd(from: i + 1, close: [c], escapes: true, multiline: false, end: end)
                add(i, j, .string); i = j; continue
            }
            switch c {
            case Ch.lbrace: depth += 1; inValue = false; i += 1; continue
            case Ch.rbrace: depth = max(0, depth - 1); inValue = false; i += 1; continue
            case Ch.semicolon: inValue = false; i += 1; continue
            case Ch.lparen: parens += 1; i += 1; continue
            case Ch.rparen: parens = max(0, parens - 1); i += 1; continue
            default: break
            }
            if c == Ch.at || c == Ch.dollar, Ch.isIdentStart(next) || next == Ch.minus {
                let j = identifierEnd(from: i + 1, end: end, extras: dash)
                add(i, j, c == Ch.at ? .keyword : .attribute)
                if c == Ch.dollar, !inValue, at(skipSpaces(from: j, end: end), end) == Ch.colon { afterProperty = true }
                i = j; continue
            }
            if c == Ch.bang, Ch.isIdentStart(next) {
                let j = identifierEnd(from: i + 1, end: end)
                add(i, j, .keyword); i = j; continue
            }
            if c == Ch.hash || (c == Ch.dot && !Ch.isDigit(next)) {
                let j = identifierEnd(from: i + 1, end: end, extras: dash)
                if j > i + 1 { add(i, j, inValue && c == Ch.hash ? .number : .type) }
                i = max(j, i + 1); continue
            }
            if Ch.isDigit(c) || (c == Ch.dot && Ch.isDigit(next)) || (c == Ch.minus && Ch.isDigit(next) && inValue) {
                let j = numberEnd(from: c == Ch.minus ? i + 1 : i, end: end)
                add(i, j, .number); i = j; continue
            }
            if c == Ch.colon {
                if afterProperty { inValue = true; afterProperty = false; i += 1; continue }
                var j = i + 1
                if at(j, end) == Ch.colon { j += 1 }
                let k = identifierEnd(from: j, end: end, extras: dash)
                if k > j, !inValue { add(i, k, .keyword) }
                i = max(k, i + 1); continue
            }
            if Ch.isIdentStart(c) || c == Ch.minus {
                let j = identifierEnd(from: i, end: end, extras: dash)
                guard j > i else { i += 1; continue }
                if inValue {
                    if at(j, end) == Ch.lparen { add(i, j, .function) }
                } else if depth > 0, at(skipSpaces(from: j, end: end), end) == Ch.colon {
                    add(i, j, word(i, i + min(2, j - i)) == "--" ? .attribute : .key)
                    afterProperty = true
                } else {
                    add(i, j, .tag)
                }
                i = j; continue
            }
            i += 1
        }
    }

    // MARK: YAML

    func lexYAML(_ range: Range<Int>, into tokens: inout [Token]) {
        let end = range.upperBound
        var lineStart = range.lowerBound
        var blockIndent: Int? = nil
        let values = GenericLexer(s: self, rules: Languages.yamlValueRules)
        func add(_ from: Int, _ to: Int, _ kind: TokenKind) {
            if to > from { tokens.append(Token(location: from, length: to - from, kind: kind)) }
        }
        while lineStart < end {
            let lineEnd = endOfLine(from: lineStart, end: end)
            defer { lineStart = lineEnd + 1 }
            var i = skipSpaces(from: lineStart, end: lineEnd)
            let indent = i - lineStart
            if i == lineEnd { continue }
            // Lines of a `|` or `>` block scalar are one string.
            if let block = blockIndent {
                if indent > block { add(i, lineEnd, .string); continue }
                blockIndent = nil
            }
            if u[i] == Ch.hash { add(i, lineEnd, .comment); continue }
            if i == lineStart, matches([Ch.minus, Ch.minus, Ch.minus], at: i, end: lineEnd) || matches([Ch.dot, Ch.dot, Ch.dot], at: i, end: lineEnd) {
                add(i, i + 3, .preprocessor)
                i += 3
            }
            while i < lineEnd, u[i] == Ch.minus, at(i + 1, lineEnd) == Ch.space || i + 1 == lineEnd {
                i = skipSpaces(from: i + 1, end: lineEnd)
            }
            // A key ends at the first `: ` outside quotes.
            if i < lineEnd {
                var j = i
                if u[i] == Ch.quote || u[i] == Ch.apostrophe {
                    j = quotedEnd(from: i + 1, close: [u[i]], escapes: u[i] == Ch.quote, multiline: false, end: lineEnd)
                } else if ![Ch.lbracket, Ch.lbrace, Ch.amp, Ch.star, Ch.bang, Ch.pipe, Ch.gt, Ch.hash].contains(u[i]) {
                    while j < lineEnd, !(u[j] == Ch.colon && (j + 1 == lineEnd || u[j + 1] == Ch.space)),
                          !(u[j] == Ch.hash && u[j - 1] == Ch.space) { j += 1 }
                }
                if j < lineEnd, u[j] == Ch.colon, j + 1 == lineEnd || u[j + 1] == Ch.space {
                    var keyEnd = j
                    while keyEnd > i, u[keyEnd - 1] == Ch.space { keyEnd -= 1 }
                    add(i, keyEnd, .key)
                    i = skipSpaces(from: j + 1, end: lineEnd)
                }
            }
            // Anchors, aliases, tags, then the scalar.
            while i < lineEnd, u[i] == Ch.amp || u[i] == Ch.star || u[i] == Ch.bang {
                var j = i + 1
                while j < lineEnd, u[j] != Ch.space { j += 1 }
                add(i, j, .attribute)
                i = skipSpaces(from: j, end: lineEnd)
            }
            if i < lineEnd, u[i] == Ch.pipe || u[i] == Ch.gt {
                let j = endOfLine(from: i, end: lineEnd)
                add(i, j, .keyword)
                blockIndent = indent
                continue
            }
            values.lex(i..<lineEnd, into: &tokens)
        }
    }

    // MARK: JSON

    func lexJSON(_ range: Range<Int>, into tokens: inout [Token]) {
        let end = range.upperBound
        var i = range.lowerBound
        func add(_ from: Int, _ to: Int, _ kind: TokenKind) {
            if to > from { tokens.append(Token(location: from, length: to - from, kind: kind)) }
        }
        while i < end {
            let c = u[i]
            if c == Ch.quote || c == Ch.apostrophe {
                let j = quotedEnd(from: i + 1, close: [c], escapes: true, multiline: false, end: end)
                add(i, j, at(skipSpaces(from: j, end: end), end) == Ch.colon ? .key : .string)
                i = j
            } else if Ch.isDigit(c) || c == Ch.minus {
                var j = i + 1
                while j < end, Ch.isDigit(u[j]) || [Ch.dot, 0x65, 0x45, Ch.plus, Ch.minus].contains(u[j]) { j += 1 }
                add(i, j, .number); i = j
            } else if Ch.isIdentStart(c) {
                let j = identifierEnd(from: i, end: end)
                if at(skipSpaces(from: j, end: end), end) == Ch.colon {
                    add(i, j, .key)
                } else if ["true", "false", "null", "NaN", "Infinity"].contains(word(i, j)) {
                    add(i, j, .keyword)
                }
                i = j
            } else if c == Ch.slash, at(i + 1, end) == Ch.slash {
                let j = endOfLine(from: i, end: end)
                add(i, j, .comment); i = j
            } else if c == Ch.slash, at(i + 1, end) == Ch.star {
                let j = quotedEnd(from: i + 2, close: [Ch.star, Ch.slash], escapes: false, multiline: true, end: end)
                add(i, j, .comment); i = j
            } else {
                i += 1
            }
        }
    }

    // MARK: Diff

    func lexDiff(_ range: Range<Int>, into tokens: inout [Token]) {
        let end = range.upperBound
        var lineStart = range.lowerBound
        let headers = ["diff ", "index ", "--- ", "+++ ", "new file", "deleted file", "similarity", "rename ", "old mode", "new mode"]
            .map { Array($0.utf16) }
        while lineStart < end {
            let lineEnd = endOfLine(from: lineStart, end: end)
            defer { lineStart = lineEnd + 1 }
            guard lineEnd > lineStart else { continue }
            let kind: TokenKind?
            if headers.contains(where: { matches($0, at: lineStart, end: lineEnd) }) {
                kind = .meta
            } else {
                switch u[lineStart] {
                case Ch.plus: kind = .inserted
                case Ch.minus: kind = .deleted
                case Ch.at: kind = .preprocessor
                default: kind = nil
                }
            }
            if let kind { tokens.append(Token(location: lineStart, length: lineEnd - lineStart, kind: kind)) }
        }
    }
}

// MARK: - Generic lexer

nonisolated private struct GenericLexer {
    let s: Scanner
    let rules: LexRules
    let lineComments: [[UInt16]]
    let blockComments: [(open: [UInt16], close: [UInt16])]
    let strings: [(rule: StringRule, open: [UInt16], close: [UInt16])]
    let extras: Set<UInt16>
    let keyAssignment: Set<UInt16>
    let attributePrefix: UInt16?
    let preprocessorPrefix: UInt16?
    let variablePrefix: UInt16?

    init(s: Scanner, rules: LexRules) {
        self.s = s
        self.rules = rules
        lineComments = rules.lineComments.map { Array($0.utf16) }
        blockComments = rules.blockComments.map { (Array($0.open.utf16), Array($0.close.utf16)) }
        strings = rules.strings.map { ($0, Array($0.open.utf16), Array($0.close.utf16)) }
        extras = Set(rules.identifierExtras.utf16)
        keyAssignment = Set(rules.keyAssignment.utf16)
        attributePrefix = rules.attributePrefix?.utf16.first
        preprocessorPrefix = rules.preprocessorPrefix?.utf16.first
        variablePrefix = rules.variablePrefix?.utf16.first
    }

    private var u: UnsafeBufferPointer<UInt16> { s.u }

    /// Where the scan is on its line, which decides how the next token reads.
    private struct LineState {
        /// Something other than spaces came before on this line.
        var hasContent = false
        /// Only keywords so far on this line: a leading identifier followed by `=` or `:` is then a key.
        var onlyKeywords = true
        /// The last keyword declares a name (`func`, `class`): the next identifier is that name.
        var pendingDeclaration = false
        var previous: UInt16 = Ch.newline

        mutating func startLine() {
            hasContent = false
            onlyKeywords = true
            previous = Ch.newline
        }
    }

    /// A token a recognizer found, and what reading it does to the line.
    private struct Read {
        let end: Int
        let kind: TokenKind
        var endsDeclaration = false
        var endsKeywordsOnly = false
        var setsPrevious = false
    }

    func lex(_ range: Range<Int>, into tokens: inout [Token]) {
        let end = range.upperBound
        var i = range.lowerBound
        var line = LineState()
        while i < end {
            let c = u[i]
            if c == Ch.newline {
                line.startLine()
                i += 1
                continue
            }
            if c == Ch.space || c == Ch.tab { line.previous = c; i += 1; continue }
            let atLineStart = !line.hasContent
            line.hasContent = true
            if let read = token(at: i, end: end, atLineStart: atLineStart, previous: line.previous) {
                if read.end > i { tokens.append(Token(location: i, length: read.end - i, kind: read.kind)) }
                apply(read, to: &line)
                i = read.end
            } else if Ch.isIdentStart(c) {
                i = identifier(at: i, end: end, atLineStart: atLineStart, line: &line, tokens: &tokens)
                line.previous = u[i - 1]
            } else {
                line.pendingDeclaration = line.pendingDeclaration && (c == Ch.backslash || c == 0x60)
                line.onlyKeywords = false
                line.previous = c
                i += 1
            }
        }
    }

    /// The token other than an identifier starting at `i`, if any: the first of these rules to match wins.
    private func token(at i: Int, end: Int, atLineStart: Bool, previous: UInt16) -> Read? {
        let c = u[i]
        if let j = commentEnd(at: i, end: end, atLineStart: atLineStart, previous: previous) {
            return Read(end: j, kind: .comment)
        }
        if rules.sectionHeaders, atLineStart, c == Ch.lbracket {
            return Read(end: sectionHeaderEnd(at: i, end: end), kind: .type, endsKeywordsOnly: true)
        }
        if rules.rustSyntax, c == Ch.apostrophe, let j = lifetimeEnd(at: i, end: end) {
            return Read(end: j, kind: .attribute)
        }
        if let (j, kind) = stringEnd(at: i, end: end) {
            return Read(end: j, kind: kind, endsDeclaration: true, endsKeywordsOnly: true, setsPrevious: true)
        }
        if c == variablePrefix, let j = variableEnd(at: i, end: end) {
            return Read(end: j, kind: .attribute, endsKeywordsOnly: true, setsPrevious: true)
        }
        if c == attributePrefix, Ch.isIdentStart(s.at(i + 1, end)) {
            let j = s.identifierEnd(from: i + 1, end: end, extras: extras.union([Ch.dot]))
            return Read(end: j, kind: rules.keywords.contains(s.word(i, j)) ? .keyword : .attribute, setsPrevious: true)
        }
        if rules.rustSyntax, c == Ch.hash,
           s.at(i + 1, end) == Ch.lbracket || (s.at(i + 1, end) == Ch.bang && s.at(i + 2, end) == Ch.lbracket) {
            return Read(end: rustAttributeEnd(at: i, end: end), kind: .attribute)
        }
        if c == preprocessorPrefix, rules.preprocessorAnywhere || atLineStart, let j = directiveEnd(at: i, end: end) {
            return Read(end: j, kind: .preprocessor, setsPrevious: true)
        }
        if Ch.isDigit(c) || (c == Ch.dot && Ch.isDigit(s.at(i + 1, end)) && !Ch.isIdentChar(previous)) {
            return Read(end: s.numberEnd(from: i, end: end), kind: .number, endsDeclaration: true, endsKeywordsOnly: true,
                        setsPrevious: true)
        }
        if rules.symbols, c == Ch.colon, Ch.isIdentStart(s.at(i + 1, end)), previous != Ch.colon, !Ch.isIdentChar(previous) {
            return Read(end: s.identifierEnd(from: i + 1, end: end), kind: .number, setsPrevious: true)
        }
        return nil
    }

    private func apply(_ read: Read, to line: inout LineState) {
        if read.endsDeclaration { line.pendingDeclaration = false }
        if read.endsKeywordsOnly { line.onlyKeywords = false }
        if read.setsPrevious { line.previous = u[read.end - 1] }
    }

    /// `[section]` at the start of a line, its closing brackets included.
    private func sectionHeaderEnd(at i: Int, end: Int) -> Int {
        var j = i + 1
        while j < end, u[j] != Ch.newline, u[j] != Ch.rbracket { j += 1 }
        while j < end, u[j] == Ch.rbracket { j += 1 }
        return j
    }

    /// A Rust lifetime (`'a`), not a character literal (`'a'`).
    private func lifetimeEnd(at i: Int, end: Int) -> Int? {
        guard Ch.isIdentStart(s.at(i + 1, end)) else { return nil }
        let j = s.identifierEnd(from: i + 1, end: end)
        return s.at(j, end) == Ch.apostrophe ? nil : j
    }

    /// A Rust attribute, `#[…]` or `#![…]`, up to its closing bracket or the end of the line.
    private func rustAttributeEnd(at i: Int, end: Int) -> Int {
        var j = i + 1, depth = 0
        while j < end {
            if u[j] == Ch.lbracket { depth += 1 }
            if u[j] == Ch.rbracket { depth -= 1; if depth == 0 { j += 1; break } }
            if u[j] == Ch.newline { break }
            j += 1
        }
        return j
    }

    /// A preprocessor directive's name after its prefix (`#include`, `# define`); nil when no name follows.
    private func directiveEnd(at i: Int, end: Int) -> Int? {
        let nameStart = s.skipSpaces(from: i + 1, end: end)
        guard Ch.isIdentStart(s.at(nameStart, end)) else { return nil }
        return s.identifierEnd(from: nameStart, end: end)
    }

    private func identifier(at start: Int, end: Int, atLineStart: Bool, line: inout LineState,
                            tokens: inout [Token]) -> Int {
        var j = s.identifierEnd(from: start, end: end, extras: extras)
        let word = s.word(start, j)
        let key = rules.caseInsensitive ? word.lowercased() : word
        if !rules.stringPrefixes.isEmpty, rules.stringPrefixes.contains(key), let (stringEnd, _) = stringEnd(at: j, end: end) {
            tokens.append(Token(location: start, length: stringEnd - start, kind: .string))
            line.onlyKeywords = false
            return stringEnd
        }
        let next = s.at(j, end)
        var kind: TokenKind?
        if rules.keywords.contains(key) || (atLineStart && rules.lineStartKeywords.contains(key)) {
            kind = .keyword
        } else if line.pendingDeclaration {
            kind = .declaration
        } else if rules.types.contains(key) {
            kind = .type
        } else if !keyAssignment.isEmpty, line.onlyKeywords, isAssignment(at: j, end: end) {
            kind = .key
        } else if rules.rustSyntax, next == Ch.bang, s.at(j + 1, end) != Ch.equal {
            j += 1
            kind = .preprocessor
        } else if Ch.isUpper(u[start]), j - start > 1, !word.utf16.contains(where: Ch.isLower),
                  rules.allCapsMacros || rules.allCapsTypes {
            // `NAME` is a macro in C, a type in Swift (`URL`), and a plain constant elsewhere.
            kind = rules.allCapsMacros ? .preprocessor : .type
        } else if rules.capitalizedTypes, Ch.isUpper(u[start]), word.utf16.contains(where: Ch.isLower) {
            kind = .type
        } else if rules.functionCalls, next == Ch.lparen {
            kind = .function
        }
        line.pendingDeclaration = kind == .keyword && rules.declarationKeywords.contains(key)
        if kind != .keyword { line.onlyKeywords = false }
        if let kind { tokens.append(Token(location: start, length: j - start, kind: kind)) }
        return j
    }

    /// Whether `i` (after a leading identifier) continues with `=`, `:` or a compound operator like `:=`, `?=`, `+=`.
    private func isAssignment(at i: Int, end: Int) -> Bool {
        let j = s.skipSpaces(from: i, end: end)
        let c = s.at(j, end)
        if keyAssignment.contains(c) {
            // `a == b` and `std::x` aren't assignments.
            return s.at(j + 1, end) != c
        }
        return [Ch.question, Ch.plus, Ch.colon, Ch.bang].contains(c) && s.at(j + 1, end) == Ch.equal && keyAssignment.contains(Ch.equal)
    }

    private func commentEnd(at i: Int, end: Int, atLineStart: Bool, previous: UInt16) -> Int? {
        let c = u[i]
        for (open, close) in blockComments where open[0] == c && s.matches(open, at: i, end: end) {
            var j = i + open.count, depth = 1
            while j < end {
                if rules.nestedComments, s.matches(open, at: j, end: end) { depth += 1; j += open.count; continue }
                if s.matches(close, at: j, end: end) {
                    depth -= 1; j += close.count
                    if depth == 0 || !rules.nestedComments { return j }
                    continue
                }
                j += 1
            }
            return end
        }
        for prefix in lineComments where prefix[0] == c && s.matches(prefix, at: i, end: end) {
            if rules.commentNeedsBoundary, !atLineStart, previous != Ch.space, previous != Ch.tab { continue }
            return s.endOfLine(from: i, end: end)
        }
        return nil
    }

    private func stringEnd(at i: Int, end: Int) -> (Int, TokenKind)? {
        let c = u[i]
        for (rule, open, close) in strings where open[0] == c && s.matches(open, at: i, end: end) {
            return (s.quotedEnd(from: i + open.count, close: close, escapes: rule.escapes, multiline: rule.multiline, end: end), rule.kind)
        }
        return nil
    }

    private func variableEnd(at i: Int, end: Int) -> Int? {
        let next = s.at(i + 1, end)
        if next == Ch.lbrace || (next == Ch.lparen && rules.variableParens) {
            let close = next == Ch.lbrace ? Ch.rbrace : Ch.rparen
            var j = i + 2, depth = 1
            while j < end, u[j] != Ch.newline {
                if u[j] == next { depth += 1 }
                if u[j] == close { depth -= 1; if depth == 0 { return j + 1 } }
                j += 1
            }
            return j
        }
        if Ch.isIdentStart(next) { return s.identifierEnd(from: i + 1, end: end) }
        if Ch.isDigit(next) || [Ch.at, Ch.star, Ch.hash, Ch.question, Ch.bang, Ch.dollar, Ch.lt, 0x5E].contains(next) { return i + 2 }
        return nil
    }
}
