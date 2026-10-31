import Foundation

package nonisolated enum RealPath {
    /// Where `url` really is, its links followed: each one looked up on its disk, so away from the main thread.
    @concurrent package static func of(_ url: URL) async -> URL { url.resolvingSymlinksInPath() }
}
