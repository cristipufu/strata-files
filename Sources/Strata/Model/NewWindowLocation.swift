import Foundation

package nonisolated enum NewWindowLocation: String, CaseIterable, Sendable {
    case lastVisited, home, custom

    /// New windows may inherit the front window; the first window uses the last saved local folder.
    package func folder(custom: URL?, last: URL?, current: URL? = nil, home: URL,
                available: (URL) -> Bool = Self.isAvailable) -> URL {
        let candidate: URL?
        switch self {
        case .home: return home
        case .lastVisited: candidate = current ?? last
        case .custom: candidate = custom
        }
        guard let candidate, candidate.isFileURL, available(candidate) else { return home }
        return candidate
    }

    package static func isAvailable(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue && FileManager.default.isReadableFile(atPath: url.path)
            && FileManager.default.isExecutableFile(atPath: url.path)
    }
}
