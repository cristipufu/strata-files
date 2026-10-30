import Foundation

/// Subsequence matching with fzf-like scoring: consecutive runs, word starts and prefixes rank higher.
nonisolated package enum Fuzzy {
    package struct Match {
        package let score: Int
        /// Character offsets in the candidate that matched, for highlighting.
        package let indices: [Int]

        package init(score: Int, indices: [Int]) {
            self.score = score
            self.indices = indices
        }
    }

    package static func match(_ query: String, _ candidate: String) -> Match? {
        let q = query.lowercased().map { String($0) }
        let chars = Array(candidate)
        let lower = chars.map { $0.lowercased() }
        guard !q.isEmpty, q.count <= lower.count else { return nil }

        var best: Match?
        // Try every start position of the first query character and keep the best-scoring greedy path.
        for start in lower.indices where lower[start] == q[0] {
            var indices = [start]
            var cursor = start + 1
            var ok = true
            for qc in q.dropFirst() {
                guard let next = (cursor..<lower.count).first(where: { lower[$0] == qc }) else { ok = false; break }
                indices.append(next)
                cursor = next + 1
            }
            guard ok else { break }
            let s = score(indices, chars, query: q, lower: lower)
            if best == nil || s > best!.score { best = Match(score: s, indices: indices) }
        }
        return best
    }

    private static func score(_ indices: [Int], _ chars: [Character], query: [String], lower: [String]) -> Int {
        var score = 0
        var previous = -2
        for i in indices {
            score += 1
            if i == previous + 1 { score += 6 }
            if isWordStart(i, chars) { score += 8 }
            if previous >= 0, i > previous + 1 { score -= min(i - previous - 1, 6) }
            previous = i
        }
        if indices.first == 0 { score += 10 }
        if lower.starts(with: query) { score += 25 }
        score -= chars.count / 10
        return score
    }

    private static func isWordStart(_ i: Int, _ chars: [Character]) -> Bool {
        if i == 0 { return true }
        let prev = chars[i - 1], cur = chars[i]
        if " _-./()[]".contains(prev) { return true }
        if prev.isLowercase && cur.isUppercase { return true }
        if !prev.isNumber && cur.isNumber { return true }
        return false
    }
}
