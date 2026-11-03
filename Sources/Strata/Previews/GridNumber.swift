import Foundation

nonisolated struct GridNumber: Comparable, Sendable {
    private static let inputByteLimit = 128
    private let negative: Bool
    private let digits: [UInt8]
    private let magnitude: Int

    static func parse(_ value: String) -> Self? {
        guard value.utf8.count <= inputByteLimit else { return nil }
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let negative = text.first == "-"
        if text.first == "-" || text.first == "+" { text.removeFirst() }
        if let first = text.first, "$€£¥".contains(first) { text.removeFirst() }
        let percent = text.last == "%"
        if percent { text.removeLast() }
        text = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "_", with: "")
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "e" || $0 == "E" })
        guard parts.count <= 2, let first = parts.first else { return nil }
        let exponent: Int
        if parts.count == 2 {
            var suffix = parts[1]
            if suffix.first == "+" || suffix.first == "-" { suffix = suffix.dropFirst() }
            guard !suffix.isEmpty, suffix.utf8.allSatisfy({ (48...57).contains($0) }), let parsed = Int(parts[1]) else { return nil }
            exponent = parsed
        } else { exponent = 0 }
        return fromMantissa(normalize(String(first)), negative: negative, exponent: exponent, percent: percent)
    }

    private static func normalize(_ mantissa: String) -> String {
        guard mantissa.contains(",") else { return mantissa }
        if let dot = mantissa.lastIndex(of: "."), let comma = mantissa.lastIndex(of: ",") {
            return dot > comma ? mantissa.replacingOccurrences(of: ",", with: "")
                : mantissa.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        }
        let groups = mantissa.split(separator: ",", omittingEmptySubsequences: false)
        let grouped = groups.count > 1 && !(groups.first?.isEmpty ?? true) && groups.dropFirst().allSatisfy { $0.count == 3 }
        return mantissa.replacingOccurrences(of: ",", with: grouped ? "" : ".")
    }

    private static func fromMantissa(_ text: String, negative: Bool, exponent: Int, percent: Bool) -> Self? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.contains(where: { !$0.isEmpty }),
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let raw = parts.joined().utf8
        let digits = Array(raw.drop(while: { $0 == 48 }))
        if digits.isEmpty { return Self(negative: false, digits: [], magnitude: 0) }
        let fraction = parts.count == 2 ? parts[1].utf8.count : 0
        let (base, overflow) = exponent.subtractingReportingOverflow(fraction + (percent ? 2 : 0))
        let (magnitude, shifted) = base.addingReportingOverflow(digits.count)
        guard !overflow, !shifted else { return nil }
        return Self(negative: negative, digits: digits, magnitude: magnitude)
    }

    static func == (a: Self, b: Self) -> Bool { !a.isLess(than: b) && !b.isLess(than: a) }
    static func < (a: Self, b: Self) -> Bool { a.isLess(than: b) }

    private func isLess(than other: Self) -> Bool {
        if negative != other.negative { return negative }
        if digits.isEmpty || other.digits.isEmpty {
            return negative ? !digits.isEmpty && other.digits.isEmpty : digits.isEmpty && !other.digits.isEmpty
        }
        if magnitude != other.magnitude { return negative ? magnitude > other.magnitude : magnitude < other.magnitude }
        for index in 0..<max(digits.count, other.digits.count) {
            let a = index < digits.count ? digits[index] : 48
            let b = index < other.digits.count ? other.digits[index] : 48
            if a != b { return negative ? a > b : a < b }
        }
        return false
    }
}
