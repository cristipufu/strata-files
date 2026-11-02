import Foundation

/// How a path is spelled, worked out from the string alone: never asking the disk, so it's fit for the main thread and
/// answers the same whether or not the item still exists. macOS fixes /var, /tmp and /etc as links into /private, so
/// those two spellings name one place.
package nonisolated enum PathSpelling {
    private static let aliases = ["/var", "/tmp", "/etc"]

    /// As `standardizedFileURL` spells it (no `.`, `..` or doubled slash; /private/var as /var), without the stat that
    /// makes its answer depend on whether the item exists, or the links it resolves on the way to a `..`.
    package static func short(_ url: URL) -> String { short(lexicalPath(url)) }

    /// `url`'s absolute path, decoded, with each `.`, `..` and doubled slash taken out by its letters.
    private static func lexicalPath(_ url: URL) -> String {
        var parts: [Substring] = []
        for part in url.absoluteURL.path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

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

extension URL {
    /// The file URL as `standardizedFileURL` spells it (`PathSpelling.short`, its directory hint kept), without asking
    /// the disk: `standardizedFileURL` stats a /private path and resolves the links on the way to a `..`, so its answer
    /// can wait on a disk, and changes once an item is gone.
    package nonisolated var lexicallyStandardized: URL {
        guard isFileURL, !path.isEmpty else { return self }
        return URL(filePath: PathSpelling.short(self), directoryHint: hasDirectoryPath ? .isDirectory : .notDirectory)
    }
}
