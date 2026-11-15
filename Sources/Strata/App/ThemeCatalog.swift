import Foundation
import StrataSupport

private final class ThemeBundleMarker {}

/// A contributed palette supplies color choices; native drawing and accessibility stay in ThemeStyle.
nonisolated package struct ThemeDefinition: Decodable, Equatable, Sendable {
    package let id: String
    package let name: String
    package let order: Int
    package let seed: ThemeRGB
    package let tintStrength: CGFloat
    package let lightShift: CGFloat
    package let darkShift: CGFloat
    /// A published scheme states its own colors for each appearance; nil derives them from the seed.
    package let colors: ThemeAppearances?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, id, name, comment, order, seed, tintStrength, lightnessShift, light, dark
    }
    fileprivate struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    package init(from decoder: any Decoder) throws {
        let keys = Set(try decoder.container(keyedBy: Key.self).allKeys.map(\.stringValue))
        let common: [CodingKeys] = [.version, .id, .name, .comment, .order, .seed]
        let derived = Set((common + [.tintStrength, .lightnessShift]).map(\.rawValue))
        let stated = Set((common + [.light, .dark]).map(\.rawValue))
        guard keys == derived || keys == stated else {
            throw ThemeCatalog.Invalid("Unknown or missing theme fields")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == 1 else {
            throw ThemeCatalog.Invalid("Unsupported theme version")
        }
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        order = try values.decode(Int.self, forKey: .order)
        let comment = try values.decode(String.self, forKey: .comment)
        let channels = try values.decode([Double].self, forKey: .seed)
        guard id.range(of: "^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$", options: .regularExpression) != nil,
              id.count <= 48, id != "system", order > 0, order <= 10_000,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 40,
              name == name.trimmingCharacters(in: .whitespacesAndNewlines), !name.contains("%"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, comment.count <= 240,
              channels.count == 3, channels.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw ThemeCatalog.Invalid("Invalid theme identity, name or color values")
        }
        seed = ThemeRGB(red: channels[0], green: channels[1], blue: channels[2])
        if keys == stated {
            let light = try values.decode(ThemeColors.self, forKey: .light)
            let dark = try values.decode(ThemeColors.self, forKey: .dark)
            guard light.isReadable(dark: false), dark.isReadable(dark: true) else {
                throw ThemeCatalog.Invalid("Stated colors must keep text readable in their appearance")
            }
            colors = ThemeAppearances(light: light, dark: dark)
            tintStrength = 1
            lightShift = 0
            darkShift = 0
            return
        }
        let strength = try values.decode(Double.self, forKey: .tintStrength)
        let shift = try values.decode([String: Double].self, forKey: .lightnessShift)
        guard Set(shift.keys) == ["light", "dark"], let light = shift["light"], let dark = shift["dark"] else {
            throw ThemeCatalog.Invalid("Expected light and dark lightness shifts")
        }
        guard strength.isFinite, (0...1.25).contains(strength),
              light.isFinite, (-0.02...0.04).contains(light),
              dark.isFinite, (-0.12...0.04).contains(dark) else {
            throw ThemeCatalog.Invalid("Invalid theme identity, name or color values")
        }
        colors = nil
        tintStrength = strength
        lightShift = light
        darkShift = dark
    }
}

/// A published scheme's own colors, a set for each appearance.
nonisolated package struct ThemeAppearances: Equatable, Sendable {
    package let light, dark: ThemeColors
}

