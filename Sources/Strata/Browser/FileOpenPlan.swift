import Foundation
import UniformTypeIdentifiers

nonisolated struct FileOpenPlan: Sendable {
    struct Request: Sendable {
        var urls: [URL]
        let application: URL?
    }

    let requests: [Request]
    let folder: URL?

    static func read(_ files: [FileEntry], folder: URL?, applicationForFile: (URL) -> URL?) -> Self {
        var folder = folder
        var requests: [Request] = []
        var applicationIndices: [URL: Int] = [:]
        for file in files {
            let url = file.url
            // An index hit (search results, Recents) doesn't know whether it's an alias or link.
            if (file.isAlias || !file.isListed), FileEntry.openedFolder(url) != url {
                if folder == nil { folder = url }
                continue
            }
            // Leave links, aliases and app launches to the system. The link or app bundle itself isn't the document
            // to hand to the target app.
            let isLink = file.isAlias || file.isSymlink || (!file.isListed &&
                (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true)
            guard files.count > 1, !isLink, url.pathExtension.lowercased() != "app",
                  file.contentType?.conforms(to: .applicationBundle) != true, let app = applicationForFile(url) else {
                requests.append(Request(urls: [url], application: nil))
                continue
            }
            if let index = applicationIndices[app] {
                requests[index].urls.append(url)
            } else {
                applicationIndices[app] = requests.count
                requests.append(Request(urls: [url], application: app))
            }
        }
        return Self(requests: requests, folder: folder)
    }
}
