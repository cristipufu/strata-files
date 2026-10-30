import AppKit

nonisolated struct Place: Sendable, Equatable {
    let title: String
    let url: URL
    let symbol: String
    /// A removable, ejectable or network volume.
    var isEjectable = false
}

enum Places {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Unmounts (and for disks, ejects) the volume at `url` off the main thread; reports a failure in `window`.
    static func eject(_ url: URL, from window: NSWindow?) {
        let name = FileManager.default.displayName(atPath: url.path)
        Task.detached {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "“\(name)” couldn’t be ejected")
                    alert.informativeText = String(localized: "Close any files from it that are open in other apps, then try again. (\(error.localizedDescription))")
                    if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
                }
            }
        }
    }


    /// The sidebar's favorites: your own list once you've added, removed or reordered any, else the defaults; as
    /// `checks` last read them, for lists that mustn't wait on a disk.
    static func favorites(preferences: Prefs, checks: PlaceChecks) -> [Place] {
        favorites(preferences: preferences, isFolder: { checks.isFolder($0) }, name: checks.name)
    }

    /// The favorites read from disk now, for changing them.
    static func favorites(preferences: Prefs) -> [Place] {
        favorites(preferences: preferences, isFolder: { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }, name: { FileManager.default.displayName(atPath: $0.path) })
    }

    /// A favorite not yet read counts as there; one of the default places only once it's been found.
    private static func favorites(preferences: Prefs, isFolder: (String) -> Bool?, name: (URL) -> String) -> [Place] {
        let defaults = defaultFavorites(isFolder: isFolder, name: name)
        guard let paths = preferences.favoritePaths else { return defaults }
        return paths.compactMap { path in
            guard isFolder(path) != false else { return nil }
            let url = URL(fileURLWithPath: path)
            return defaults.first { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }
                ?? Place(title: name(url), url: url, symbol: "folder")
        }
    }

    /// Adds folders to the favorites (at `index`, else at the end); ones already there move instead.
    static func addFavorites(_ urls: [URL], at index: Int? = nil, preferences: Prefs) {
        let folders = urls.map(\.standardizedFileURL).filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        guard !folders.isEmpty else { return }
        let paths = Set(folders.map(\.path))
        var current = favorites(preferences: preferences).map(\.url.standardizedFileURL)
        let before = current.prefix(min(index ?? current.count, current.count)).filter { paths.contains($0.path) }.count
        current.removeAll { paths.contains($0.path) }
        let at = min(max(0, (index ?? current.count + before) - before), current.count)
        current.insert(contentsOf: folders, at: at)
        preferences.favoritePaths = current.map(\.path)
    }

    static func removeFavorite(_ url: URL, preferences: Prefs) {
        let path = url.standardizedFileURL.path
        preferences.favoritePaths = favorites(preferences: preferences).map(\.url.standardizedFileURL.path).filter { $0 != path }
    }

    private static let standardPlaces: [(path: String, symbol: String)] = [
        ("", "house"), ("Desktop", "menubar.dock.rectangle"), ("Documents", "doc"), ("Downloads", "arrow.down.circle"),
    ]
    /// Common homes for source code get a spot without any setup.
    private static let codeFolders = ["Developer", "Projects", "Code", "code", "src", "repos", "Documents/GitHub", "GitHub"]
    private static var iCloud: URL { home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs") }
    private static let applications = URL(fileURLWithPath: "/Applications")

    /// Every folder the default favorites are made of, or may be.
    static var defaultCandidates: [URL] {
        standardPlaces.map { $0.path.isEmpty ? home : home.appending(path: $0.path) } + [applications, iCloud]
            + codeFolders.map { home.appending(path: $0) }
    }

    private static func defaultFavorites(isFolder: (String) -> Bool?, name: (URL) -> String) -> [Place] {
        // macOS's own names for its folders ("Schreibtisch", "Téléchargements"…), the same as Finder shows.
        var places = standardPlaces.map { place in
            let url = place.path.isEmpty ? home : home.appending(path: place.path)
            return Place(title: name(url), url: url, symbol: place.symbol)
        } + [Place(title: name(applications), url: applications, symbol: "square.grid.2x2")]
        for path in codeFolders {
            let url = home.appending(path: path)
            if isFolder(url.path) == true, !places.contains(where: { $0.url.path.lowercased() == url.path.lowercased() }) {
                places.append(Place(title: url.lastPathComponent, url: url, symbol: "chevron.left.forwardslash.chevron.right"))
            }
        }
        if isFolder(iCloud.path) == true {
            places.append(Place(title: name(iCloud), url: iCloud, symbol: "icloud"))
        }
        return places
    }

    /// A folder's name as Finder shows it ("Trash" for `~/.Trash`; an archive opened as a folder goes by its file name).
    static func displayName(_ url: URL, copies: CopyProviders) -> String {
        ownName(url, copies: copies) ?? FileManager.default.displayName(atPath: url.path)
    }

    /// The same, with Finder's names as `names` last read them, for the folder on show, which mustn't wait on a disk.
    static func displayName(_ url: URL, copies: CopyProviders, names: FolderNames) -> String {
        ownName(url, copies: copies) ?? names.name(url)
    }

    /// The same, with Finder's names as `checks` last read them, for lists that mustn't wait on a disk.
    static func displayName(_ url: URL, copies: CopyProviders, checks: PlaceChecks) -> String {
        ownName(url, copies: copies) ?? checks.name(url)
    }

    /// The names Strata gives places itself.
    private static func ownName(_ url: URL, copies: CopyProviders) -> String? {
        if Trash.isTrash(url) { return String(localized: "Trash", comment: "The Trash folder") }
        if let (archive, top) = ArchiveCache.archive(containing: url), top.standardizedFileURL == url.standardizedFileURL {
            return archive.lastPathComponent
        }
        // The Containers folder; a container's `/` goes by the container's name.
        if copies.containerCopies.engineFolder(url) != nil { return String(localized: "Containers", comment: "Sidebar section title: Docker containers") }
        if let (source, top) = copies.containerCopies.copy(containing: url), top.standardizedFileURL == url.standardizedFileURL {
            return source.name
        }
        // A server's `/` (a bucket's top) goes by the server's name.
        if let (server, top) = copies.remoteCopies.server(containing: url), top.standardizedFileURL == url.standardizedFileURL {
            return server.name
        }
        return nil
    }

    /// The volumes mounted, read now: lists use `PlaceChecks`' last read.
    nonisolated static func volumes() -> [Place] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey,
            .volumeIsBrowsableKey, .volumeIsRootFileSystemKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable ?? true else { return nil }
            let symbol: String
            if v.volumeIsLocal == false {
                symbol = "network"
            } else if v.volumeIsRemovable == true || v.volumeIsEjectable == true {
                symbol = "externaldrive"
            } else {
                symbol = "internaldrive"
            }
            return Place(title: v.volumeLocalizedName ?? url.lastPathComponent, url: url, symbol: symbol,
                         isEjectable: v.volumeIsRootFileSystem != true
                             && (v.volumeIsLocal == false || v.volumeIsRemovable == true || v.volumeIsEjectable == true))
        }
    }
}