/// One appearance of a published scheme, in its own sRGB values, such as Catppuccin’s Latte or Mocha.
nonisolated package struct ThemeColors: Decodable, Equatable, Sendable {
    package let content, sidebar, inspector, preview, chrome, alternatingRow: ThemeRGB
    /// Selected names are black on a light selection and white on a dark one.
    package let selection: ThemeRGB
    /// Links, matching letters, sidebar symbols and the active pane draw in this color on any of the surfaces.
    package let accent: ThemeRGB

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case content, sidebar, inspector, preview, chrome, alternatingRow, selection, accent
    }

    package init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: ThemeDefinition.Key.self).allKeys.map(\.stringValue)
        guard Set(keys) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw ThemeCatalog.Invalid("Expected every surface, selection and accent color")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func color(_ key: CodingKeys) throws -> ThemeRGB {
            let text = try values.decode(String.self, forKey: key)
            guard text.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil,
                  let value = Int(text.dropFirst(), radix: 16) else {
                throw ThemeCatalog.Invalid("Colors are written #RRGGBB in sRGB")
            }
            return ThemeRGB(red: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                            blue: CGFloat(value & 0xFF) / 255)
        }
        content = try color(.content)
        sidebar = try color(.sidebar)
        inspector = try color(.inspector)
        preview = try color(.preview)
        chrome = try color(.chrome)
        alternatingRow = try color(.alternatingRow)
        selection = try color(.selection)
        accent = try color(.accent)
    }

    package func surface(_ role: ThemeSurfaceRole) -> ThemeRGB {
        switch role {
        case .content: content
        case .sidebar: sidebar
        case .inspector: inspector
        case .preview: preview
        case .chrome: chrome
        case .alternatingRow: alternatingRow
        }
    }

    /// Strata draws dark ink on light appearances and light ink on dark ones, so surfaces must stay on their side.
    /// Dark fills share the 0.12 luminance ceiling of derived dark selections.
    func isReadable(dark: Bool) -> Bool {
        let surfaces = ThemeSurfaceRole.allCases.map(surface)
        return (surfaces + [selection]).allSatisfy { dark ? $0.luminance <= 0.12 : $0.luminance >= 0.4 }
            && surfaces.allSatisfy { accent.contrast(with: $0) >= 4.5 }
    }
}

