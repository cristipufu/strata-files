import Foundation
import StrataSupport

package nonisolated struct CloudFolder: Equatable, Sendable {
    package let url: URL
    package let title: String
}

/// The sync service behind a cloud folder, told from the folder's path alone.
package nonisolated enum CloudProvider: Equatable, Sendable {
    case dropbox, googleDrive, oneDrive, box, iCloud, other

    /// File Provider accounts are named after their app: `Dropbox`, `GoogleDrive-you@example.com`, `OneDrive-Personal`.
    package init(accountFolder name: String) {
        let name = name.lowercased()
        if name.hasPrefix("dropbox") { self = .dropbox }
        else if name.hasPrefix("googledrive") { self = .googleDrive }
        else if name.hasPrefix("onedrive") { self = .oneDrive }
        else if name.hasPrefix("box") { self = .box }
        else { self = .other }
    }
}

/// Accounts exposed by the installed sync apps, discovered without launching them or contacting their servers.
package nonisolated enum CloudFolders {
    /// The cloud account `url` is in, or is: an account folder in Library/CloudStorage, or iCloud Drive. By path alone,
    /// so it never waits on a disk or a sync app.
    package static func cloudRoot(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> (root: URL, provider: CloudProvider)? {
        if let root = providerRoot(for: url, home: home) {
            return (root, CloudProvider(accountFolder: root.lastPathComponent))
        }
        let iCloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        return contains(url, in: iCloud) ? (iCloud, .iCloud) : nil
    }

    package static func contains(_ url: URL, in root: URL) -> Bool {
        guard url.isFileURL, root.isFileURL else { return false }
        let path = PathSpelling.system(PathSpelling.short(url))
        let root = PathSpelling.system(PathSpelling.short(root))
        return path == root || path.hasPrefix(root + "/")
    }

    package static func providerRoot(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard url.isFileURL, home.isFileURL else { return nil }
        let root = URL(fileURLWithPath: PathSpelling.system(home.appending(path: "Library/CloudStorage").lexicallyStandardized.path))
        let path = PathSpelling.system(PathSpelling.short(url))
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
