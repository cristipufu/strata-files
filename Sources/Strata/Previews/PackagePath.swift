import Foundation

nonisolated enum PackagePath {
    static func resolve(_ reference: String, relativeTo base: [String]) throws -> [String] {
        guard reference.utf8.count <= 4096, let uri = URLComponents(string: reference), uri.scheme == nil, uri.host == nil,
              uri.query == nil, !uri.percentEncodedPath.isEmpty else { throw PreviewError.unsupported }
        let rooted = uri.percentEncodedPath.hasPrefix("/")
        var parts = rooted ? [] : base
        let path = rooted ? String(uri.percentEncodedPath.dropFirst()) : uri.percentEncodedPath
        for encoded in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard let part = String(encoded).removingPercentEncoding, !part.isEmpty,
                  !part.unicodeScalars.contains(where: { $0 == "/" || $0 == "\\" || CharacterSet.controlCharacters.contains($0) }),
                  part.utf8.count <= 255 else { throw PreviewError.unsupported }
            if part == "." { continue }
            if part == ".." { guard !parts.isEmpty else { throw PreviewError.unsupported }; parts.removeLast() }
            else { parts.append(part) }
        }
        guard !parts.isEmpty, parts.count <= 16 else { throw PreviewError.unsupported }
        return parts
    }
}
