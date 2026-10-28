import AppKit
import Synchronization

/// A hue shared by the entire browser; file types, tags and status colors keep their meanings.
nonisolated package struct ColorTheme: RawRepresentable, CaseIterable, Hashable, Sendable {
    package let rawValue: String
    private let definition: ThemeDefinition?

    package static let system = ColorTheme()
    package static let allCases: [ColorTheme] = [.system] + ThemeCatalog.bundled

    // Existing call sites keep their typed names; contributed themes need no Swift declaration.
    package static let graphite = ColorTheme(rawValue: "graphite") ?? .system
    package static let blue = ColorTheme(rawValue: "blue") ?? .system
    package static let green = ColorTheme(rawValue: "green") ?? .system
    package static let purple = ColorTheme(rawValue: "purple") ?? .system
    package static let sand = ColorTheme(rawValue: "sand") ?? .system
    package static let teal = ColorTheme(rawValue: "teal") ?? .system
    package static let rose = ColorTheme(rawValue: "rose") ?? .system
    package static let amber = ColorTheme(rawValue: "amber") ?? .system

    private init() { rawValue = "system"; definition = nil }
    package init(definition: ThemeDefinition) { rawValue = definition.id; self.definition = definition }

    package init?(rawValue: String) {
        guard let theme = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = theme
    }

    package static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawValue == rhs.rawValue }
    package func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }

    package var title: String {
        guard let definition else { return String(localized: "System", comment: "Color theme: use the Mac’s colors") }
        // localize.py extracts names and translator notes from the theme files.
        return String(localized: String.LocalizationValue(definition.name))
    }

    package var seed: ThemeRGB { definition?.seed ?? ThemeRGB(red: 0.38, green: 0.44, blue: 0.67) }

    /// A published scheme's own colors for this appearance, or nil when they derive from the seed.
    package func statedColors(dark: Bool) -> ThemeColors? {
        guard let colors = definition?.colors else { return nil }
        return dark ? colors.dark : colors.light
    }

    package func surface(_ role: ThemeSurfaceRole, dark: Bool) -> NSColor {
        if let stated = statedColors(dark: dark) { return stated.surface(role).color }
        return seed.surface(role, dark: dark, tintStrength: definition?.tintStrength ?? 1,
                            brightnessShift: dark ? (definition?.darkShift ?? 0) : (definition?.lightShift ?? 0))
    }

    /// Light selections use a stronger shade of the pastel surfaces; dark selections keep readable light text.
    package var selectionColor: NSColor { selectionColor(highContrast: false) }

    package func selectionColor(highContrast: Bool) -> NSColor {
        guard self != .system else { return .selectedContentBackgroundColor }
        let rgb = seed
        return NSColor(name: nil) { appearance in
            if highContrast || appearance.isHighContrast { return .selectedContentBackgroundColor }
            if let stated = self.statedColors(dark: appearance.isDark) { return stated.selection.color }
            if appearance.isDark { return rgb.selectionColor }
            let surface = self.surface(.chrome, dark: false)
            return surface.blended(withFraction: 0.08, of: .black) ?? surface
        }
    }

    package var selectedTextColor: NSColor { selectedTextColor(highContrast: false) }

    package func selectedTextColor(highContrast: Bool) -> NSColor {
        guard self != .system else { return .alternateSelectedControlTextColor }
        return NSColor(name: nil) { appearance in
            if highContrast || appearance.isHighContrast { return .alternateSelectedControlTextColor }
            return appearance.isDark ? .white : .black
        }
    }

    /// Brighter on dark backgrounds so links and matching letters remain legible.
    package var accentColor: NSColor { accentColor(highContrast: false) }

    package func accentColor(highContrast: Bool) -> NSColor {
        ColorThemeOptions(palette: self).accentColor(highContrast: highContrast)
    }
}

