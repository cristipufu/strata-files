import Foundation
import UniformTypeIdentifiers

/// A snapshot of one directory entry, read off the main thread.
package nonisolated struct FileEntry: Sendable, Hashable {
    package let url: URL
    package let name: String
    /// Finder's localized label. Names used to rename, identify extensions or form paths stay in `name` and `url`.
    package let displayName: String
    package let isDirectory: Bool
    package let isPackage: Bool
    package let isHidden: Bool
    package let isSymlink: Bool
    package let isVolume: Bool
    package let size: Int64?
    package let modified: Date?
    package let created: Date?
    package let added: Date?
    package let kind: String
    package let contentType: UTType?

    /// A folder you navigate into (packages such as apps open instead).
    package var isFolder: Bool { isDirectory && !isPackage }

    /// The folder opening `url` should show. A symlink or Finder alias to a folder opens that folder:
    /// listing the link itself fails, because the link is not a directory.
    package static func openedFolder(_ url: URL) -> URL {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey]) else { return url }
        if values.isSymbolicLink == true {
            let resolved = url.resolvingSymlinksInPath()
            if resolved.standardizedFileURL.path != url.standardizedFileURL.path, isNavigableFolder(resolved) {
                return resolved
            }
        } else if values.isAliasFile == true, let resolved = try? URL(resolvingAliasFileAt: url), isNavigableFolder(resolved) {
            return resolved
        }
        return url
    }

    /// A directory the browser lists. Apps and other packages open instead.
    package static func isNavigableFolder(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return values.isDirectory == true && values.isPackage != true
    }

    /// macOS calls `.ts` an MPEG-2 stream and has no names for many source files; developers expect these.
    package static let developerKinds: [String: String] = [
        "ts": String(localized: "TypeScript source", comment: "Kind of file"),
        "tsx": String(localized: "TypeScript JSX source", comment: "Kind of file"),
        "jsx": String(localized: "JavaScript JSX source", comment: "Kind of file"),
        "mts": String(localized: "TypeScript source", comment: "Kind of file"),
        "rs": String(localized: "Rust source", comment: "Kind of file"),
        "go": String(localized: "Go source", comment: "Kind of file"),
        "kt": String(localized: "Kotlin source", comment: "Kind of file"),
        "kts": String(localized: "Kotlin script", comment: "Kind of file"),
        "gd": String(localized: "GDScript source", comment: "Kind of file"),
        "dart": String(localized: "Dart source", comment: "Kind of file"),
        "vue": String(localized: "Vue component", comment: "Kind of file"),
        "svelte": String(localized: "Svelte component", comment: "Kind of file"),
        "toml": String(localized: "TOML document", comment: "Kind of file"),
        "lock": String(localized: "Lockfile", comment: "Kind of file: a package manager’s lock file"),
        "tf": String(localized: "Terraform configuration", comment: "Kind of file"),
        "proto": String(localized: "Protocol Buffers definition", comment: "Kind of file"),
    ]

    /// The Kind shown everywhere (list, inspector, conflict sheet, Space, AI plans): the system's description, except
    /// for source files macOS names wrong or not at all and the documents it has no type for (`KnownDocument`, by the
    /// item's own `type`). `.ts` is ambiguous: small ones are TypeScript, large ones are almost always MPEG
    /// transport-stream video.
    package static func kind(extension ext: String, isDirectory: Bool, isPackage: Bool, size: Int64?, system: String?,
                     type: UTType?) -> String {
        let ext = ext.lowercased()
        if !isDirectory, let document = KnownDocument.kind(extension: ext, type: type) { return document.name }
        if !isDirectory, let developer = developerKinds[ext], !(ext == "ts" || ext == "mts") || (size ?? 0) < 4_000_000 {
            return developer
        }
        return system ?? (isDirectory && !isPackage ? String(localized: "Folder", comment: "Kind of item")
                                                    : String(localized: "Document", comment: "Kind of item"))
    }

    package static let resourceKeys: [URLResourceKey] = [
        .nameKey, .localizedNameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey, .addedToDirectoryDateKey, .localizedTypeDescriptionKey,
        .contentTypeKey, .isVolumeKey,
    ]

    package init(url: URL, name: String, isDirectory: Bool, isPackage: Bool, isHidden: Bool, isSymlink: Bool, isVolume: Bool,
         size: Int64?, modified: Date?, created: Date?, added: Date?, kind: String, contentType: UTType?, displayName: String? = nil) {
        self.url = url
        self.name = name
        self.displayName = displayName ?? name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isHidden = isHidden
        self.isSymlink = isSymlink
        self.isVolume = isVolume
        self.size = size
        self.modified = modified
        self.created = created
        self.added = added
        self.kind = kind
        self.contentType = contentType
    }

    package init(url: URL, values: URLResourceValues) {
        self.url = url
        name = values.name ?? url.lastPathComponent
        displayName = values.localizedName ?? name
        isSymlink = values.isSymbolicLink ?? false
        isVolume = values.isVolume ?? false
        var isDirectory = values.isDirectory ?? false
        var isPackage = values.isPackage ?? false
        if isSymlink, let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) {
            isDirectory = target.isDirectory ?? false
            isPackage = target.isPackage ?? false
        }
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        isHidden = values.isHidden ?? name.hasPrefix(".")
        size = isDirectory ? nil : values.fileSize.map(Int64.init)
        modified = values.contentModificationDate
        created = values.creationDate
        added = values.addedToDirectoryDate
        kind = Self.kind(extension: url.pathExtension, isDirectory: isDirectory, isPackage: isPackage,
                         size: values.fileSize.map(Int64.init), system: values.localizedTypeDescription,
                         type: values.contentType)
        contentType = values.contentType
    }

    /// The same item described as another kind.
    package func with(kind: String? = nil, displayName: String? = nil) -> FileEntry {
        FileEntry(url: url, name: name, isDirectory: isDirectory, isPackage: isPackage, isHidden: isHidden, isSymlink: isSymlink,
                  isVolume: isVolume, size: size, modified: modified, created: created, added: added, kind: kind ?? self.kind,
                  contentType: contentType, displayName: displayName ?? self.displayName)
    }

    /// Filtering accepts both the name on disk and the visible label, without highlighting offsets from another name.
    package func nameMatch(_ query: String) -> Fuzzy.Match? {
        if let match = Fuzzy.match(query, displayName) { return match }
        return Fuzzy.match(query, name).map { Fuzzy.Match(score: $0.score, indices: []) }
    }

    /// Index hits keep disk work out of the main thread. Resolve folder and bundle labels once results arrive.
    @concurrent package static func localizedNames(_ entries: [Self]) async -> [Self] {
        entries.map { entry in
            guard !Task.isCancelled, entry.isDirectory || entry.isPackage,
                  let values = try? entry.url.resourceValues(forKeys: [.localizedNameKey]), let name = values.localizedName else { return entry }
            return entry.with(displayName: name)
        }
    }

    package init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys)) else { return nil }
        self.init(url: url, values: values)
    }

    @concurrent package static func read(_ url: URL) async -> FileEntry? {
        FileEntry(url: url)
    }
}

