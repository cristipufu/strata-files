import Foundation

/// Validates and pretty-prints JSON while keeping key order and number spelling exactly as written.
nonisolated package enum JSONFormatter {
    package enum Validity: Equatable {
        case valid
        /// Valid only with JSON5 extensions (comments, trailing commas), as in `tsconfig.json`; shown as written.
        case extended
        case invalid(line: Int?)
    }

    package static func validate(_ text: String) -> Validity {
        let data = Data(text.utf8)
        if (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil { return .valid }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed, .json5Allowed])
            return .extended
        } catch {
            return .invalid(line: errorLine(error as NSError, data: data))
        }
    }

    /// Re-indents `text` with two spaces. Lenient: unbalanced or truncated input still formats as far as it goes.
    /// Short arrays of plain values stay on one line.
    package static func format(_ text: String) -> String {
        let input = Array(text.utf16)
        // Indentation can multiply even a short document's size. Keep the original text when formatting
        // would make the preview too large, including incomplete files that bypass JSON validation.
        let outputLimit = 1 << 20
        guard input.count <= outputLimit else { return text }
        var printer = Printer(input: input)
        var i = 0
        while i < input.count {
            guard printer.out.count <= outputLimit else { return text }
            let c = input[i]
            switch c {
            case space, tab, newlineChar, 0x0D:
                i += 1
            case quote:
                i = printer.copy(from: i, to: stringEnd(input, from: i))
            case openBrace, openBracket:
                guard let next = printer.open(at: i) else { return text }
                i = next
            case closeBrace, closeBracket:
                printer.close(c)
                i += 1
            case comma:
                printer.out.append(comma)
                printer.newline()
                i += 1
            case colon:
                printer.out.append(colon)
                printer.out.append(space)
                i += 1
            default:
                i = printer.copy(from: i, to: scalarEnd(input, from: i))
            }
        }
        guard printer.out.count <= outputLimit else { return text }
        return String(utf16CodeUnits: printer.out, count: printer.out.count)
    }

    /// The indented text so far, and how deep it is.
    private struct Printer {
        let input: [UInt16]
        var out: [UInt16] = []
        var depth = 0

        init(input: [UInt16]) {
            self.input = input
            out.reserveCapacity(input.count + input.count / 2)
        }

        mutating func newline() {
            out.append(newlineChar)
            out.append(contentsOf: repeatElement(space, count: depth * 2))
        }

        /// Copies `input[start..<end]` as written: where to go on.
        mutating func copy(from start: Int, to end: Int) -> Int {
            out.append(contentsOf: input[start..<end])
            return end
        }

        /// An object or array opening at `i`: empty, a short array of plain values on one line, or a new level on
        /// lines of its own. Where to go on, or nil when it's nested too deep to indent.
        mutating func open(at i: Int) -> Int? {
            let c = input[i]
            let close = c == openBrace ? closeBrace : closeBracket
            let next = skipWhitespace(input, from: i + 1)
            if next < input.count, input[next] == close {
                out.append(c); out.append(close)
                return next + 1
            }
            if c == openBracket, let (inline, end) = inlineArray(input, from: i) {
                out.append(contentsOf: inline)
                return end
            }
            out.append(c)
            guard depth < 64 else { return nil }
            depth += 1
            newline()
            return i + 1
        }

        mutating func close(_ c: UInt16) {
            depth = max(0, depth - 1)
            newline()
            out.append(c)
        }
    }

    // MARK: - Helpers

    private static let space: UInt16 = 0x20, tab: UInt16 = 0x09, newlineChar: UInt16 = 0x0A, quote: UInt16 = 0x22
    private static let openBrace: UInt16 = 0x7B, closeBrace: UInt16 = 0x7D, openBracket: UInt16 = 0x5B, closeBracket: UInt16 = 0x5D
    private static let comma: UInt16 = 0x2C, colon: UInt16 = 0x3A, backslash: UInt16 = 0x5C

    private static func isStructural(_ c: UInt16) -> Bool {
        c == openBrace || c == closeBrace || c == openBracket || c == closeBracket || c == comma || c == colon || c == quote
            || c == space || c == tab || c == newlineChar || c == 0x0D
    }

    private static func skipWhitespace(_ input: [UInt16], from i: Int) -> Int {
        var j = i
        while j < input.count, input[j] == space || input[j] == tab || input[j] == newlineChar || input[j] == 0x0D { j += 1 }
        return j
    }

    private static func stringEnd(_ input: [UInt16], from i: Int) -> Int {
        var j = i + 1
        while j < input.count {
            if input[j] == backslash { j += 2; continue }
            if input[j] == quote { return j + 1 }
            j += 1
        }
        return input.count
    }

    private static func scalarEnd(_ input: [UInt16], from i: Int) -> Int {
        var j = i
        while j < input.count, !isStructural(input[j]) { j += 1 }
        return max(j, i + 1)
    }

    /// `[1, 2, 3]` on one line when the array holds only short plain values.
    private static func inlineArray(_ input: [UInt16], from start: Int) -> ([UInt16], Int)? {
        let maxWidth = 60
        var out: [UInt16] = [openBracket]
        var i = start + 1
        var expectValue = true
        while i < input.count, out.count <= maxWidth {
            i = skipWhitespace(input, from: i)
            guard i < input.count else { return nil }
            let c = input[i]
            if c == closeBracket {
                guard !expectValue || out.count == 1 else { return nil }
                out.append(closeBracket)
                return (out, i + 1)
            }
            if expectValue {
                if c == openBrace || c == openBracket || c == comma || c == colon { return nil }
                let end = c == quote ? stringEnd(input, from: i) : scalarEnd(input, from: i)
                out.append(contentsOf: input[i..<end])
                i = end
                expectValue = false
            } else {
                guard c == comma else { return nil }
                out.append(comma); out.append(space)
                i += 1
                expectValue = true
            }
        }
        return nil
    }

    private static func errorLine(_ error: NSError, data: Data) -> Int? {
        if let description = error.userInfo[NSDebugDescriptionErrorKey] as? String,
           let match = description.firstMatch(of: /line (\d+)/), let line = Int(match.1) {
            return line
        }
        if let index = error.userInfo["NSJSONSerializationErrorIndex"] as? Int, index >= 0, index <= data.count {
            return data.prefix(index).count(where: { $0 == 0x0A }) + 1
        }
        return nil
    }
}
