import AppKit
import Testing
@testable import Strata
@testable import StrataModel

/// A cloud account (Dropbox, iCloud Drive…) starts the path bar in a tinted crumb of its own, in place of Home ›
/// Library › CloudStorage, unless Settings ▸ Appearance turns that off. Worked out from the path alone.
@MainActor struct PathBarCloudTests {
    private let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)

    private func crumbs(_ relative: String, cloudRoots: Bool = true, in environment: IndependentEnvironment)
        -> [PathBar.Crumb] {
        PathBar.localComponents(of: home.appending(path: relative), copies: environment.services.copies,
                                names: environment.services.folderNames, home: home, cloudRoots: cloudRoots)
    }

    private func titles(_ crumbs: [PathBar.Crumb]) -> [String] { crumbs.map(\.title) }

    @Test func aDropboxFolderStartsWithItsAccount() throws {
        let environment = try IndependentEnvironment()
        let parts = crumbs("Library/CloudStorage/Dropbox/DIY MYOG/Holz", in: environment)
        #expect(titles(parts) == ["Dropbox", "DIY MYOG", "Holz"])
        #expect(parts.map(\.cloud) == [.dropbox, nil, nil])
        #expect(parts[0].url.path == "/Users/someone/Library/CloudStorage/Dropbox")
        #expect(parts[2].url.path == "/Users/someone/Library/CloudStorage/Dropbox/DIY MYOG/Holz")
        // The account folder itself is one crumb.
        #expect(titles(crumbs("Library/CloudStorage/Dropbox", in: environment)) == ["Dropbox"])
    }

    @Test func eachServiceIsToldByItsAccountFolder() throws {
        let environment = try IndependentEnvironment()
        #expect(crumbs("Library/CloudStorage/GoogleDrive-you@example.com/Work", in: environment).first?.cloud == .googleDrive)
        #expect(crumbs("Library/CloudStorage/OneDrive-Personal", in: environment).first?.cloud == .oneDrive)
        #expect(crumbs("Library/CloudStorage/Box-Box/a", in: environment).first?.cloud == .box)
        #expect(crumbs("Library/CloudStorage/pCloudDrive/a", in: environment).first?.cloud == .other)
        let iCloud = crumbs("Library/Mobile Documents/com~apple~CloudDocs/Notes", in: environment)
        #expect(iCloud.map(\.cloud) == [.iCloud, nil])
        #expect(titles(iCloud) == ["iCloud Drive", "Notes"])
    }

    @Test func pathsOutsideAnAccountAndTheSettingOffKeepHomeFirst() throws {
        let environment = try IndependentEnvironment()
        #expect(crumbs("Library/CloudStorage", in: environment).map(\.cloud) == [nil, nil, nil])
        #expect(crumbs("Library/CloudStorage", in: environment).first?.symbol == "house.fill")
        #expect(crumbs("Library/Mobile Documents/other", in: environment).allSatisfy { $0.cloud == nil })
        let off = crumbs("Library/CloudStorage/Dropbox/DIY MYOG", cloudRoots: false, in: environment)
        #expect(off.first?.symbol == "house.fill")
        #expect(titles(off).dropFirst() == ["Library", "CloudStorage", "Dropbox", "DIY MYOG"])
        #expect(off.allSatisfy { $0.cloud == nil })
    }

    @Test func theCloudCrumbKeepsItsTintAfterThePointerLeaves() {
        let crumb = CrumbButton(title: "Dropbox", symbol: nil, emphasized: false, cloud: .dropbox)
        let resting = crumb.layer?.backgroundColor
        #expect(resting != nil)
        crumb.setHighlight(true)
        #expect(crumb.layer?.backgroundColor != resting)
        crumb.setHighlight(false)
        #expect(crumb.layer?.backgroundColor == resting)
        // Other crumbs show only a hover fill.
        let plain = CrumbButton(title: "Holz", symbol: nil, emphasized: false)
        plain.setHighlight(true)
        plain.setHighlight(false)
        #expect(plain.layer?.backgroundColor == nil)
    }

    @Test func theSettingIsOnByDefaultAndSwitchesAnOpenPathBar() throws {
        let environment = try IndependentEnvironment()
        let preferences = environment.preferences
        #expect(preferences.cloudRootCrumbs)
        let services = environment.services
        let bar = PathBar(preferences: preferences, places: services.places, index: services.index,
                          copies: services.copies, names: services.folderNames, clipboard: services.clipboard)
        bar.url = Places.home.appending(path: "Library/CloudStorage/Dropbox/DIY MYOG", directoryHint: .isDirectory)
        #expect(bar.crumbButtons.map(\.cloud) == [.dropbox, nil])

        var announced = 0
        let observer = preferences.notifications.addObserver(forName: .appearanceChanged, object: nil, queue: nil) { _ in
            announced += 1
        }
        defer { preferences.notifications.removeObserver(observer) }
        preferences.cloudRootCrumbs = false
        #expect(announced == 1)
        #expect(!preferences.cloudRootCrumbs)
        #expect(bar.crumbButtons.count == 5 && bar.crumbButtons.allSatisfy { $0.cloud == nil })
        preferences.cloudRootCrumbs = true
        #expect(bar.crumbButtons.map(\.cloud) == [.dropbox, nil])
    }
}