nonisolated package struct ThemeRGB: Equatable, Sendable {
    package var red: CGFloat
    package var green: CGFloat
    package var blue: CGFloat

    package var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    package init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        func channel(_ value: CGFloat) -> CGFloat { value.isFinite ? min(max(value, 0), 1) : 0.5 }
        self.red = channel(red); self.green = channel(green); self.blue = channel(blue)
    }

    package var luminance: CGFloat {
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    package func contrast(with other: Self) -> CGFloat {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }

    package var selectionRGB: Self {
        var result = self
        // Gold and green need darker selections to leave room for both names and secondary metadata.
        while result.luminance > 0.12 {
            result = Self(red: result.red * 0.94, green: result.green * 0.94, blue: result.blue * 0.94)
        }
        return result
    }

    package var selectionColor: NSColor { selectionRGB.color }

    package func surface(_ role: ThemeSurfaceRole, dark: Bool, tintStrength: CGFloat = 1,
                         brightnessShift: CGFloat = 0) -> NSColor {
        let maxChannel = max(red, green, blue), minChannel = min(red, green, blue)
        let chroma = maxChannel - minChannel
        var hue: CGFloat = 0
        if chroma > 0.0001 {
            if maxChannel == red { hue = ((green - blue) / chroma).truncatingRemainder(dividingBy: 6) }
            else if maxChannel == green { hue = (blue - red) / chroma + 2 }
            else { hue = (red - green) / chroma + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation: CGFloat = chroma < 0.025 ? 0 : (dark ? 0.33 : 0.40) * tintStrength
        var level: CGFloat
        switch role {
        case .content: level = dark ? 0.29 : 0.92
        case .sidebar: level = dark ? 0.31 : 0.86
        case .inspector: level = dark ? 0.31 : 0.86
        case .preview: level = dark ? 0.26 : 0.94
        case .chrome: level = dark ? 0.33 : 0.82
        case .alternatingRow: level = dark ? 0.31 : 0.90
        }
        if dark, chroma < 0.025 { level -= 0.10 }
        level = min(max(level + brightnessShift, 0), 1)
        let c = (1 - abs(2 * level - 1)) * saturation
        let x = c * (1 - abs((hue * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = level - c / 2
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch hue * 6 {
        case ..<1: rgb = (c, x, 0)
        case ..<2: rgb = (x, c, 0)
        case ..<3: rgb = (0, c, x)
        case ..<4: rgb = (0, x, c)
        case ..<5: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        return NSColor(srgbRed: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m, alpha: 1)
    }
}

nonisolated package enum ThemeSurfaceRole: CaseIterable {
    case content, sidebar, inspector, preview, chrome, alternatingRow

    package var nativeColor: NSColor {
        switch self {
        case .content: .controlBackgroundColor
        case .preview: .textBackgroundColor
        case .alternatingRow: NSColor.alternatingContentBackgroundColors.last ?? .controlBackgroundColor
        default: .clear
        }
    }
}

nonisolated package struct ColorThemeOptions: Equatable, Sendable {
    package var palette: ColorTheme = .system
    package var tintsWindow = true
    package var seed: ThemeRGB { palette.seed }

    package init(palette: ColorTheme = .system, tintsWindow: Bool = true) {
        self.palette = palette
        self.tintsWindow = tintsWindow
    }

    package func controlAccentColor(highContrast: Bool) -> NSColor {
        palette == .system || highContrast ? .controlAccentColor : seed.selectionColor
    }

    package func accentColor(highContrast: Bool) -> NSColor {
        guard palette != .system else { return .controlAccentColor }
        let rgb = seed.selectionRGB, palette = palette
        return NSColor(name: nil) { appearance in
            if highContrast || appearance.isHighContrast { return .labelColor }
            if let stated = palette.statedColors(dark: appearance.isDark) { return stated.accent.color }
            let lift: CGFloat = appearance.isDark ? 0.90 : 0
            let scale: CGFloat = appearance.isDark ? 1 : 0.80
            return NSColor(srgbRed: (rgb.red + (1 - rgb.red) * lift) * scale,
                           green: (rgb.green + (1 - rgb.green) * lift) * scale,
                           blue: (rgb.blue + (1 - rgb.blue) * lift) * scale, alpha: 1)
        }
    }

    package func selectionColor(highContrast: Bool) -> NSColor {
        palette.selectionColor(highContrast: highContrast)
    }

    package static func read(from defaults: UserDefaults) -> Self {
        Self(palette: defaults.string(forKey: "colorTheme").flatMap(ColorTheme.init(rawValue:)) ?? .system,
             tintsWindow: defaults.object(forKey: "tintWindow") as? Bool ?? true)
    }

    package func save(in defaults: UserDefaults) {
        defaults.set(palette.rawValue, forKey: "colorTheme")
        defaults.set(tintsWindow, forKey: "tintWindow")
    }

    package func surfaceColor(in appearance: NSAppearance, reduceTransparency: Bool, highContrast: Bool = false,
                              role: ThemeSurfaceRole = .sidebar) -> NSColor {
        guard palette != .system, tintsWindow, !highContrast, !appearance.isHighContrast else { return role.nativeColor }
        // Opaque coordinated surfaces stay consistent over wallpaper and in full screen, including Reduce Transparency.
        return palette.surface(role, dark: appearance.isDark)
    }

    package var windowColor: NSColor { windowColor(highContrast: false) }

    package func windowColor(highContrast: Bool) -> NSColor {
        guard palette != .system, tintsWindow, !highContrast else { return .windowBackgroundColor }
        return NSColor(name: nil) { appearance in
            let tint = self.surfaceColor(in: appearance, reduceTransparency: true, highContrast: highContrast, role: .content)
            return tint.alphaComponent == 0 ? .windowBackgroundColor : tint
        }
    }
}

/// Views refresh their drawing, without reloading entries, requesting thumbnails or disturbing inline rename.
package protocol ColorThemeUpdating: NSView {
    func updateColorTheme()
}

/// Marks the main browser window's split view controller so theme bindings can coordinate its safe area and resize events.
package protocol ThemeSplitWindowContent: NSSplitViewController {}

package enum ThemeStyle {
    nonisolated package static let inspectorState = Mutex((options: ColorThemeOptions(), tinted: false))
    package private(set) static var options = ColorThemeOptions()
    /// macOS can alias named high-contrast appearances to Aqua; also keep the accessibility preference itself.
    package private(set) static var highContrast = false
    package static var colorsSurfaces: Bool { options.palette != .system && options.tintsWindow && !highContrast }
    package static var accent: NSColor { options.accentColor(highContrast: highContrast) }
    package static var controlAccent: NSColor { options.controlAccentColor(highContrast: highContrast) }
    package static var selectedText: NSColor { options.palette.selectedTextColor(highContrast: highContrast) }
    package static let panelLabel = NSColor.ink(light: 0.92, dark: 1)
    package static let panelIcon = NSColor.ink(light: 0.6, dark: 0.75)
    package static var border: NSColor { colorsSurfaces ? accent.withAlphaComponent(0.25) : .separatorColor }

    package static var iconSelection: NSColor {
        guard options.palette != .system, !highContrast else { return .unemphasizedSelectedContentBackgroundColor }
        let chosen = options
        return NSColor(name: nil) { appearance in
            appearance.isHighContrast ? .unemphasizedSelectedContentBackgroundColor : chosen.palette.surface(.chrome, dark: appearance.isDark)
        }
    }

    package static func selection(emphasized: Bool) -> NSColor {
        emphasized ? options.selectionColor(highContrast: highContrast) : iconSelection
    }

    package static func surface(_ role: ThemeSurfaceRole) -> NSColor {
        let chosen = options, contrast = highContrast
        return NSColor(name: nil) { appearance in
            chosen.surfaceColor(in: appearance, reduceTransparency: true, highContrast: contrast, role: role)
        }
    }

    package static func apply(_ options: ColorThemeOptions, windows: [NSWindow],
                              highContrast: Bool = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast) {
        self.options = options
        self.highContrast = highContrast
        if !colorsSurfaces {
            // A returning header can now sit inside the split view, outside the toolbar traversal.
            for view in headerMaterials.keyEnumerator().allObjects as? [NSView] ?? [] {
                restoreHeaderMaterial(view)
            }
        }
        inspectorState.withLock { $0 = (options, colorsSurfaces) }
        ThemeAppearance.shared.update(options, highContrast: highContrast)
        for window in windows { apply(to: window) }
    }

    package static func apply(to window: NSWindow) {
        if window.contentViewController is any ThemeSplitWindowContent {
            if windows.object(forKey: window) == nil { windows.setObject(ThemeWindowBinding(window), forKey: window) }
        }
        windows.object(forKey: window)?.apply(to: window)
        if window.contentViewController is any ThemeSplitWindowContent { ToolbarThemeController.apply(to: window) }
        if let root = window.contentView { refresh(root, includingInputs: windows.object(forKey: window) != nil) }
    }

    package static func bind(_ window: NSWindow) {
        if windows.object(forKey: window) == nil { windows.setObject(ThemeWindowBinding(window), forKey: window) }
        apply(to: window)
    }

    package static func updateTitlebar(in window: NSWindow, detached: Bool) {
        windows.object(forKey: window)?.updateTitlebar(in: window, detached: detached)
    }

    package static func refresh(_ view: NSView, includingInputs: Bool = false) {
        let owned = includingInputs || surfaces.object(forKey: view) != nil
        if owned { bindInput(view) }
        surfaces.object(forKey: view)?.apply(to: view)
        if let table = view as? NSTableView {
            for column in table.tableColumns { headers.object(forKey: column)?.apply(to: column) }
            refreshHeaderAppearance(in: table)
        }
        (view as? any ColorThemeUpdating)?.updateColorTheme()
        view.needsDisplay = true
        for child in view.subviews { refresh(child, includingInputs: owned) }
    }

    /// Only inside an owned surface: never recolor the system's file pickers or field editor.
    package static func bindInput(_ view: NSView) {
        let field = view as? NSTextField
        let text = view as? NSTextView
        if (field?.isEditable == true && !(field is NSSearchField)
            && (field?.drawsBackground == true || field?.isBezeled == true))
            || (text?.isEditable == true && text?.drawsBackground == true && text?.isFieldEditor == false) {
            // Inline rename temporarily turns a file label into an editor; its cell owns that background.
            if let parent = view.superview,
               sequence(first: parent, next: { $0.superview }).contains(where: { $0 is NSTableView || $0 is NSCollectionView }) {
                return
            }
            bind(view, to: .preview)
        }
    }

    private static let surfaces = NSMapTable<NSView, ThemeSurfaceBinding>.weakToStrongObjects()
    private static let windows = NSMapTable<NSWindow, ThemeWindowBinding>.weakToStrongObjects()
    private static let headerMaterials = NSMapTable<NSView, HeaderMaterialTint>.weakToStrongObjects()
    private static let headers = NSMapTable<NSTableColumn, ThemeHeaderBinding>.weakToStrongObjects()
    private static let headerAppearances = NSMapTable<NSTableHeaderView, ThemeHeaderAppearanceBinding>.weakToStrongObjects()

    package static func bind(_ column: NSTableColumn) {
        if headers.object(forKey: column) == nil { headers.setObject(ThemeHeaderBinding(column), forKey: column) }
        headers.object(forKey: column)?.apply(to: column)
        if let table = column.tableView { refreshHeaderAppearance(in: table) }
    }

    package static func refreshHeaderAppearance(in table: NSTableView) {
        guard let header = table.headerView,
              table.tableColumns.contains(where: { headers.object(forKey: $0) != nil }) else { return }
        if headerAppearances.object(forKey: header) == nil {
            headerAppearances.setObject(ThemeHeaderAppearanceBinding(header), forKey: header)
        }
        headerAppearances.object(forKey: header)?.apply(to: header, in: table)
    }

    package static func tintHeaderMaterial(_ view: NSView, withinWindow: Bool = false) {
        guard view is NSGlassEffectView || (withinWindow && view is NSVisualEffectView)
                || headerMaterials.object(forKey: view) != nil else { return }
        if headerMaterials.object(forKey: view) == nil { headerMaterials.setObject(HeaderMaterialTint(view), forKey: view) }
        headerMaterials.object(forKey: view)?.apply(to: view, withinWindow: withinWindow)
    }

    package static func restoreHeaderMaterial(_ view: NSView) {
        headerMaterials.object(forKey: view)?.restore(in: view)
        headerMaterials.removeObject(forKey: view)
    }

    package static func bind(_ view: NSView, to role: ThemeSurfaceRole) {
        if surfaces.object(forKey: view) == nil { surfaces.setObject(ThemeSurfaceBinding(view: view, role: role), forKey: view) }
        surfaces.object(forKey: view)?.apply(to: view)
    }
}

/// An owned surface’s coordinated color; System leaves the native material visible.
package final class ThemeSurfaceView: NSView {
    package var role: ThemeSurfaceRole = .sidebar
    package var ignoresMouse = false

    package override func hitTest(_ point: NSPoint) -> NSView? { ignoresMouse ? nil : super.hitTest(point) }

    package override func draw(_ dirtyRect: NSRect) {
        guard ThemeStyle.colorsSurfaces else { return }
        ThemeStyle.options.surfaceColor(in: effectiveAppearance,
                                        reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                                        highContrast: ThemeStyle.highContrast, role: role).setFill()
        dirtyRect.intersection(bounds).fill()
    }

    package override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Lists and deeper columns use the same selection palette as icon names.
package final class ThemeRowView: NSTableRowView {
    package override func drawSelection(in dirtyRect: NSRect) {
        guard ThemeStyle.options.palette != .system, !ThemeStyle.highContrast, !effectiveAppearance.isHighContrast else {
            super.drawSelection(in: dirtyRect)
            return
        }
        guard selectionHighlightStyle != .none else { return }
        ThemeStyle.selection(emphasized: isEmphasized).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4).fill()
    }
}
