import Foundation

package nonisolated enum RealPath {
    /// Where `url` really is, its links followed: each one looked up on its disk, so away from the main thread.
    package nonisolated static func of(_ url: URL) async -> URL { await OwnThread.run { url.resolvingSymlinksInPath() } }
}
