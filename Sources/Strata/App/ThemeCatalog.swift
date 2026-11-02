import Foundation

/// A contributed palette supplies color choices; native drawing and accessibility stay in ThemeStyle.
nonisolated package struct ThemeDefinition: Decodable, Sendable {
    package let id: String
    package let name: String
    package let order: Int
    package let seed: ThemeRGB
    package let tintStrength: CGFloat
    package let lightShift: CGFloat
    package let darkShift: CGFloat
    /// A published scheme states its own colors for each appearance; nil derives them from the seed.
    package let colors: (light: ThemeColors, dark: ThemeColors)?

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
            colors = (light, dark)
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

/// One appearance of a published scheme, in its own sRGB values, such as Catppuccin’s Latte or Mocha.
nonisolated package struct ThemeColors: Decodable, Sendable {
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
        // SwiftPM's accessor finds the bundle beside test executables; packaged apps carry it in Resources.
        let bundle = Bundle.main.url(forResource: "Strata_StrataTheme", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? .module
        guard let folder = bundle.url(forResource: "Themes", withExtension: nil) else {
            throw Invalid("Missing bundled theme folder")
        }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        guard !files.isEmpty, files.count <= 128 else { throw Invalid("Expected 1–128 theme files") }
        return try load(files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    /// This same loader validates new files in tests, without changing the application's catalog or preferences.
    package static func load(_ files: [(name: String, data: Data)]) throws -> [ColorTheme] {
        guard files.count <= 128 else { throw Invalid("Too many theme files") }
        var ids = Set<String>(), names = Set<String>(), orders = Set<Int>()
        let themes = try files.map { file in
            guard file.data.count <= 16_384 else { throw Invalid("Theme file is larger than 16 KiB: \(file.name)") }
            let definition = try JSONDecoder().decode(ThemeDefinition.self, from: file.data)
            guard file.name == definition.id + ".json",
                  ids.insert(definition.id).inserted, names.insert(definition.name).inserted,
                  orders.insert(definition.order).inserted else {
                throw Invalid("Theme filename, ID, name and order must be unique: \(file.name)")
            }
            return definition
        }.sorted { $0.order < $1.order }
        return themes.map(ColorTheme.init(definition:))
    }
}