package nonisolated enum DirectoryLoader {
    /// A preview reads one level and stops before allocating an unbounded URL array. Expanded children have their
    /// own request; hidden files, Applications merging and provider routing match the main browser.
    @concurrent
    package static func loadPreview(_ directory: URL, showHidden: Bool, applications: ApplicationsFolders,
                            copies: CopyProviders, limit: Int) async throws -> [FileEntry] {
        try Task.checkCancellation()
        if copies.contains(directory) { try await copies.previewFolder(directory) }
        try Task.checkCancellation()
        return try previewEntries(directory, showHidden: showHidden, applications: applications, limit: limit)
    }

    private static func previewEntries(_ directory: URL, showHidden: Bool, applications: ApplicationsFolders,
                                       limit: Int) throws -> [FileEntry] {
        let directory = FileEntry.openedFolder(directory)
        let options: FileManager.DirectoryEnumerationOptions = showHidden
            ? [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
            : [.skipsSubdirectoryDescendants, .skipsPackageDescendants, .skipsHiddenFiles]
        var entries: [FileEntry] = []
        var examined = 0
        for (index, folder) in applications.directories(for: directory).enumerated() {
            var failure: Error?
            guard let iterator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: FileEntry.resourceKeys,
                                                               options: options, errorHandler: { _, error in failure = error; return false }) else {
                if index == 0 { throw CocoaError(.fileReadNoPermission) }
                continue
            }
            for case let url as URL in iterator {
                try Task.checkCancellation()
                guard examined < limit else { throw CocoaError(.fileReadTooLarge) }
                examined += 1
                if let entry = FileEntry(url: url) { entries.append(entry) }
            }
            if let failure, index == 0 { throw failure }
        }
        return entries
    }

    @concurrent
    package static func load(_ directory: URL, showHidden: Bool, applications: ApplicationsFolders = .standard,
                     copies: CopyProviders) async throws -> [FileEntry] {
        // A container's files: list the folder from the container first (every view loads folders here).
        if copies.contains(directory) { await copies.refresh(directory) }
        // Follow a symlink or Finder alias. FileManager will not list the link itself.
        let directory = FileEntry.openedFolder(directory)
        let isContainersFolder = copies.containerCopies.engineFolder(directory) != nil
        let keys = FileEntry.resourceKeys
        let urls = try applications.contents(of: directory, keys: keys, options: showHidden ? [] : [.skipsHiddenFiles])
        let keySet = Set(keys)
        let containerKind = String(localized: "Container", comment: "Kind of item: a Docker container's files")
        let stackKind = String(localized: "Stack", comment: "Kind of item: a Compose project's containers")
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keySet) else { return nil }
            let entry = FileEntry(url: url, values: values)
            if copies.containerCopies.isContainerTop(url) { return entry.with(kind: containerKind) }
            if isContainersFolder, copies.containerCopies.isStack(url) { return entry.with(kind: stackKind) }
            return entry
        }
    }
}
