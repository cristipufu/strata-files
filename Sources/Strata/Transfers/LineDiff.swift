import Foundation

/// Unified line diff (Myers' O(ND) algorithm) for previewing small text files side by side in the conflict sheet.
package nonisolated enum LineDiff {
    package enum Kind: Sendable { case same, added, removed }

    package struct Line: Sendable {
        package let kind: Kind
        package let text: String
        package let oldNumber: Int?
        package let newNumber: Int?
    }

    package enum Row: Sendable {
        case line(Line)
        /// Unchanged lines left out between hunks.
        case gap(Int)
    }

    package struct Result: Sendable {
        package let rows: [Row]
        package let added: Int
        package let removed: Int
        package var isIdentical: Bool { added == 0 && removed == 0 }

        package init(rows: [Row], added: Int, removed: Int) {
            self.rows = rows
            self.added = added
            self.removed = removed
        }
    }

    /// Diff of `old` → `new` with `context` unchanged lines around each change. Nil when the inputs are too large
    /// or too different to show usefully.
    package static func compute(old: String, new: String, context: Int = 3, maxLines: Int = 50_000,
                        maxEdits: Int = 2_000) -> Result? {
        let a = lines(old), b = lines(new)
        guard a.count + b.count <= maxLines else { return nil }
        // Compare integers, not strings.
        var ids: [String: Int] = [:]
        func id(_ line: String) -> Int {
            if let known = ids[line] { return known }
            ids[line] = ids.count
            return ids.count - 1
        }
        let x = a.map(id)
        let y = b.map(id)
        guard let script = edits(x, y, maxEdits: maxEdits) else { return nil }

        var lines: [Line] = []
        lines.reserveCapacity(script.count)
        var i = 0, j = 0
        for kind in script {
            switch kind {
            case .same:
                lines.append(Line(kind: .same, text: a[i], oldNumber: i + 1, newNumber: j + 1))
                i += 1
                j += 1
            case .removed:
                lines.append(Line(kind: .removed, text: a[i], oldNumber: i + 1, newNumber: nil))
                i += 1
            case .added:
                lines.append(Line(kind: .added, text: b[j], oldNumber: nil, newNumber: j + 1))
                j += 1
            }
        }
        let added = lines.count { $0.kind == .added }
        let removed = lines.count { $0.kind == .removed }
        return Result(rows: hunks(lines, context: context), added: added, removed: removed)
    }

    package static func lines(_ text: String) -> [String] {
        var result = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
        }
        if result.last == "" { result.removeLast() }
        return result
    }

    /// Keeps changed lines and `context` lines around them; collapses the rest into gaps.
    private static func hunks(_ lines: [Line], context: Int) -> [Row] {
        guard lines.contains(where: { $0.kind != .same }) else { return [] }
        var keep = [Bool](repeating: false, count: lines.count)
        for (index, line) in lines.enumerated() where line.kind != .same {
            for k in max(0, index - context)...min(lines.count - 1, index + context) { keep[k] = true }
        }
        var rows: [Row] = []
        var skipped = 0
        for (index, line) in lines.enumerated() {
            if keep[index] {
                if skipped > 0 { rows.append(.gap(skipped)) }
                skipped = 0
                rows.append(.line(line))
            } else {
                skipped += 1
            }
        }
        if skipped > 0 { rows.append(.gap(skipped)) }
        return rows
    }

    /// Shortest edit script from `a` to `b`. Common prefix and suffix are peeled off first, so typical edits to
    /// large files stay cheap; the trace keeps only the 2d+3 live diagonals per step (O(D²) memory).
    package static func edits(_ a: [Int], _ b: [Int], maxEdits: Int) -> [Kind]? {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let a = Array(a[prefix..<(a.count - suffix)])
        let b = Array(b[prefix..<(b.count - suffix)])
        let head = [Kind](repeating: .same, count: prefix)
        let tail = [Kind](repeating: .same, count: suffix)
        if a.isEmpty { return head + [Kind](repeating: .added, count: b.count) + tail }
        if b.isEmpty { return head + [Kind](repeating: .removed, count: a.count) + tail }

        let n = a.count, m = b.count
        let limit = min(n + m, maxEdits)
        let offset = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        var trace: [[Int]] = []
        var found = false
        search: for d in 0...limit {
            trace.append(Array(v[(offset - d - 1)...(offset + d + 1)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n, y >= m {
                    found = true
                    break search
                }
            }
        }
        guard found else { return nil }

        var script: [Kind] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let saved = trace[d]
            func at(_ k: Int) -> Int { saved[k + d + 1] }
            let k = x - y
            let previousK = (k == -d || (k != d && at(k - 1) < at(k + 1))) ? k + 1 : k - 1
            let previousX = d == 0 ? 0 : at(previousK)
            let previousY = previousX - previousK
            while x > previousX, y > previousY {
                script.append(.same)
                x -= 1
                y -= 1
            }
            if d > 0 {
                if x == previousX {
                    script.append(.added)
                    y -= 1
                } else {
                    script.append(.removed)
                    x -= 1
                }
            }
            x = previousX
            y = previousY
        }
        return head + script.reversed() + tail
    }
}
