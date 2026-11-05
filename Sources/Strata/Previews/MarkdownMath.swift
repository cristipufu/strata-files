import Foundation

nonisolated enum MarkdownMath {
    static let sourceKey = NSAttributedString.Key("StrataMathSource")
    private static let maximumScanPasses = 8

    struct Equation: Equatable, Sendable {
        let source: String
        let original: String
        let display: Bool
        var attribute: [String: String] { ["source": source, "original": original, "display": display ? "1" : "0"] }

        init(source: String, original: String, display: Bool) {
            self.source = source; self.original = original; self.display = display
        }
        init?(attribute: Any?) {
            guard let value = attribute as? [String: String], value.count == 3,
                  let source = value["source"], source.utf8.count <= MathRenderer.textLimit,
                  let original = value["original"], original.utf8.count <= MathRenderer.textLimit + 16,
                  let display = value["display"], ["0", "1"].contains(display) else { return nil }
            self.init(source: source, original: original, display: display == "1")
        }
    }

    struct Prepared {
        let markdown: String
        let equations: [(token: String, equation: Equation)]

        func restore(in text: NSMutableAttributedString) {
            for (token, equation) in equations {
                let range = (text.string as NSString).range(of: token)
                guard range.location != NSNotFound else { continue }
                var attributes = text.attributes(at: range.location, effectiveRange: nil)
                attributes[sourceKey] = equation.attribute
                attributes[MarkdownRenderer.assetID] = UUID().uuidString
                text.replaceCharacters(in: range, with: NSAttributedString(string: equation.original, attributes: attributes))
            }
        }
    }

    static func copiedText(in document: NSAttributedString, ranges: [NSRange]) -> String? {
        var result: [String] = [], foundMath = false
        for range in ranges {
            guard range.location >= 0, range.length >= 0, range.location <= document.length,
                  range.length <= document.length - range.location else { return nil }
            let selected = document.attributedSubstring(from: range)
            let text = NSMutableString(string: selected.string)
            var equations: [(NSRange, String)] = []
            selected.enumerateAttribute(.attachment, in: NSRange(location: 0, length: selected.length)) { value, range, _ in
                guard value != nil else { return }
                if let equation = Equation(attribute: selected.attribute(sourceKey, at: range.location, effectiveRange: nil)) {
                    equations.append((range, equation.original)); foundMath = true
                } else if let source = selected.attribute(MarkdownRenderer.mermaidSource, at: range.location, effectiveRange: nil) as? String {
                    equations.append((range, "```mermaid\n" + source + "\n```"))
                }
            }
            for (range, original) in equations.reversed() { text.replaceCharacters(in: range, with: original) }
            result.append(text as String)
        }
        return foundMath ? result.joined(separator: "\n") : nil
    }

    /// Reserve literal tokens before native Markdown parsing so TeX underscores and backslashes keep their meaning.
    static func prepare(_ markdown: String, limit: Int) -> Prepared {
        guard limit > 0 else { return Prepared(markdown: markdown, equations: []) }
        let units = Array(markdown.utf16), occupied = Set(units)
        let tokens = (UInt16(0xE000)...UInt16(0xF8FF)).lazy.filter { !occupied.contains($0) }.prefix(limit)
        var available = tokens.makeIterator()
        var output: [UInt16] = [], equations: [(String, Equation)] = []
        output.reserveCapacity(units.count)
        var index = 0
        var work = units.count * maximumScanPasses
        while index < units.count {
            guard consume(&work), !Task.isCancelled else { output.append(contentsOf: units[index...]); break }
            if let end = literalEnd(units, at: index, work: &work) {
                output.append(contentsOf: units[index..<end]); index = end; continue
            }
            guard units[index] == 36, equations.count < limit, let match = equation(units, at: index, work: &work),
                  let token = available.next() else { output.append(units[index]); index += 1; continue }
            output.append(token)
            equations.append((String(decoding: [token], as: UTF16.self), match.equation))
            index = match.end
        }
        return Prepared(markdown: String(decoding: output, as: UTF16.self), equations: equations)
    }

    private static func equation(_ units: [UInt16], at start: Int, work: inout Int) -> (equation: Equation, end: Int)? {
        let display = start + 1 < units.count && units[start + 1] == 36
        let delimiter = display ? 2 : 1, beginning = start + delimiter
        guard beginning < units.count, display || !space(units[beginning]) else { return nil }
        var index = beginning
        while index < units.count {
            guard consume(&work), !Task.isCancelled else { return nil }
            if units[index] == 92 { index += min(2, units.count - index); continue }
            if !display, units[index] == 10 { return nil }
            if units[index] == 36, index > beginning,
               (!display && !space(units[index - 1]) && (index + 1 == units.count || !digit(units[index + 1])))
                || (display && index + 1 < units.count && units[index + 1] == 36) {
                let end = index + delimiter
                let source = String(decoding: units[beginning..<index], as: UTF16.self)
                guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      source.utf8.count <= MathRenderer.textLimit else { return nil }
                let original = String(decoding: units[start..<end], as: UTF16.self)
                return (Equation(source: source, original: original, display: display), end)
            }
            index += 1
        }
        return nil
    }

    private static func literalEnd(_ units: [UInt16], at start: Int, work: inout Int) -> Int? {
        if units[start] == 92 { return min(start + 2, units.count) }
        if units[start] == 96 {
            var end = start
            while end < units.count, units[end] == 96 { end += 1 }
            let count = end - start
            var index = end
            while index < units.count {
                guard consume(&work), !Task.isCancelled else { return nil }
                guard units[index] == 96 else { index += 1; continue }
                let beginning = index
                while index < units.count, units[index] == 96 { index += 1 }
                if index - beginning == count { return index }
            }
            return end
        }
        if units[start] == 60 {
            var index = start + 1
            while index < units.count {
                guard consume(&work), !Task.isCancelled else { return nil }
                if units[index] == 62 { return index + 1 }
                index += 1
            }
        }
        if start + 1 < units.count, units[start] == 33, units[start + 1] == 91 {
            guard let end = balancedEnd(units, at: start + 1, open: 91, close: 93, work: &work) else { return nil }
            if end < units.count, units[end] == 40 { return balancedEnd(units, at: end, open: 40, close: 41, work: &work) ?? end }
            return end
        }
        if start + 1 < units.count, units[start] == 93, units[start + 1] == 40,
           let end = balancedEnd(units, at: start + 1, open: 40, close: 41, work: &work) { return end }
        return nil
    }

    private static func balancedEnd(_ units: [UInt16], at start: Int, open: UInt16, close: UInt16, work: inout Int) -> Int? {
        var index = start + 1, depth = 1
        while index < units.count {
            guard consume(&work), !Task.isCancelled else { return nil }
            if units[index] == 92 { index += min(2, units.count - index); continue }
            if units[index] == open { depth += 1 }
            if units[index] == close { depth -= 1; if depth == 0 { return index + 1 } }
            index += 1
        }
        return nil
    }

    private static func digit(_ value: UInt16) -> Bool { (48...57).contains(value) }
    private static func consume(_ work: inout Int) -> Bool {
        guard work > 0 else { return false }
        work -= 1
        return true
    }
    private static func space(_ value: UInt16) -> Bool {
        Unicode.Scalar(value).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }
}
