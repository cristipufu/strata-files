import AppKit
import Testing
@testable import StrataTheme

struct ThemeCatalogTests {
    private func file(id: String = "meadow", name: String = "Meadow", order: Int = 150,
                      changing: [String: Any] = [:]) throws -> (name: String, data: Data) {
        var values: [String: Any] = [
            "version": 1, "id": id, "name": name, "comment": "Color theme: soft yellow-green",
            "order": order, "seed": [0.45, 0.60, 0.25], "tintStrength": 0.5,
            "lightnessShift": ["light": 0.0, "dark": -0.02],
        ]
        values.merge(changing) { _, new in new }
        return (id + ".json", try JSONSerialization.data(withJSONObject: values))
    }

    private static let latte: [String: String] = [
        "content": "#eff1f5", "sidebar": "#e6e9ef", "inspector": "#e6e9ee", "preview": "#fafafa",
        "chrome": "#ccd0da", "alternatingRow": "#e6e9ed", "selection": "#d8c9f4", "accent": "#702fc5",
    ]
    private static let mocha: [String: String] = [
        "content": "#1e1e2e", "sidebar": "#181825", "inspector": "#181826", "preview": "#11111b",
        "chrome": "#313244", "alternatingRow": "#181827", "selection": "#5b4e74", "accent": "#cba6f7",
    ]

    /// A published scheme states each appearance's colors in place of the derived tint.
    private func statedFile(light: [String: String] = latte, dark: [String: String] = mocha,
                            changing: [String: Any] = [:]) throws -> (name: String, data: Data) {
        var values: [String: Any] = [
            "version": 1, "id": "meadow", "name": "Meadow", "comment": "Color theme: a published palette",
            "order": 150, "seed": [0.53, 0.22, 0.94], "light": light, "dark": dark,
        ]
        values.merge(changing) { _, new in new }
        return ("meadow.json", try JSONSerialization.data(withJSONObject: values))
    }

    private func hex(_ color: NSColor) throws -> String {
        let rgb = try #require(color.usingColorSpace(.sRGB))
        return String(format: "#%02x%02x%02x", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }

    @Test func bundledThemesAreValidAndEveryFileIsAvailableInSettings() throws {
        let themes = try ThemeCatalog.loadBundled()
        #expect(!themes.isEmpty)
        #expect(ColorTheme.allCases == [.system] + themes)
        for theme in themes {
            #expect(ColorTheme(rawValue: theme.rawValue) == theme)
            #expect(!theme.title.isEmpty)
        }
        for id in ["graphite", "blue", "green", "purple", "sand", "teal", "rose", "amber",
                   "slate", "sage", "coral", "plum", "ice", "midnight", "catppuccin", "dracula", "tokyo-night"] {
            #expect(themes.contains { $0.rawValue == id })
        }
    }

    @Test func anUnlistedThemeLoadsWithoutChangingSwiftAndKeepsItsOwnColors() throws {
        let themes = try ThemeCatalog.load([file(order: 160), file(id: "dusk", name: "Dusk", order: 150)])
        #expect(themes.map(\.rawValue) == ["dusk", "meadow"])
        let meadow = try #require(themes.last)
        #expect(meadow.title == "Meadow")
        #expect(meadow.seed == ThemeRGB(red: 0.45, green: 0.60, blue: 0.25))
        for dark in [false, true] {
            #expect(meadow.surface(.content, dark: dark)
                    == meadow.seed.surface(.content, dark: dark, tintStrength: 0.5, brightnessShift: dark ? -0.02 : 0))
        }
        #expect(ColorTheme(rawValue: "meadow") == nil, "An injected catalog must not change the application catalog.")
    }

    @Test func invalidColorsSchemaAndIdentityFailBeforeAThemeIsPublished() throws {
        let changes: [[String: Any]] = [
            ["version": 2], ["extra": "typo"], ["seed": []], ["seed": [0.5, 0.5]],
            ["seed": [0.5, 0.5, 0.5, 0.5]], ["seed": [-0.01, 0.5, 0.5]], ["seed": [1.01, 0.5, 0.5]],
            ["seed": ["red", "green", "blue"]], ["seed": NSNull()],
            ["tintStrength": -0.01], ["tintStrength": 1.26],
            ["lightnessShift": ["light": -0.03, "dark": 0]],
            ["lightnessShift": ["light": 0, "dark": -0.13]],
            ["lightnessShift": ["light": 0.05, "dark": 0.05]],
            ["lightnessShift": ["light": 0]], ["id": "system"], ["id": "../escape"],
            ["lightnessShift": ["light": 0, "dark": 0, "dakr": -0.02]],
            ["id": "Meadow"], ["id": ""], ["name": " "], ["name": " Meadow"],
            ["name": "Two\nLines"], ["name": "%@"], ["name": String(repeating: "a", count: 41)],
            ["comment": " "], ["order": 0], ["order": 10_001],
        ]
        for change in changes {
            let input = try file(changing: change)
            #expect(throws: (any Error).self, "\(change)") { try ThemeCatalog.load([input]) }
        }
        for data in [Data(), Data("{".utf8), Data(repeating: 32, count: 16_385)] {
            #expect(throws: (any Error).self) { try ThemeCatalog.load([("meadow.json", data)]) }
        }
        let input = try file()
        #expect(throws: (any Error).self) { try ThemeCatalog.load([("other.json", input.data)]) }
        #expect(throws: (any Error).self) { try ThemeCatalog.load(Array(repeating: input, count: 129)) }
    }