nonisolated package enum ThemeCatalog {
    package struct Invalid: Error, CustomStringConvertible {
        package let description: String
        init(_ description: String) { self.description = description }
    }

    package static let bundled: [ColorTheme] = {
        do { return try loadBundled() }
        catch {
            NSLog("Strata could not load its color themes: %@", String(describing: error))
            return []
        }
    }()

    package static func loadBundled() throws -> [ColorTheme] {
        let bundle = try ResourceBundle.named("Strata_StrataTheme", in: .main, linkedTo: Bundle(for: ThemeBundleMarker.self))
        guard let folder = bundle.url(forResource: "Themes", withExtension: nil) else {
            throw Invalid("Missing bundled theme folder")
        }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        guard !files.isEmpty, files.count <= maximumThemes else { throw Invalid("Expected 1–128 theme files") }
        return try load(files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    /// A theme file is small, and a folder of themes short: nothing longer is read, and nothing past these is looked at.
    package static let maximumBytes = 16_384
    package static let maximumThemes = 128
    package static let maximumEntries = 1_024

    package typealias File = (name: String, data: Data)

    /// What reading a folder of the user's themes found.
    package struct FolderRead: Sendable {
        /// The theme files that were read.
        package var files: [File]
        /// The names of theme files that are there and could not be read: this read says nothing of them.
        package var unread: [String]

        package init(files: [File] = [], unread: [String] = []) {
            self.files = files
            self.unread = unread
        }
    }

    /// A theme file that is there and gave no bytes this time.
    package struct Unread: Error, CustomStringConvertible {
        package let description: String
    }

    /// Reads the theme files of `folder`, a folder of the user's. Nil when the folder is there and could not be
    /// listed: a folder that was not read is no empty folder. A file that is no theme file is logged and skipped, and
    /// one that could not be read is logged and named as unread.
    package static func read(folder: URL) -> FolderRead? {
        guard let files = themeFiles(in: folder) else {
            NSLog("Strata could not read its themes folder")
            return nil
        }
        var found = FolderRead()
        for url in files {
            do { found.files.append((url.lastPathComponent, try read(url))) }
            catch {
                NSLog("Strata skipped the theme %@: %@", url.lastPathComponent, String(describing: error))
                if error is Unread { found.unread.append(url.lastPathComponent) }
            }
        }
        return found
    }

    /// The folder's `.json` entries by name, from no more of its entries than `limit`: what the folder holds is the
    /// user's, and may be anything. None when the folder is missing, or what is there is no folder; nil when it
    /// could not be listed.
    package static func themeFiles(in folder: URL, lookingAt limit: Int = maximumEntries) -> [URL]? {
        guard let directory = opendir(folder.path) else {
            let reason = errno
            return reason == ENOTDIR || (reason == ENOENT && isMissing(folder)) ? [] : nil
        }
        defer { closedir(directory) }
        var files: [URL] = []
        var seen = 0
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { return nil }
                break
            }
            let name = DirectoryEntryName.read(entry)
            if name == "." || name == ".." { continue }
            guard seen < limit else {
                NSLog("Strata looked at the first %d items of its themes folder only", limit)
                break
            }
            seen += 1
            if let name, (name as NSString).pathExtension == "json" { files.append(folder.appending(path: name)) }
        }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Whether the folder that would hold `folder` is there and holds nothing by its name. A link by that name to a
    /// folder that is away, and a folder whose own parent can't be reached, are not missing: they could not be read.
    private static func isMissing(_ folder: URL) -> Bool {
        var status = stat()
        guard lstat(folder.path, &status) != 0, errno == ENOENT else { return false }
        return stat(folder.deletingLastPathComponent().path, &status) == 0
    }

    /// A theme file's bytes: a regular file's, read no further than a theme may be long. Opening it never waits, so
    /// a pipe or a device named like a theme is refused where reading it whole would hold whoever reads. Throws
    /// `Unread` for a file that is there and can't be read now (only in the cloud, or not permitted), and `Invalid`
    /// for what is no theme file, or is gone: a link whose target is missing among them.
    package static func read(_ url: URL) throws -> Data {
        // Through a link as well: what is asked about is the file that would be read.
        var status = stat()
        if stat(url.path, &status) == 0, DatalessFile.isDataless(status) {
            throw Unread(description: "The file is only in the cloud")
        }
        let read: (data: Data, isLonger: Bool)
        do { read = try TextFile.readPrefix(url, limit: maximumBytes) }
        catch is TextFile.NotText { throw Invalid("The file is no regular file") }
        catch POSIXError.ENOENT { throw Invalid("The file is gone") }
        catch { throw Unread(description: "The file can't be read: \(error)") }
        guard !read.isLonger else { throw Invalid("Theme file is larger than 16 KiB") }
        return read.data
    }

    /// The user's themes among `files`, in their order, with the files they were read from by name. Every file is
    /// checked once, with the bundled rules: a file that's invalid, or repeats an ID or name `taken` or another of
    /// the user's themes already has, or that theme's order, is logged and skipped, so one mistake never hides the
    /// other themes. A name is taken as its theme is called untranslated and as it is shown in the app's language.
    package static func accepted(_ files: [File], besides taken: [ColorTheme]) -> (themes: [ColorTheme], files: [String: Data]) {
        var used = Used()
        var definitions: [ThemeDefinition] = []
        var kept: [String: Data] = [:]
        for file in files {
            do {
                guard definitions.count < maximumThemes else { throw Invalid("More than 128 user themes") }
                let definition = try definition(in: file)
                guard !taken.contains(where: { $0.rawValue == definition.id || $0.name == definition.name || $0.title == definition.name }) else {
                    throw Invalid("A theme of Strata's already uses this ID or name")
                }
                guard used.take(definition) else { throw Invalid("Another of your themes already uses this ID, name or order") }
                definitions.append(definition)
                kept[file.name] = file.data
            } catch {
                NSLog("Strata skipped the theme %@: %@", file.name, String(describing: error))
            }
        }
        return (definitions.sorted { $0.order < $1.order }.map { ColorTheme(definition: $0, translatesName: false) }, kept)
    }

    /// This same loader validates new files in tests, without changing the application's catalog or preferences.
    package static func load(_ files: [File]) throws -> [ColorTheme] {
        guard files.count <= maximumThemes else { throw Invalid("Too many theme files") }
        var used = Used()
        let themes = try files.map { file in
            let definition = try definition(in: file)
            guard used.take(definition) else {
                throw Invalid("Theme filename, ID, name and order must be unique: \(file.name)")
            }
            return definition
        }.sorted { $0.order < $1.order }
        return themes.map { ColorTheme(definition: $0, translatesName: true) }
    }

    private static func definition(in file: File) throws -> ThemeDefinition {
        guard file.data.count <= maximumBytes else { throw Invalid("Theme file is larger than 16 KiB: \(file.name)") }
        let definition = try JSONDecoder().decode(ThemeDefinition.self, from: file.data)
        guard file.name == definition.id + ".json" else { throw Invalid("A theme's file is named after its ID: \(file.name)") }
        return definition
    }

    /// The IDs, names and orders a set of themes already has: no other theme of the set may repeat one.
    private struct Used {
        private var ids = Set<String>(), names = Set<String>(), orders = Set<Int>()

        /// Takes `definition`'s unless one is taken, and says whether it did.
        mutating func take(_ definition: ThemeDefinition) -> Bool {
            guard !ids.contains(definition.id), !names.contains(definition.name), !orders.contains(definition.order) else {
                return false
            }
            ids.insert(definition.id)
            names.insert(definition.name)
            orders.insert(definition.order)
            return true
        }
    }
}
