import Foundation

package nonisolated struct CloudFolder: Equatable, Sendable {
    package let url: URL
    package let title: String
}

/// Accounts exposed by the installed sync apps, discovered without launching them or contacting their servers.
package nonisolated enum CloudFolders {
    package static func contains(_ url: URL, in root: URL) -> Bool {
        guard url.isFileURL, root.isFileURL else { return false }
        let path = ChosenFile.systemSpelling(url.standardizedFileURL.path)
        let root = ChosenFile.systemSpelling(root.standardizedFileURL.path)
        return path == root || path.hasPrefix(root + "/")
    }

    package static func providerRoot(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard url.isFileURL, home.isFileURL else { return nil }
        let root = URL(fileURLWithPath: ChosenFile.systemSpelling(home.appending(path: "Library/CloudStorage").standardizedFileURL.path))
        let path = ChosenFile.systemSpelling(url.standardizedFileURL.path)
        guard path.hasPrefix(root.path + "/"),
              let account = path.dropFirst(root.path.count + 1).split(separator: "/").first else { return nil }
        return root.appending(path: String(account), directoryHint: .isDirectory)
    }

    @concurrent package static func discover() async -> [CloudFolder] {
        discover(in: FileManager.default.homeDirectoryForCurrentUser)
    }

    package static func discover(in home: URL) -> [CloudFolder] {
        guard home.isFileURL else { return [] }
        let fm = FileManager.default
        var urls: [URL] = []
        let iCloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        if let fd = try? ChosenFile.openDirectory(iCloud.path) {
            close(fd)
            urls.append(iCloud)
        }
        let root = home.appending(path: "Library/CloudStorage")
        if let fd = try? ChosenFile.openDirectory(root.path) {
            defer { close(fd) }
            // Only physical account folders at this level; never follow a link supplied by a different folder.
            for name in (try? ChosenFile.names(in: fd)) ?? [] where !name.hasPrefix(".") {
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
                urls.append(root.appending(path: name, directoryHint: .isDirectory))
            }
        }
        return urls.map { CloudFolder(url: $0, title: fm.displayName(atPath: $0.path)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