    @Test func statedColorsAreUsedExactlyForEachAppearanceInsteadOfTheSeed() throws {
        let theme = try #require(try ThemeCatalog.load([statedFile()]).first)
        let light = try #require(NSAppearance(named: .aqua)), dark = try #require(NSAppearance(named: .darkAqua))
        let roles: [(ThemeSurfaceRole, String)] = [(.content, "content"), (.sidebar, "sidebar"), (.inspector, "inspector"),
                                                   (.preview, "preview"), (.chrome, "chrome"),
                                                   (.alternatingRow, "alternatingRow")]
        #expect(roles.count == ThemeSurfaceRole.allCases.count)
        for (appearance, stated) in [(light, Self.latte), (dark, Self.mocha)] {
            for (role, key) in roles {
                #expect(try hex(theme.surface(role, dark: appearance.isDark)) == stated[key], "\(key)")
                #expect(try hex(ColorThemeOptions(palette: theme).surfaceColor(in: appearance, reduceTransparency: false,
                                                                                role: role)) == stated[key])
            }
            var selection: NSColor?, accent: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                selection = theme.selectionColor.usingColorSpace(.sRGB)
                accent = theme.accentColor.usingColorSpace(.sRGB)
            }
            #expect(try hex(#require(selection)) == stated["selection"])
            #expect(try hex(#require(accent)) == stated["accent"])
        }
        // Filled controls draw white on a deep shade of the seed, as derived palettes do.
        #expect(ColorThemeOptions(palette: theme).controlAccentColor(highContrast: false) == theme.seed.selectionColor)
        // macOS can alias named high-contrast appearances to Aqua, so pass the accessibility preference itself.
        for appearance in [light, dark] {
            var accent: NSColor?, label: NSColor?, selection: NSColor?, native: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                accent = theme.accentColor(highContrast: true).usingColorSpace(.sRGB)
                label = NSColor.labelColor.usingColorSpace(.sRGB)
                selection = theme.selectionColor(highContrast: true).usingColorSpace(.sRGB)
                native = NSColor.selectedContentBackgroundColor.usingColorSpace(.sRGB)
            }
            #expect(accent == label && selection == native, "Increase Contrast keeps native colors for stated palettes too.")
            #expect(ColorThemeOptions(palette: theme).surfaceColor(in: appearance, reduceTransparency: false,
                                                                    highContrast: true).alphaComponent == 0)
        }
    }

    @Test func publishedSchemesUseTheirOwnLightAndDarkPalettes() throws {
        // Surfaces in role order: content, sidebar, inspector, preview, chrome (unfocused selection), alternating row.
        typealias Flavor = (surfaces: [String], selection: String, accent: String)
        let schemes: [(id: String, name: String, light: Flavor, dark: Flavor)] = [
            // Catppuccin Latte and Mocha: Base, Mantle, Crust and Surface 0; selections mix Mauve into Base.
            // Latte’s Mauve is deepened to keep links readable on Surface 0.
            ("catppuccin", "Catppuccin",
             (["#eff1f5", "#e6e9ef", "#e6e9ef", "#eff1f5", "#ccd0da", "#e6e9ef"], "#d8c9f4", "#702fc5"),
             (["#1e1e2e", "#181825", "#181825", "#11111b", "#313244", "#181825"], "#5b4e74", "#cba6f7")),
            // Alucard and Dracula Classic: Background and its lighter and darker shades with Pink; selections mix
            // Pink into Background, as the sidebar tints its own.
            ("dracula", "Dracula",
             (["#fffbeb", "#ece9df", "#ece9df", "#fffbeb", "#dedccf", "#ece9df"], "#ebc8c8", "#a3144d"),
             (["#282a36", "#21222c", "#21222c", "#191a21", "#343746", "#21222c"], "#734668", "#ff79c6")),
            // Tokyo Night Day and Night: bg, bg_sidebar, bg_highlight and bg_visual with Blue. Day’s Blue is
            // deepened to keep links readable on its gray surfaces.
            ("tokyo-night", "Tokyo Night",
             (["#e1e2e7", "#d0d5e3", "#d0d5e3", "#e1e2e7", "#c4c8da", "#d0d5e3"], "#b7c1e3", "#1d5095"),
             (["#1a1b26", "#16161e", "#16161e", "#0c0e14", "#292e42", "#16161e"], "#283457", "#7aa2f7")),
        ]
        let roles: [ThemeSurfaceRole] = [.content, .sidebar, .inspector, .preview, .chrome, .alternatingRow]
        #expect(Set(roles) == Set(ThemeSurfaceRole.allCases))
        for scheme in schemes {
            let theme = try #require(ColorTheme(rawValue: scheme.id))
            #expect(theme.title == scheme.name)
            for (dark, flavor) in [(false, scheme.light), (true, scheme.dark)] {
                let stated = try #require(theme.statedColors(dark: dark))
                for (role, expected) in zip(roles, flavor.surfaces) {
                    #expect(try hex(theme.surface(role, dark: dark)) == expected, "\(scheme.id), \(role), dark: \(dark)")
                }
                #expect(try hex(stated.selection.color) == flavor.selection, "\(scheme.id), dark: \(dark)")
                #expect(try hex(stated.accent.color) == flavor.accent, "\(scheme.id), dark: \(dark)")
            }
        }
    }

    @Test func statedColorsMustBeCompleteWellFormedAndReadableBeforeAThemeIsPublished() throws {
        var files: [(name: String, data: Data)] = []
        for broken in ["1e1e2e", "#1e1e2", "#1e1e2e0", "#1e1e2e00", "#gggggg", "#1e1e2e ", " #1e1e2e", "rgb(1,2,3)", ""] {
            files.append(try statedFile(dark: Self.mocha.merging(["content": broken]) { _, new in new }))
        }
        var missing = Self.latte
        missing["alternatingRow"] = nil
        files.append(try statedFile(light: missing))
        files.append(try statedFile(light: Self.latte.merging(["border": "#ffffff"]) { _, new in new }))
        files.append(try statedFile(changing: ["light": NSNull()]))
        files.append(try statedFile(changing: ["dark": ["content": 0.1]]))
        files.append(try statedFile(changing: ["seed": [0.5, 0.5]]))
        // One appearance alone, or stated colors mixed with a derived tint, would leave the other side undefined.
        let valid = try #require(try JSONSerialization.jsonObject(with: statedFile().data) as? [String: Any])
        let changes: [(key: String, value: Any?)] = [("dark", nil), ("light", nil), ("tintStrength", 1.0),
                                                     ("lightnessShift", ["light": 0.0, "dark": 0.0])]
        for change in changes {
            var changed = valid
            changed[change.key] = change.value
            files.append(("meadow.json", try JSONSerialization.data(withJSONObject: changed)))
        }
        // A dark appearance with light surfaces, a light appearance with dark ones, or an accent that
        // disappears against any surface would make Strata’s text unreadable. Latte’s published Mauve reads
        // on Base but not on Surface 0.
        files.append(try statedFile(light: Self.mocha, dark: Self.latte))
        files.append(try statedFile(dark: Self.mocha.merging(["sidebar": "#6c7086"]) { _, new in new }))
        files.append(try statedFile(dark: Self.mocha.merging(["selection": "#7f849c"]) { _, new in new }))
        files.append(try statedFile(light: Self.latte.merging(["chrome": "#7c7f93"]) { _, new in new }))
        files.append(try statedFile(light: Self.latte.merging(["accent": "#7287fd"]) { _, new in new }))
        files.append(try statedFile(light: Self.latte.merging(["accent": "#8839ef"]) { _, new in new }))
        files.append(try statedFile(dark: Self.mocha.merging(["accent": "#45475a"]) { _, new in new }))
        for input in files {
            #expect(throws: (any Error).self, "\(String(decoding: input.data, as: UTF8.self))") {
                try ThemeCatalog.load([input])
            }
        }
        // Uppercase digits are the same color.
        let upper = try ThemeCatalog.load([statedFile(light: Self.latte.merging(["content": "#EFF1F5"]) { _, new in new })])
        #expect(try hex(#require(upper.first).surface(.content, dark: false)) == "#eff1f5")
        #expect(try ThemeCatalog.load([statedFile()]).count == 1)
    }

    @Test func duplicateIdsNamesAndOrdersCannotSilentlyHideAContribution() throws {
        let first = try file()
        for duplicate in [try file(name: "Other", order: 160),
                          try file(id: "other", order: 160),
                          try file(id: "other", name: "Other")] {
            #expect(throws: (any Error).self) { try ThemeCatalog.load([first, duplicate]) }
        }
    }
}
