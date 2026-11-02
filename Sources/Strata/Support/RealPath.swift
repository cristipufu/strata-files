import Foundation

package nonisolated enum RealPath {
    /// Where `url` really is, its links followed: each one looked up on its disk, so away from the main thread.
    package nonisolated static func of(_ url: URL) async -> URL { await OwnThread.run { url.resolvingSymlinksInPath() } }

    /// Where `path` really is, its links followed (standardized when it doesn't exist): for code already away from the
    /// main thread.
    package nonisolated static func of(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
