import AppKit

package nonisolated struct Place: Sendable, Equatable {
    package let title: String
    package let url: URL
    package let symbol: String
    /// A removable, ejectable or network volume.
    package var isEjectable = false
    /// A network share's address, which mounts it again.
    package var remountAddress: URL?

    package init(title: String, url: URL, symbol: String, isEjectable: Bool = false, remountAddress: URL? = nil) {
        self.title = title
        self.url = url
        self.symbol = symbol
        self.isEjectable = isEjectable
        self.remountAddress = remountAddress
    }
}

package enum Places {
    package static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Unmounts (and for disks, ejects) the volume at `url` off the main thread; reports a failure in `window`.
    package static func eject(_ url: URL, from window: NSWindow?) {
        Task.detached {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                let name = FileManager.default.displayName(atPath: url.path)
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
    package static func favorites(preferences: Prefs, checks: PlaceChecks) -> [Place] {
        favorites(preferences: preferences, isFolder: { checks.isFolder($0) }, name: checks.name)
    }

    /// A favorite not yet read counts as there; one of the default places only once it's been found.
    private static func favorites(preferences: Prefs, isFolder: (String) -> Bool?, name: (URL) -> String) -> [Place] {
        let defaults = defaultFavorites(isFolder: isFolder, name: name)
        guard let paths = preferences.favoritePaths else { return defaults }
        return paths.compactMap { path in
            guard isFolder(path) != false else { return nil }
            let url = URL(filePath: path, directoryHint: .isDirectory)
            return defaults.first { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }
                ?? Place(title: name(url), url: url, symbol: "folder")
        }
    }

    /// Adds folders to the favorites (at `index` in the sidebar's list, else at the end); ones already there move
    /// instead. Which of `urls` are folders is read away from the main thread. The rest of your list is kept as it's
    /// saved, with any favorite `checks` last found missing (a disk that may be back).
    package static func addFavorites(_ urls: [URL], at index: Int? = nil, preferences: Prefs, checks: PlaceChecks) async {
        let folders = await folders(among: urls.map(\.standardizedFileURL))
        guard !folders.isEmpty else { return }
        let paths = Set(folders.map(\.path))
        let shown = favorites(preferences: preferences, checks: checks).map(\.url.standardizedFileURL)
        var saved = savedFavorites(preferences: preferences, shown: shown).filter { !paths.contains($0.path) }
        // Before the first favorite shown at `index` or after it that stays where it is.
        let anchor = index.flatMap { index in shown.dropFirst(max(0, index)).first { !paths.contains($0.path) } }
        // By path: a default place and the same folder saved by you can differ in a trailing slash.
        let at = anchor.flatMap { anchor in saved.firstIndex { $0.path == anchor.path } } ?? saved.count
        saved.insert(contentsOf: folders, at: at)
        preferences.favoritePaths = saved.map(\.path)
    }

    package static func removeFavorite(_ url: URL, preferences: Prefs, checks: PlaceChecks) {
        let path = url.standardizedFileURL.path
        let shown = favorites(preferences: preferences, checks: checks).map(\.url.standardizedFileURL)
        preferences.favoritePaths = savedFavorites(preferences: preferences, shown: shown).map(\.path).filter { $0 != path }
    }

    /// Your own list, or the defaults as `shown` until you've changed it.
    private static func savedFavorites(preferences: Prefs, shown: [URL]) -> [URL] {
        preferences.favoritePaths.map { $0.map { URL(filePath: $0, directoryHint: .isDirectory).standardizedFileURL } } ?? shown
    }

    nonisolated private static func folders(among urls: [URL]) async -> [URL] {
        await OwnThread.run {
            urls.filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
        }
    }

    private static let standardPlaces: [(path: String, symbol: String)] = [
        ("", "house"), ("Desktop", "menubar.dock.rectangle"), ("Documents", "doc"), ("Downloads", "arrow.down.circle"),
    ]
    /// Common homes for source code get a spot without any setup.
    private static let codeFolders = ["Developer", "Projects", "Code", "code", "src", "repos", "Documents/GitHub", "GitHub"]
    private static var iCloud: URL { home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs") }
    private static let applications = URL(fileURLWithPath: "/Applications")

    /// Every folder the default favorites are made of, or may be.
    package static var defaultCandidates: [URL] {
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

    /// A folder's name as Finder shows it ("Trash" for `~/.Trash`; an archive opened as a folder goes by its file name),
    /// with Finder's names as `names` last read them: the folder on show mustn't wait on a disk.
    package static func displayName(_ url: URL, copies: CopyProviders, names: FolderNames) -> String {
        ownName(url, copies: copies) ?? names.name(url)
    }

    /// The same, with Finder's names as `checks` last read them, for lists that mustn't wait on a disk.
    package static func displayName(_ url: URL, copies: CopyProviders, checks: PlaceChecks) -> String {
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

    /// The addresses network shares at `volumes` mount from. Each is asked of a system service that a share which
    /// stopped answering can hold up, so only shares are asked, and on a thread of their own.
    package nonisolated static func remountAddresses(_ volumes: [URL]) async -> [URL: URL] {
        await OwnThread.run {
            var found: [URL: URL] = [:]
            for url in volumes {
                found[url] = (try? url.resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting
            }
            return found
        }
    }

    /// The volumes mounted, read now: lists use `PlaceChecks`' last read.
    package nonisolated static func volumes() -> [Place] {
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
