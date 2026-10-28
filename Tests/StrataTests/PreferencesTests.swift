import AppKit
import Synchronization
import Testing
@testable import Strata

struct PreferencesTests {
    private final class Domain {
        let name = "StrataPreferencesTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let preferences: Prefs

        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
            preferences = Prefs(defaults: defaults, domainName: name)
        }

        isolated deinit { defaults.removePersistentDomain(forName: name) }
    }

    @Test func processPreferencesAreIsolatedFromTheAppInEveryConfiguration() {
        #expect(Prefs.shared.defaults !== UserDefaults.standard)
        #expect(Prefs.shared.domainName.hasPrefix("dev.strata.tests."))
        #expect(Prefs.shared === Prefs.shared)
    }

    @Test func newWindowLocationsPreserveLegacyChoicesAndPersistCustomFolders() throws {
        let domain = try Domain()
        let other = try Domain()
        let prefs = domain.preferences
        #expect(prefs.newWindowLocation == .lastVisited)
        #expect(prefs.customWindowFolder == nil)
        domain.defaults.set(true, forKey: "newWindowsAtHome")
        #expect(prefs.newWindowLocation == .home)
        domain.defaults.set("unknown", forKey: "newWindowLocation")
        #expect(prefs.newWindowLocation == .home)
        domain.defaults.set(false, forKey: "newWindowsAtHome")
        #expect(prefs.newWindowLocation == .lastVisited)
        let chosen = URL(fileURLWithPath: "/Volumes/Work/项目 folder", isDirectory: true)
        prefs.customWindowFolder = chosen
        prefs.newWindowLocation = .custom
        let reopened = Prefs(defaults: try #require(UserDefaults(suiteName: domain.name)), domainName: domain.name)
        #expect(reopened.newWindowLocation == .custom)
        #expect(reopened.customWindowFolder == chosen)
        reopened.newWindowLocation = .home
        #expect(reopened.customWindowFolder == chosen)
        #expect(other.preferences.newWindowLocation == .lastVisited)
        #expect(other.preferences.customWindowFolder == nil)
        domain.defaults.set("relative/path", forKey: "customWindowFolder")
        #expect(prefs.customWindowFolder == nil)
        prefs.customWindowFolder = URL(string: "https://example.com/folder")
        #expect(prefs.customWindowFolder == nil)
    }

    @Test func newWindowLocationUsesTheChosenPolicyAndFallsBackWithoutChangingIt() throws {
        let tree = try TestTree("home/", "last/", "current/", "custom/", "file", "alias -> custom", "broken -> missing")
        let home = tree.url("home")
        let last = tree.url("last")
        let current = tree.url("current")
        let custom = tree.url("custom")
        for choice in NewWindowLocation.allCases {
            let folder = choice.folder(custom: custom, last: last, current: current, home: home)
            #expect(folder == (choice == .home ? home : choice == .custom ? custom : current))
        }
        #expect(NewWindowLocation.lastVisited.folder(custom: custom, last: last, home: home) == last)
        #expect(NewWindowLocation.custom.folder(custom: custom, last: last, home: home) == custom)
        #expect(NewWindowLocation.custom.folder(custom: tree.url("alias"), last: last, home: home) == tree.url("alias"))
        for missing in [nil, tree.url("missing"), tree.url("file"), tree.url("broken"), URL(string: "sftp://host/folder")] {
            #expect(NewWindowLocation.custom.folder(custom: missing, last: last, current: current, home: home) == home)
        }
        #expect(NewWindowLocation.custom.folder(custom: custom, last: last, home: home, available: { _ in false }) == home)
        #expect(NewWindowLocation.lastVisited.folder(custom: custom, last: nil, home: home) == home)
        #expect(tree.snapshot() == ["alias -> custom", "broken -> missing", "current/", "custom/", "file", "home/", "last/"])
    }

    @Test func creatingPreferencesDoesNotRegisterProcessWideDefaults() throws {
        let name = "StrataPreferencesRegistrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let before = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        let prefs = Prefs(defaults: defaults, domainName: name)
        _ = prefs.foldersFirst
        _ = prefs.gridIconSize
        #expect(NSDictionary(dictionary: before).isEqual(to: defaults.volatileDomain(forName: UserDefaults.registrationDomain)))
        #expect(prefs.defaults.persistentDomain(forName: name)?.isEmpty ?? true)
    }

    @Test func typedSettingsPreserveNativeDefaultsAndExistingKeys() throws {
        let domain = try Domain()
        let prefs = domain.preferences
        domain.defaults.set(true, forKey: "showHiddenFiles")
        domain.defaults.set(false, forKey: "foldersFirst")
        domain.defaults.set("size", forKey: "sortColumn")
        domain.defaults.set(false, forKey: "sortAscending")
        domain.defaults.set(96.0, forKey: "gridIconSize")
        #expect(prefs.showHidden && !prefs.foldersFirst)
        #expect(prefs.sortColumn == "size" && !prefs.sortAscending)
        #expect(prefs.gridIconSize == 96)
        domain.defaults.set("NO", forKey: "foldersFirst")
        domain.defaults.set("144", forKey: "gridIconSize")
        #expect(!prefs.foldersFirst && prefs.gridIconSize == 144)
        domain.defaults.removeObject(forKey: "foldersFirst")
        domain.defaults.removeObject(forKey: "gridIconSize")
        #expect(prefs.foldersFirst && prefs.gridIconSize == 72)
        #expect(prefs.reopenWindows && prefs.openArchivesAsFolders && prefs.showIconPreviews)
        #expect(!prefs.dualPaneAddressBars)
        #expect(prefs.density == 1 && prefs.nameTextSize == 13)
        #expect(prefs.favoritePaths == nil)
        prefs.dualPaneAddressBars = true
        #expect(prefs.dualPaneAddressBars)
        prefs.newFileExtension = ".md"
        #expect(prefs.newFileExtension == "md")
        prefs.newFileExtension = "../bad"
        #expect(prefs.newFileExtension == "md")
        prefs.nameTextSize = 100
        #expect(prefs.nameTextSize == 16)
        prefs.nameTextSize = 1
        #expect(prefs.nameTextSize == 11)
        prefs.sortColumn = "future-column"
        #expect(prefs.sortColumn == "name")
        prefs.favoritePaths = ["/one", "/two"]
        prefs.collapsedSidebarSections = ["volumes", "favorites"]
        prefs.hiddenListColumns = ["size", "created"]
        prefs.iconViewOptions = .init(showsInfo: false, folderInfo: .size)
        prefs.colorThemeOptions = .init(palette: .teal, tintsWindow: false)
        prefs.lastLocation = URL(fileURLWithPath: "/one", isDirectory: true)
        let reopened = Prefs(defaults: try #require(UserDefaults(suiteName: domain.name)), domainName: domain.name)
        #expect(reopened.dualPaneAddressBars)
        #expect(reopened.favoritePaths == ["/one", "/two"])
        #expect(reopened.collapsedSidebarSections == ["favorites", "volumes"])
        #expect(reopened.hiddenListColumns == ["size", "created"])
        #expect(reopened.iconViewOptions == .init(showsInfo: false, folderInfo: .size))
        #expect(reopened.colorThemeOptions == .init(palette: .teal, tintsWindow: false))
        #expect(reopened.lastLocation?.path == "/one")
        #expect(domain.defaults.stringArray(forKey: "collapsedSidebarSections") == ["favorites", "volumes"])
    }

    @Test func independentSettingsDoNotChangeEachOtherOrBroadcastToOtherEnvironments() throws {
        let first = try Domain()
        let second = try Domain()
        let events = Mutex<[String]>([])
        let names: [Notification.Name] = [.prefsChanged, .appearanceChanged, .favoritesChanged,
                                         .viewOptionsChanged, .listColumnsChanged, .colorThemeChanged]
        var observers: [(NotificationCenter, NSObjectProtocol)] = []
        for (label, center) in [("first", first.preferences.notifications), ("second", second.preferences.notifications),
                                ("global", NotificationCenter.default)] {
            for name in names {
                let observer = center.addObserver(forName: name, object: nil, queue: nil) { _ in
                    events.withLock { $0.append(label + ":" + name.rawValue) }
                }
                observers.append((center, observer))
            }
        }
        defer { for (center, observer) in observers { center.removeObserver(observer) } }
        first.preferences.showHidden = true
        first.preferences.theme = 2
        first.preferences.favoritePaths = ["/one"]
        first.preferences.iconViewOptions = .init(showsInfo: false, folderInfo: .size)
        first.preferences.hiddenListColumns = ["size"]
        first.preferences.colorThemeOptions = .init(palette: .rose)
        first.preferences.colorThemeOptions = .init(palette: .rose)
        #expect(events.withLock { $0 } == names.map { "first:" + $0.rawValue })
        #expect(!second.preferences.showHidden)
        #expect(second.preferences.theme == 0)
        #expect(second.preferences.favoritePaths == nil)
        #expect(second.preferences.iconViewOptions == IconViewOptions())
        #expect(second.preferences.colorThemeOptions == ColorThemeOptions())
        #expect(second.defaults.persistentDomain(forName: second.name)?.isEmpty ?? true)
        second.preferences.favoritePaths = []
        #expect(first.preferences.favoritePaths == ["/one"])
        #expect(second.preferences.favoritePaths == [])
    }

    @Test func languageOverrideUsesOnlyItsOwnPersistentDomain() throws {
        let domain = try Domain()
        let fallback = try Domain()
        fallback.preferences.language = "fr"
        domain.defaults.addSuite(named: fallback.name)
        defer { domain.defaults.removeSuite(named: fallback.name) }
        #expect(domain.defaults.stringArray(forKey: "AppleLanguages") == ["fr"])
        #expect(domain.preferences.language == "")
        domain.preferences.language = "de"
        #expect(domain.preferences.language == "de")
        #expect(domain.defaults.persistentDomain(forName: domain.name)?["AppleLanguages"] as? [String] == ["de"])
        domain.preferences.language = ""
        #expect(domain.preferences.language == "")
        #expect(domain.defaults.persistentDomain(forName: domain.name)?["AppleLanguages"] == nil)
        #expect(domain.defaults.stringArray(forKey: "AppleLanguages") == ["fr"])
        #expect(fallback.preferences.language == "fr")
    }

    @Test func visitHistoryUsesItsOwnPreferencesAndKeepsRankingAfterReopening() throws {
        let tree = try TestTree("frequent/", "recent/", "other/")
        let first = try Domain()
        let second = try Domain()
        let date = Date(timeIntervalSince1970: 100_000)
        let history = Frecency(preferences: first.defaults, now: { date })
        for _ in 0..<3 { history.record(tree.url("frequent")) }
        history.record(tree.url("recent"))
        let other = Frecency(preferences: second.defaults, now: { date })
        other.record(tree.url("other"))
        #expect(history.ranked().map(\.lastPathComponent) == ["frequent", "recent"])
        #expect(other.ranked().map(\.lastPathComponent) == ["other"])
        let reopened = Frecency(preferences: first.defaults, now: { date.addingTimeInterval(86_400) })
        #expect(reopened.ranked().map(\.lastPathComponent) == ["frequent", "recent"])
        // A fresh visit outweighs the older visits, without depending on the wall clock during a test run.
        reopened.record(tree.url("recent"))
        #expect(reopened.ranked().map(\.lastPathComponent) == ["recent", "frequent"])
        #expect(Frecency(preferences: second.defaults, now: { date }).ranked().map(\.lastPathComponent) == ["other"])
        #expect(Frecency(preferences: first.defaults, now: { date.addingTimeInterval(86_400) }).ranked().map(\.lastPathComponent)
                == ["recent", "frequent"])
        #expect(tree.snapshot() == ["frequent/", "other/", "recent/"])
    }
}
