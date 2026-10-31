import AppKit

extension Notification.Name {
    package static let prefsChanged = Notification.Name("StrataPrefsChanged")
    /// Theme, density or text size changed (Settings ▸ Appearance): views restyle, nothing reloads.
    package static let appearanceChanged = Notification.Name("StrataAppearanceChanged")
    /// Palette or window tint changed: redraw without reloading file views.
    package static let colorThemeChanged = Notification.Name("StrataColorThemeChanged")
    package static let favoritesChanged = Notification.Name("StrataFavoritesChanged")
    /// A list column was shown or hidden (right-click the column titles): every list follows.
    package static let listColumnsChanged = Notification.Name("StrataListColumnsChanged")
    package static let viewOptionsChanged = Notification.Name("StrataViewOptionsChanged")
    package static let previewOptionsChanged = Notification.Name("StrataPreviewOptionsChanged")
    /// A sidebar section was hidden or shown: every window's sidebar follows.
    package static let sidebarSectionsCollapsed = Notification.Name("StrataSidebarSectionsCollapsed")
}

/// Typed app settings. Production shares one instance; independent environments supply their own defaults and
/// notification center, so changing a fixture never reloads another environment's views.
package final class Prefs {
    private static var selected: Prefs?
    /// A test process keeps its settings here, in a folder of its own, not in ~/Library/Preferences: the system can
    /// write a test suite's file back after its process exits, and only a temporary folder can take those late writes.
    package nonisolated static let testPreferencesFolder = FileManager.default.temporaryDirectory
        .appending(path: "StrataTestPreferences/\(getpid())", directoryHint: .isDirectory)
    nonisolated private static let testDomain = testPreferencesFolder
        .appending(path: "dev.strata.tests.\(UUID().uuidString)").path

    package static func useApplicationPreferences() {
        precondition(selected == nil, "Configure preferences before creating app services")
        selected = Prefs(defaults: .standard, domainName: Bundle.main.bundleIdentifier ?? "dev.strata.app",
                         notifications: .default)
    }

    package static var shared: Prefs {
        if let selected { return selected }
        guard let defaults = UserDefaults(suiteName: testDomain) else {
            preconditionFailure("Unable to create isolated test preferences")
        }
        let made = Prefs(defaults: defaults, domainName: testDomain, notifications: .default)
        selected = made
        registerTestCleanup()
        return made
    }

    private nonisolated static func registerTestCleanup() {
        // The test runner can exit from a worker thread; a C exit callback must not inherit MainActor isolation.
        atexit {
            UserDefaults.standard.removePersistentDomain(forName: Prefs.testDomain)
            // Emptying a suite leaves its file behind.
            try? FileManager.default.removeItem(atPath: Prefs.testDomain + ".plist")
        }
    }

    package let defaults: UserDefaults
    package let domainName: String
    package let notifications: NotificationCenter

    package init(defaults: UserDefaults, domainName: String, notifications: NotificationCenter = NotificationCenter()) {
        self.defaults = defaults
        self.domainName = domainName
        self.notifications = notifications
    }

    private enum Key {
        static let showHidden = "showHiddenFiles"
        static let foldersFirst = "foldersFirst"
        static let lastLocation = "lastLocation"
        static let returnOpens = "returnOpens"
        static let terminal = "terminalApp"
        static let newWindowsAtHome = "newWindowsAtHome"
        static let newWindowLocation = "newWindowLocation"
        static let customWindowFolder = "customWindowFolder"
        static let viewMode = "viewMode"
        static let gridIconSize = "gridIconSize"
        static let previewViewMode = "previewViewMode"
        static let previewIconSize = "previewIconSize"
        static let previewWindowSize = "previewWindowSize"
        static let previewBrowserFraction = "previewBrowserFraction"
        static let previewColumnWidths = "previewColumnWidths"
        static let verifyCopies = "verifyCopies"
        static let favoritePaths = "favoritePaths"
        static let reopenWindows = "reopenWindows"
        static let openArchivesAsFolders = "openArchivesAsFolders"
        static let theme = "theme"
        static let density = "density"
        static let nameTextSize = "nameTextSize"
        static let showIconPreviews = "showIconPreviews"
        static let sidebarShowsTree = "sidebarShowsTree"
        static let sortColumn = "sortColumn"
        static let sortAscending = "sortAscending"
        static let hiddenListColumns = "hiddenListColumns"
        static let toolbarItems = "toolbarItems"
        static let toolbarDisplayMode = "toolbarDisplayMode"
        static let knownListColumns = "knownListColumns"
        static let dockSearch = "dockSearch"
        static let collapsedSidebarSections = "collapsedSidebarSections"
        static let newFileExtension = "newFileExtension"
        static let dualPaneAddressBars = "dualPaneAddressBars"
    }

    /// An explicit app-language override. An empty value lets macOS choose the language on the next launch.
    package var language: String {
        get { (defaults.persistentDomain(forName: domainName)?["AppleLanguages"] as? [String])?.first ?? "" }
        set {
            if newValue.isEmpty { defaults.removeObject(forKey: "AppleLanguages") }
            else { defaults.set([newValue], forKey: "AppleLanguages") }
        }
    }

    package var showHidden: Bool {
        get { defaults.bool(forKey: Key.showHidden) }
        set { defaults.set(newValue, forKey: Key.showHidden); notifications.post(name: .prefsChanged, object: nil) }
    }

    /// The sidebar shows the folder tree instead of Favorites, Locations and the rest.
    package var sidebarShowsTree: Bool {
        get { defaults.bool(forKey: Key.sidebarShowsTree) }
        set { defaults.set(newValue, forKey: Key.sidebarShowsTree); notifications.post(name: .prefsChanged, object: nil) }
    }

    /// In Dual Pane, each pane shows its own path bar instead of just the folder name.
    package var dualPaneAddressBars: Bool {
        get { defaults.bool(forKey: Key.dualPaneAddressBars) }
        set { defaults.set(newValue, forKey: Key.dualPaneAddressBars); notifications.post(name: .prefsChanged, object: nil) }
    }

    /// Sidebar sections you've hidden (Hide on a section's title), by ID: they stay hidden until you show them again.
    package var collapsedSidebarSections: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.collapsedSidebarSections) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.collapsedSidebarSections) }
    }

    /// The extension File ▸ New File gives the file ("txt" until you change it; empty for none).
    package var newFileExtension: String {
        get { defaults.string(forKey: Key.newFileExtension).flatMap(FileOps.newFileExtension) ?? "txt" }
        set {
            guard let clean = FileOps.newFileExtension(newValue) else { return }
            defaults.set(clean, forKey: Key.newFileExtension)
        }
    }

    package var foldersFirst: Bool {
        get { defaults.object(forKey: Key.foldersFirst) == nil ? true : defaults.bool(forKey: Key.foldersFirst) }
        set { defaults.set(newValue, forKey: Key.foldersFirst); notifications.post(name: .prefsChanged, object: nil) }
    }

    /// Return opens the selection instead of renaming it (Finder renames).
    package var returnOpens: Bool {
        get { defaults.bool(forKey: Key.returnOpens) }
        set { defaults.set(newValue, forKey: Key.returnOpens) }
    }

    /// Bundle id of the terminal for "Open in Terminal"; nil picks the first installed of Ghostty, iTerm, Warp, Terminal.
    package var terminal: String? {
        get { defaults.string(forKey: Key.terminal) }
        set { defaults.set(newValue, forKey: Key.terminal) }
    }

    package var viewMode: Int {
        get { defaults.integer(forKey: Key.viewMode) }
        set { defaults.set(newValue, forKey: Key.viewMode) }
    }

    package var gridIconSize: Double {
        get {
            guard defaults.object(forKey: Key.gridIconSize) != nil else { return 72 }
            let value = defaults.double(forKey: Key.gridIconSize)
            return value.isFinite ? min(max(value, 32), 256) : 72
        }
        set {
            defaults.set(newValue, forKey: Key.gridIconSize)
            notifications.post(name: .viewOptionsChanged, object: nil)
        }
    }

    package var previewViewMode: PreviewViewMode {
        get { PreviewViewMode(rawValue: defaults.integer(forKey: Key.previewViewMode)) ?? .list }
        set {
            defaults.set(newValue.rawValue, forKey: Key.previewViewMode)
            notifications.post(name: .previewOptionsChanged, object: nil)
        }
    }

    package var previewIconSize: Double {
        get {
            let value = defaults.object(forKey: Key.previewIconSize) as? Double ?? 80
            return value.isFinite ? min(max(value, 32), 256) : 80
        }
        set {
            defaults.set(newValue.isFinite ? min(max(newValue, 32), 256) : 80, forKey: Key.previewIconSize)
            notifications.post(name: .previewOptionsChanged, object: nil)
        }
    }

    package var previewWindowSize: NSSize? {
        get {
            guard let values = defaults.array(forKey: Key.previewWindowSize) as? [Double], values.count == 2 else { return nil }
            let size = NSSize(width: values[0], height: values[1])
            return PreviewLayout.validSize(size) ? size : nil
        }
        set {
            if let size = newValue, PreviewLayout.validSize(size) {
                defaults.set([size.width, size.height], forKey: Key.previewWindowSize)
            } else { defaults.removeObject(forKey: Key.previewWindowSize) }
        }
    }

    package var previewBrowserFraction: CGFloat {
        get {
            let value = defaults.object(forKey: Key.previewBrowserFraction) as? Double ?? PreviewLayout.defaultBrowserFraction
            return value.isFinite && value > 0 && value < 1 ? value : PreviewLayout.defaultBrowserFraction
        }
        set {
            guard newValue.isFinite, newValue > 0, newValue < 1 else { return }
            defaults.set(newValue, forKey: Key.previewBrowserFraction)
        }
    }

    package var previewColumnWidths: [String: Double] {
        get {
            (defaults.dictionary(forKey: Key.previewColumnWidths) ?? [:]).compactMapValues {
                guard let value = $0 as? Double, value.isFinite, (64...320).contains(value) else { return nil }
                return value
            }
        }
        set { defaults.set(newValue.filter { $0.value.isFinite && (64...320).contains($0.value) }, forKey: Key.previewColumnWidths) }
    }

    package var iconViewOptions: IconViewOptions {
        get { IconViewOptions.read(from: defaults) }
        set {
            newValue.save(in: defaults)
            notifications.post(name: .viewOptionsChanged, object: nil)
        }
    }

    /// The sidebar's favorite folders once you've changed them (nil: the defaults).
    package var favoritePaths: [String]? {
        get { defaults.stringArray(forKey: Key.favoritePaths) }
        set {
            defaults.set(newValue, forKey: Key.favoritePaths)
            notifications.post(name: .favoritesChanged, object: nil)
        }
    }

    /// Open the windows and tabs of the last session at launch.
    package var reopenWindows: Bool {
        get { defaults.object(forKey: Key.reopenWindows) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.reopenWindows) }
    }

    /// Opening a zip (or another archive) shows what's inside, like a folder, instead of unpacking it.
    package var openArchivesAsFolders: Bool {
        get { defaults.object(forKey: Key.openArchivesAsFolders) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.openArchivesAsFolders) }
    }

    /// 0 follows the system, 1 is always light, 2 always dark.
    package var theme: Int {
        get { defaults.integer(forKey: Key.theme) }
        set { defaults.set(newValue, forKey: Key.theme); notifications.post(name: .appearanceChanged, object: nil) }
    }

    package var colorThemeOptions: ColorThemeOptions {
        get { ColorThemeOptions.read(from: defaults) }
        set {
            guard newValue != colorThemeOptions else { return }
            newValue.save(in: defaults)
            notifications.post(name: .colorThemeChanged, object: nil)
        }
    }

    /// Row spacing in the list and columns: 0 compact, 1 regular, 2 spacious.
    package var density: Int {
        get { min(max(defaults.object(forKey: Key.density) as? Int ?? 1, 0), 2) }
        set { defaults.set(newValue, forKey: Key.density); notifications.post(name: .appearanceChanged, object: nil) }
    }

    package static let defaultNameTextSize: Double = 13

    /// File names' text size in points (11–16).
    package var nameTextSize: Double {
        get {
            let value = defaults.object(forKey: Key.nameTextSize) as? Double ?? Self.defaultNameTextSize
            return value.isFinite ? min(max(value, 11), 16) : Self.defaultNameTextSize
        }
        set { defaults.set(newValue, forKey: Key.nameTextSize); notifications.post(name: .appearanceChanged, object: nil) }
    }

    /// Files show a Quick Look thumbnail of their contents in place of their icon, like Finder's "Show icon preview".
    package var showIconPreviews: Bool {
        get { defaults.object(forKey: Key.showIconPreviews) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showIconPreviews); notifications.post(name: .appearanceChanged, object: nil) }
    }

    /// Read every copied file back and compare it with the original (slower; catches failing disks and cables).
    package var verifyCopies: Bool {
        get { defaults.bool(forKey: Key.verifyCopies) }
        set { defaults.set(newValue, forKey: Key.verifyCopies) }
    }

    package var newWindowLocation: NewWindowLocation {
        get {
            if let raw = defaults.string(forKey: Key.newWindowLocation), let choice = NewWindowLocation(rawValue: raw) {
                return choice
            }
            return defaults.bool(forKey: Key.newWindowsAtHome) ? .home : .lastVisited
        }
        set { defaults.set(newValue.rawValue, forKey: Key.newWindowLocation) }
    }

    package var customWindowFolder: URL? {
        get {
            guard let path = defaults.string(forKey: Key.customWindowFolder), path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            if let newValue, newValue.isFileURL { defaults.set(newValue.path, forKey: Key.customWindowFolder) }
            else { defaults.removeObject(forKey: Key.customWindowFolder) }
        }
    }

    package let terminals: [(name: String, bundleID: String)] = [
        ("Ghostty", "com.mitchellh.ghostty"), ("iTerm", "com.googlecode.iterm2"), ("Warp", "dev.warp.Warp-Stable"),
        ("Terminal", "com.apple.Terminal"),
    ]

    /// The terminal Open in Terminal uses: the one chosen in Settings, else the first installed of `terminals`.
    package func terminalApp() async -> URL? {
        await Self.firstInstalled((terminal.map { [$0] } ?? []) + terminals.map(\.bundleID))
    }

    /// The first of `bundleIDs` installed, asked of LaunchServices away from the main thread.
    @concurrent package nonisolated static func firstInstalled(_ bundleIDs: [String]) async -> URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    /// Those of `bundleIDs` installed, asked the same way.
    @concurrent package nonisolated static func installed(_ bundleIDs: [String]) async -> Set<String> {
        Set(bundleIDs.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
    }

    /// Native toolbar layouts use this environment rather than AppKit's process-wide defaults.
    package var toolbarItems: [String]? {
        get { defaults.stringArray(forKey: Key.toolbarItems) }
        set { defaults.set(newValue, forKey: Key.toolbarItems) }
    }

    package var toolbarDisplayMode: Int {
        get {
            let value = defaults.integer(forKey: Key.toolbarDisplayMode)
            return (1...3).contains(value) ? value : 2
        }
        set { defaults.set((1...3).contains(newValue) ? newValue : 2, forKey: Key.toolbarDisplayMode) }
    }

    /// List sort from the last session. Unknown or missing values are Name, ascending.
    package var sortColumn: String {
        get {
            let stored = defaults.string(forKey: Key.sortColumn) ?? SortKey.name.rawValue
            return SortKey(rawValue: stored)?.rawValue ?? SortKey.name.rawValue
        }
        set { defaults.set(newValue, forKey: Key.sortColumn) }
    }

    package var sortAscending: Bool {
        get { defaults.object(forKey: Key.sortAscending) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.sortAscending) }
    }

    /// Settings ▸ General ▸ Search box in the Dock (see `DockSearch`). Off until you turn it on.
    package var dockSearch: Bool {
        get { defaults.bool(forKey: Key.dockSearch) }
        set { defaults.set(newValue, forKey: Key.dockSearch) }
    }

    /// The list columns you've hidden, by identifier. Date Created starts hidden, as in Finder.
    package var hiddenListColumns: Set<String> {
        get { ListColumn.hidden(stored: defaults.stringArray(forKey: Key.hiddenListColumns),
                                known: defaults.stringArray(forKey: Key.knownListColumns)) }
        set {
            defaults.set(newValue.sorted(), forKey: Key.hiddenListColumns)
            defaults.set(ListColumn.allCases.map(\.rawValue), forKey: Key.knownListColumns)
            notifications.post(name: .listColumnsChanged, object: nil)
        }
    }

    package var lastLocation: URL? {
        get { defaults.string(forKey: Key.lastLocation).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) } }
        set { defaults.set(newValue?.path, forKey: Key.lastLocation) }
    }
}
