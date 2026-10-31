import AppKit
import Synchronization
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct PreferencesTests {
    @Test func processPreferencesAreIsolatedFromTheAppInEveryConfiguration() {
        #expect(Prefs.shared.defaults !== UserDefaults.standard)
        #expect(Prefs.shared.domainName.hasPrefix(Prefs.testPreferencesFolder.appending(path: "dev.strata.tests.").path))
        #expect(Prefs.shared === Prefs.shared)
    }

    @Test func isolatedPreferencesLeaveNoSuiteOrFileOnceReleased() async throws {
        var prefs: Prefs? = try Prefs.isolated()
        let domain = try #require(prefs?.domainName)
        #expect(domain.hasPrefix(Prefs.testPreferencesFolder.path))
        let file = URL(filePath: domain + ".plist")
        prefs?.showHidden = true
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: file.path) { try await Task.sleep(for: .milliseconds(20)) }
        try #require(FileManager.default.fileExists(atPath: file.path))
        prefs = nil
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(UserDefaults.standard.persistentDomain(forName: domain)?.isEmpty ?? true)
    }

    @Test func newWindowLocationsPreserveLegacyChoicesAndPersistCustomFolders() throws {
        let prefs = try Prefs.isolated()
        let other = try Prefs.isolated()
        #expect(prefs.newWindowLocation == .lastVisited)
        #expect(prefs.customWindowFolder == nil)
        prefs.defaults.set(true, forKey: "newWindowsAtHome")
        #expect(prefs.newWindowLocation == .home)
        prefs.defaults.set("unknown", forKey: "newWindowLocation")
        #expect(prefs.newWindowLocation == .home)
        prefs.defaults.set(false, forKey: "newWindowsAtHome")
        #expect(prefs.newWindowLocation == .lastVisited)
        let chosen = URL(fileURLWithPath: "/Volumes/Work/项目 folder", isDirectory: true)
        prefs.customWindowFolder = chosen
        prefs.newWindowLocation = .custom
        let reopened = Prefs(defaults: try #require(UserDefaults(suiteName: prefs.domainName)),
                             domainName: prefs.domainName)
        #expect(reopened.newWindowLocation == .custom)
        #expect(reopened.customWindowFolder == chosen)
        reopened.newWindowLocation = .home
        #expect(reopened.customWindowFolder == chosen)
        #expect(other.newWindowLocation == .lastVisited)
        #expect(other.customWindowFolder == nil)
        prefs.defaults.set("relative/path", forKey: "customWindowFolder")
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
        let defaults = try #require(ThrowawayDefaults.make())
        let before = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        let prefs = Prefs(defaults: defaults, domainName: defaults.domain)
        _ = prefs.foldersFirst
        _ = prefs.gridIconSize
        #expect(NSDictionary(dictionary: before).isEqual(to: defaults.volatileDomain(forName: UserDefaults.registrationDomain)))
        #expect(prefs.defaults.persistentDomain(forName: defaults.domain)?.isEmpty ?? true)
    }

    @Test func typedSettingsPreserveNativeDefaultsAndExistingKeys() throws {
        let prefs = try Prefs.isolated()
        prefs.defaults.set(true, forKey: "showHiddenFiles")
        prefs.defaults.set(false, forKey: "foldersFirst")
        prefs.defaults.set("size", forKey: "sortColumn")
        prefs.defaults.set(false, forKey: "sortAscending")
        prefs.defaults.set(96.0, forKey: "gridIconSize")
        #expect(prefs.showHidden && !prefs.foldersFirst)
        #expect(prefs.sortColumn == "size" && !prefs.sortAscending)
        #expect(prefs.gridIconSize == 96)
        prefs.defaults.set("NO", forKey: "foldersFirst")
        prefs.defaults.set("144", forKey: "gridIconSize")
        #expect(!prefs.foldersFirst && prefs.gridIconSize == 144)
        prefs.defaults.removeObject(forKey: "foldersFirst")
        prefs.defaults.removeObject(forKey: "gridIconSize")
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
        prefs.nameTextSize = .nan
        #expect(prefs.nameTextSize == 13 && FileViewTypography(preferences: prefs).font.pointSize == 13)
        prefs.sortColumn = "future-column"
        #expect(prefs.sortColumn == "name")
        prefs.favoritePaths = ["/one", "/two"]
        prefs.collapsedSidebarSections = ["volumes", "favorites"]
        prefs.hiddenListColumns = ["size", "created"]
        prefs.iconViewOptions = .init(showsInfo: false, folderInfo: .size)
        prefs.colorThemeOptions = .init(palette: .teal, tintsWindow: false)
        prefs.lastLocation = URL(fileURLWithPath: "/one", isDirectory: true)
        let reopened = Prefs(defaults: try #require(UserDefaults(suiteName: prefs.domainName)),
                             domainName: prefs.domainName)
        #expect(reopened.dualPaneAddressBars)
        #expect(reopened.favoritePaths == ["/one", "/two"])
        #expect(reopened.collapsedSidebarSections == ["favorites", "volumes"])
        #expect(reopened.hiddenListColumns == ["size", "created"])
        #expect(reopened.iconViewOptions == .init(showsInfo: false, folderInfo: .size))
        #expect(reopened.colorThemeOptions == .init(palette: .teal, tintsWindow: false))
        #expect(reopened.lastLocation?.path == "/one")
        #expect(prefs.defaults.stringArray(forKey: "collapsedSidebarSections") == ["favorites", "volumes"])
    }

    @Test func independentSettingsDoNotChangeEachOtherOrBroadcastToOtherEnvironments() throws {
        let first = try Prefs.isolated()
        let second = try Prefs.isolated()
        let events = Mutex<[String]>([])
        let names: [Notification.Name] = [.prefsChanged, .appearanceChanged, .favoritesChanged,
                                         .viewOptionsChanged, .listColumnsChanged, .colorThemeChanged]
        var observers: [(NotificationCenter, NSObjectProtocol)] = []
        for (label, center) in [("first", first.notifications), ("second", second.notifications),
                                ("global", NotificationCenter.default)] {
            for name in names {
                let observer = center.addObserver(forName: name, object: nil, queue: nil) { _ in
                    events.withLock { $0.append(label + ":" + name.rawValue) }
                }
                observers.append((center, observer))
            }
        }
        defer { for (center, observer) in observers { center.removeObserver(observer) } }
        first.showHidden = true
        first.theme = 2
        first.favoritePaths = ["/one"]
        first.iconViewOptions = .init(showsInfo: false, folderInfo: .size)
        first.hiddenListColumns = ["size"]
        first.colorThemeOptions = .init(palette: .rose)
        first.colorThemeOptions = .init(palette: .rose)
        #expect(events.withLock { $0 } == names.map { "first:" + $0.rawValue })
        #expect(!second.showHidden)
        #expect(second.theme == 0)
        #expect(second.favoritePaths == nil)
        #expect(second.iconViewOptions == IconViewOptions())
        #expect(second.colorThemeOptions == ColorThemeOptions())
        #expect(second.defaults.persistentDomain(forName: second.domainName)?.isEmpty ?? true)
        second.favoritePaths = []
        #expect(first.favoritePaths == ["/one"])
        #expect(second.favoritePaths == [])
    }

    @Test func languageOverrideUsesOnlyItsOwnPersistentDomain() throws {
        let domain = try Prefs.isolated()
        let fallback = try Prefs.isolated()
        fallback.language = "fr"
        domain.defaults.addSuite(named: fallback.domainName)
        defer { domain.defaults.removeSuite(named: fallback.domainName) }
        #expect(domain.defaults.stringArray(forKey: "AppleLanguages") == ["fr"])
        #expect(domain.language == "")
        domain.language = "de"
        #expect(domain.language == "de")
        #expect(domain.defaults.persistentDomain(forName: domain.domainName)?["AppleLanguages"] as? [String] == ["de"])
        domain.language = ""
        #expect(domain.language == "")
        #expect(domain.defaults.persistentDomain(forName: domain.domainName)?["AppleLanguages"] == nil)
        #expect(domain.defaults.stringArray(forKey: "AppleLanguages") == ["fr"])
        #expect(fallback.language == "fr")
    }

    @Test func visitHistoryUsesItsOwnPreferencesAndKeepsRankingAfterReopening() throws {
        let tree = try TestTree("frequent/", "recent/", "other/")
        let first = try Prefs.isolated()
        let second = try Prefs.isolated()
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
