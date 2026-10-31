import Foundation

/// How a path is spelled, worked out from the string alone: never asking the disk, so it's fit for the main thread and
/// answers the same whether or not the item still exists. macOS fixes /var, /tmp and /etc as links into /private, so
/// those two spellings name one place.
package nonisolated enum PathSpelling {
    private static let aliases = ["/var", "/tmp", "/etc"]

    /// As `standardizedFileURL` spells it (no `.`, `..` or doubled slash; /private/var as /var), without the stat that
    /// makes its answer depend on whether the item exists.
    package static func short(_ url: URL) -> String { short(url.standardized.path) }

    package static func short(_ path: String) -> String {
        for alias in aliases where path == "/private" + alias || path.hasPrefix("/private" + alias + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    /// As the kernel spells it (/var as /private/var): what `realpath` and an opened folder report.
    package static func system(_ path: String) -> String {
        for alias in aliases where path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }
}
