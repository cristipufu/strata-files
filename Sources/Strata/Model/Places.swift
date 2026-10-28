import AppKit

struct Place {
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

    /// Whether `url` is the root of a volume that can be ejected.
    static func isEjectableVolume(_ url: URL) -> Bool {
        volumes().contains { $0.isEjectable && $0.url.standardizedFileURL.path == url.standardizedFileURL.path }
    }

    /// The sidebar's favorites: your own list once you've added, removed or reordered any, else the defaults.
    static func favorites() -> [Place] { favorites(preferences: .shared) }

    static func favorites(preferences: Prefs) -> [Place] {
        guard let paths = preferences.favoritePaths else { return defaultFavorites() }
        let defaults = defaultFavorites()
        return paths.compactMap { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let url = URL(fileURLWithPath: path)
            return defaults.first { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }
                ?? Place(title: FileManager.default.displayName(atPath: path), url: url, symbol: "folder")
        }
    }

    /// Adds folders to the favorites (at `index`, else at the end); ones already there move instead.
    static func addFavorites(_ urls: [URL], at index: Int? = nil, preferences: Prefs = .shared) {
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

    static func removeFavorite(_ url: URL, preferences: Prefs = .shared) {
        let path = url.standardizedFileURL.path
        preferences.favoritePaths = favorites(preferences: preferences).map(\.url.standardizedFileURL.path).filter { $0 != path }
    }

    static func defaultFavorites() -> [Place] {
        let fm = FileManager.default
        // macOS's own names for its folders ("Schreibtisch", "Téléchargements"…), the same as Finder shows.
        func named(_ url: URL, _ symbol: String) -> Place {
            Place(title: fm.displayName(atPath: url.path), url: url, symbol: symbol)
        }
        var places = [
            named(home, "house"),
            named(home.appending(path: "Desktop"), "menubar.dock.rectangle"),
            named(home.appending(path: "Documents"), "doc"),
            named(home.appending(path: "Downloads"), "arrow.down.circle"),
            named(URL(fileURLWithPath: "/Applications"), "square.grid.2x2"),
        ]
        // Common homes for source code get a spot without any setup.
        for path in ["Developer", "Projects", "Code", "code", "src", "repos", "Documents/GitHub", "GitHub"] {
            let url = home.appending(path: path)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
               !places.contains(where: { $0.url.path.lowercased() == url.path.lowercased() }) {
                places.append(Place(title: url.lastPathComponent, url: url, symbol: "chevron.left.forwardslash.chevron.right"))
            }
        }
        let iCloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: iCloud.path) {
            places.append(named(iCloud, "icloud"))
        }
        return places
    }

    /// A folder's name as Finder shows it ("Trash" for `~/.Trash`; an archive opened as a folder goes by its file name).
    static func displayName(_ url: URL, copies: CopyProviders = .live) -> String {
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
        return FileManager.default.displayName(atPath: url.path)
    }

    static func volumes() -> [Place] {
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
