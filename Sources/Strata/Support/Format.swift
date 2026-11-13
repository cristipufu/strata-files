import Foundation

nonisolated package extension Int64 {
    func saturatingAdd(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other < 0 ? .min : .max) : sum
    }

    func saturatingMultiply(_ other: Int64) -> Int64 {
        let (product, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? ((self < 0) == (other < 0) ? .max : .min) : product
    }
}

nonisolated package extension UInt64 {
    func saturatingAdd(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}

nonisolated package extension Sequence where Element == Int64 {
    /// The total, stopping at Int64.max rather than overflowing (sizes reported by another machine can be absurd).
    var saturatingSum: Int64 {
        reduce(0) { $0.saturatingAdd($1) }
    }
}

package enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    package static func bytes(_ n: Int64) -> String { byteFormatter.string(fromByteCount: n) }
    package static func date(_ d: Date?) -> String { d.map(shortDate.string(from:)) ?? "—" }
    package static func longDate(_ d: Date?) -> String { d.map(longDate.string(from:)) ?? "—" }

    package static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n.formatted()) \(n == 1 ? singular : plural)"
    }

    /// Path with the home folder shortened to `~`.
    package static func tildePath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
