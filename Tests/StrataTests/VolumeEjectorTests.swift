import AppKit
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSupport

/// Stands in for macOS: records each disk it's asked to eject and holds it until the test answers.
private actor HeldUnmounts {
    private(set) var asked: [URL] = []
    private var held: [CheckedContinuation<Void, any Error>] = []
    private var arrival: CheckedContinuation<Void, Never>?

    func unmount(_ volume: URL) async throws {
        asked.append(volume)
        arrival?.resume()
        arrival = nil
        try await withCheckedThrowingContinuation { held.append($0) }
    }

    func waitForAsks(_ count: Int) async {
        while asked.count < count { await withCheckedContinuation { arrival = $0 } }
    }

    func answerNext(throwing error: (any Error)? = nil) {
        guard !held.isEmpty else {
            Issue.record("No eject is waiting for an answer")
            return
        }
        let next = held.removeFirst()
        if let error { next.resume(throwing: error) } else { next.resume() }
    }
}

/// What the environment reported, kept where its report closures can add to it.
@MainActor private final class Reports<Item> {
    var items: [Item] = []
}

/// The eject button, its menus and ⌘E share one owner: it hands macOS only the root of a disk the latest read lists as
/// ejectable, once until it answers, and only after the disk has gone do panes on it go home.
@MainActor struct VolumeEjectorTests {
    private static func disk(_ url: URL, named title: String, ejectable: Bool = true) -> Place {
        Place(title: title, url: url, symbol: ejectable ? "externaldrive" : "internaldrive", isEjectable: ejectable)
    }

    private static func volumes(_ paths: String...) -> [URL] {
        paths.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// An environment whose disks are `disks`, as the places read has listed them, and whose ejects `unmounts` answers.
    private static func environment(disks: [Place], unmounts: HeldUnmounts,
                                     failed: @escaping VolumeEjector.Report = { _, _ in }) async throws -> IndependentEnvironment {
        let environment = try IndependentEnvironment(readPlaces: { _ in PlaceChecks.Snapshot(volumes: disks) },
                                                     unmount: { try await unmounts.unmount($0) }, ejectFailed: failed)
        environment.preferences.favoritePaths = []
        let places = environment.services.places
        places.refresh()
        while let read = places.task { await read.value }
        return environment
    }

    @Test func onlyTheRootOfAnEjectableDiskInTheLatestReadCanBeEjected() throws {
        let urls = Self.volumes("/Volumes/a", "/Volumes/ab", "/Volumes/a 1", "/Volumes/Data")
        let a = Self.disk(urls[0], named: "a"), ab = Self.disk(urls[1], named: "ab"), a1 = Self.disk(urls[2], named: "a 1")
        let data = Self.disk(urls[3], named: "Data", ejectable: false)
        // Even listed as ejectable, the startup disk never is.
        let startup = Self.disk(URL(filePath: "/", directoryHint: .isDirectory), named: "Macintosh HD")
        let disks = [startup, data, a, ab, a1]
        func decided(_ path: String, underway: Set<String> = []) -> Place? {
            VolumeEjector.volume(URL(filePath: path), among: disks, underway: underway)
        }
        #expect(decided("/Volumes/a") == a)
        #expect(decided("/Volumes/a/") == a)
        #expect(decided("/Volumes/./a") == a)
        #expect(decided("/Volumes/ab") == ab)
        #expect(decided("/Volumes/a 1") == a1)
        #expect(decided("/") == nil)
        #expect(decided("/Volumes/Data") == nil)
        #expect(decided("/Volumes/a/folder") == nil)
        #expect(decided("/Volumes") == nil)
        #expect(decided("/Volumes/gone") == nil)
        let web = try #require(URL(string: "https://example.com/Volumes/a"))
        #expect(VolumeEjector.volume(web, among: disks, underway: []) == nil)
        // A disk already ejecting is refused; its look-alikes aren't.
        let ejecting: Set<String> = [VolumeEjector.key(a.url)]
        #expect(decided("/Volumes/a", underway: ejecting) == nil)
        #expect(decided("/Volumes/ab", underway: ejecting) == ab)
        #expect(decided("/Volumes/a 1", underway: ejecting) == a1)
    }

    @Test func aLocationIsOnADiskOnlyByWholePathComponents() {
        let a = URL(filePath: "/Volumes/a/", directoryHint: .isDirectory)
        for inside in ["/Volumes/a", "/Volumes/a/", "/Volumes/a/folder", "/Volumes/a/folder/deeper"] {
            #expect(VolumeEjector.isOnVolume(URL(filePath: inside), a), "\(inside)")
        }
        for outside in ["/Volumes/ab", "/Volumes/ab/folder", "/Volumes/a 1", "/Volumes/a.txt", "/Volumes", "/", Places.home.path] {
            #expect(!VolumeEjector.isOnVolume(URL(filePath: outside), a), "\(outside)")
        }
        #expect(!VolumeEjector.isOnVolume(Places.home, URL(filePath: "/")))
    }

    @Test(.timeLimit(.minutes(2)))
    func eachDiskIsHandedToMacOSOnceUntilItAnswersAndAFailureCanBeTriedAgain() async throws {
        let urls = Self.volumes("/Volumes/strata-test-a", "/Volumes/strata-test-ab", "/Volumes/strata-test-a 1")
        let a = Self.disk(urls[0], named: "a"), ab = Self.disk(urls[1], named: "ab"), a1 = Self.disk(urls[2], named: "a 1")
        let unmounts = HeldUnmounts()
        let failures = Reports<(volume: URL, name: String)>()
        let environment = try await Self.environment(disks: [a, ab, a1], unmounts: unmounts) { failure, _ in
            failures.items.append((failure.volume, failure.name))
        }
        let ejector = environment.services.volumeEjector
        let ejected = Reports<URL>()
        let observer = NotificationCenter.default.addObserver(forName: .volumeEjected, object: ejector, queue: nil) { note in
            let volume = note.userInfo?[VolumeEjector.volumeKey] as? URL
            MainActor.assumeIsolated { if let volume { ejected.items.append(volume) } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let first = try #require(ejector.eject(a.url, from: nil))
        #expect(ejector.eject(a.url, from: nil) == nil)
        #expect(ejector.eject(URL(filePath: "/Volumes/strata-test-a"), from: nil) == nil)
        #expect(ejector.isEjecting(a.url) && !ejector.isEjecting(ab.url) && !ejector.isEjecting(a1.url))
        #expect(ejector.ejectable([a.url, ab.url, a1.url]) == [ab.url, a1.url])
        let other = try #require(ejector.eject(ab.url, from: nil))
        await unmounts.waitForAsks(2)
        #expect(await unmounts.asked == [a.url, ab.url])

        await unmounts.answerNext(throwing: CocoaError(.fileWriteNoPermission))
        await first.value
        #expect(!ejector.isEjecting(a.url) && ejector.isEjecting(ab.url))
        #expect(failures.items.map { $0.volume } == [a.url] && failures.items.map { $0.name } == ["a"])
        #expect(ejected.items.isEmpty)

        let retry = try #require(ejector.eject(a.url, from: nil))
        await unmounts.waitForAsks(3)
        await unmounts.answerNext()
        await other.value
        await unmounts.answerNext()
        await retry.value
        #expect(await unmounts.asked == [a.url, ab.url, a.url])
        #expect(ejected.items == [ab.url, a.url])
        #expect(failures.items.count == 1)
        #expect(ejector.tasks.isEmpty)
    }

    @Test(.timeLimit(.minutes(2)))
    func anEnvironmentOfItsOwnNeverHandsADiskToMacOS() async throws {
        let disk = Self.disk(URL(filePath: "/Volumes/strata-test-disk", directoryHint: .isDirectory), named: "disk")
        let base = try IndependentEnvironment()
        let failures = Reports<(volume: URL, refused: Bool)>()
        let services = BrowserServices.configured(transfers: base.services.transfers, visits: base.services.visits, windows: .headless,
            remote: base.services.remote, containers: base.services.containers, containerStore: base.services.containerStore,
            clipboard: base.services.clipboard, readPlaces: { _ in PlaceChecks.Snapshot(volumes: [disk]) },
            ejectFailed: { failure, _ in
                failures.items.append((failure.volume, (failure.error as? CocoaError)?.code == .featureUnsupported))
            })
        services.places.refresh()
        while let read = services.places.task { await read.value }
        await services.volumeEjector.eject(disk.url, from: nil)?.value
        #expect(failures.items.map { $0.volume } == [disk.url] && failures.items.allSatisfy { $0.refused })
        withExtendedLifetime(base) {}
    }

    @Test(.timeLimit(.minutes(3)))
    func onlyPanesOnTheEjectedDiskGoHomeAndOnlyOnceItHasGone() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("Volumes/a/folder/", "Volumes/ab/", "Volumes/a 1/")
        let a = Self.disk(tree.url("Volumes/a"), named: "a"), ab = Self.disk(tree.url("Volumes/ab"), named: "ab")
        let a1 = Self.disk(tree.url("Volumes/a 1"), named: "a 1")
        let unmounts = HeldUnmounts()
        let reportedIn = Reports<NSWindow?>()
        let environment = try await Self.environment(disks: [a, ab, a1], unmounts: unmounts) { _, window in
            reportedIn.items.append(window)
        }
        let window = BrowserWindowController(location: tree.url("Volumes/a/folder"), secondPane: tree.url("Volumes/ab"),
                                             services: environment.services)
        window.split.splitView.autosaveName = nil
        window.window?.setFrameAutosaveName("")
        defer { window.window?.close() }
        let left = window.pane, right = try #require(window.panes.last)
        #expect(left !== right)
        func show(_ path: String, in pane: Pane) async {
            window.go(.folder(tree.url(path)), in: pane)
            await pane.browser.directoryReads.task?.value
        }
        func isHome(_ pane: Pane) -> Bool { PathSpelling.short(pane.location) == PathSpelling.short(Places.home) }
        await left.browser.directoryReads.task?.value
        await right.browser.directoryReads.task?.value
        let ejector = environment.services.volumeEjector

        // A folder inside the disk goes home; the look-alike disk beside it stays.
        #expect(window.panesShowing(a.url).count == 1 && window.panesShowing(a.url).first === left)
        let first = try #require(ejector.eject(a.url, from: window.window))
        await unmounts.waitForAsks(1)
        #expect(!isHome(left), "A pane leaves only once the disk has gone")
        await unmounts.answerNext()
        await first.value
        #expect(isHome(left))
        #expect(PathSpelling.short(right.location) == PathSpelling.short(ab.url))

        // A failure leaves both panes on the disk where they were.
        await show("Volumes/a", in: left)
        await show("Volumes/a/folder", in: right)
        #expect(window.panesShowing(a.url).count == 2)
        let failed = try #require(ejector.eject(a.url, from: window.window))
        await unmounts.waitForAsks(2)
        await unmounts.answerNext(throwing: CocoaError(.fileWriteNoPermission))
        await failed.value
        #expect(reportedIn.items.count == 1 && reportedIn.items.first.flatMap { $0 } === window.window)
        #expect(PathSpelling.short(left.location) == PathSpelling.short(a.url))
        #expect(PathSpelling.short(right.location) == PathSpelling.short(tree.url("Volumes/a/folder")))

        // ⌘E on the disk's top: both panes on it go home, the top and the folder inside it.
        let eject = NSMenuItem(title: "", action: #selector(BrowserWindowController.ejectVolume(_:)), keyEquivalent: "")
        #expect(window.pane === left && window.validateMenuItem(eject))
        window.ejectVolume(nil)
        await unmounts.waitForAsks(3)
        #expect(!window.validateMenuItem(eject), "⌘E waits for the eject under way")
        let byCommand = try #require(ejector.tasks.values.first)
        await unmounts.answerNext()
        await byCommand.value
        #expect(isHome(left) && isHome(right))

        // Panes on another disk and at home stay where they are.
        await show("Volumes/a 1", in: left)
        #expect(window.panesShowing(a.url).isEmpty)
        let last = try #require(ejector.eject(a.url, from: window.window))
        await unmounts.waitForAsks(4)
        await unmounts.answerNext()
        await last.value
        #expect(PathSpelling.short(left.location) == PathSpelling.short(a1.url) && isHome(right))
        #expect(await unmounts.asked == [a.url, a.url, a.url, a.url])
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["Volumes/", "Volumes/a 1/", "Volumes/a/", "Volumes/a/folder/", "Volumes/ab/"])
    }

    private func cell(_ row: Int, in outline: NSOutlineView) throws -> SidebarCellView {
        try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView)
    }

    private func label(of cell: SidebarCellView) throws -> NSTextField {
        try #require(cell.subviews.compactMap { $0 as? NSTextField }.first)
    }

    @Test(.timeLimit(.minutes(2)))
    func placesShowAnEjectButtonOnlyOnEjectableDisksAndItEjectsThatDiskWithoutNavigating() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("Volumes/a/", "Volumes/Data/")
        let a = Self.disk(tree.url("Volumes/a"), named: "a")
        let data = Self.disk(tree.url("Volumes/Data"), named: "Data", ejectable: false)
        let unmounts = HeldUnmounts()
        let failures = Reports<URL>()
        let environment = try await Self.environment(disks: [data, a], unmounts: unmounts) { failure, _ in
            failures.items.append(failure.volume)
        }
        let sidebar = SidebarViewController(services: environment.services)
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        await sidebar.cloudRead?.value
        sidebar.reload()
        let outline = sidebar.outline
        let locations = try #require(sidebar.sections.first { $0.id == "locations" })
        func row(_ disk: Place) throws -> Int {
            let item = try #require(locations.items.first { $0.url.map { PathSpelling.short($0) } == PathSpelling.short(disk.url) })
            return outline.row(forItem: item)
        }
        let trashItem = try #require(locations.items.last)
        let trash = outline.row(forItem: trashItem)
        let aRow = try row(a)
        let shown = try cell(aRow, in: outline)
        #expect(!shown.ejectButton.isHidden && shown.ejectButton.isEnabled)
        #expect(shown.ejectButton.accessibilityLabel() == String(localized: "Eject “\("a")”"))
        #expect(shown.ejectButton.toolTip == shown.ejectButton.accessibilityLabel())
        let dataRow = try row(data)
        for other in [dataRow, trash] { #expect(try cell(other, in: outline).ejectButton.isHidden) }
        for section in sidebar.sections where section.id != "locations" {
            for item in section.items {
                let row = outline.row(forItem: item)
                if row >= 0 { #expect(try cell(row, in: outline).ejectButton.isHidden, "\(item.title)") }
            }
        }

        outline.selectRowIndexes([trash], byExtendingSelection: false)
        var navigations = 0
        sidebar.onSelect = { _ in navigations += 1 }
        shown.ejectButton.performClick(nil)
        await unmounts.waitForAsks(1)
        #expect(await unmounts.asked == [a.url])
        #expect(outline.selectedRow == trash && navigations == 0)
        #expect(try !cell(aRow, in: outline).ejectButton.isEnabled, "Busy while it ejects")
        let task = try #require(environment.services.volumeEjector.tasks.values.first)
        await unmounts.answerNext(throwing: CocoaError(.fileWriteNoPermission))
        await task.value
        #expect(failures.items == [a.url])
        #expect(try cell(aRow, in: outline).ejectButton.isEnabled, "A failed eject can be tried again")

        // A reused cell: the label runs up to the button, never under it, and a row that isn't a disk has none.
        shown.frame = NSRect(x: 0, y: 0, width: 160, height: 28)
        shown.configure(title: String(repeating: "Long disk name ", count: 8), symbol: "externaldrive",
                        ejection: SidebarCellView.Ejection(isUnderway: { false }, perform: {}))
        shown.layoutSubtreeIfNeeded()
        #expect(try label(of: shown).frame.maxX <= shown.ejectButton.frame.minX)
        #expect(shown.ejectButton.frame.width >= 20)
        shown.configure(title: "folder", symbol: "folder")
        shown.layoutSubtreeIfNeeded()
        #expect(shown.ejectButton.isHidden && (shown.ejectButton.accessibilityLabel() ?? "").isEmpty)
        #expect(try label(of: shown).frame.maxX > shown.ejectButton.frame.minX)
        sidebar.onSelect = nil
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["Volumes/", "Volumes/Data/", "Volumes/a/"])
    }

    @Test(.timeLimit(.minutes(2)))
    func theFolderTreeEjectsOnlyEjectableDisksFromItsButtonAndMenu() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("Volumes/a/", "Volumes/Data/")
        let a = Self.disk(tree.url("Volumes/a"), named: "a")
        let data = Self.disk(tree.url("Volumes/Data"), named: "Data", ejectable: false)
        let unmounts = HeldUnmounts()
        let environment = try await Self.environment(disks: [data, a], unmounts: unmounts)
        environment.preferences.sidebarShowsTree = true
        let sidebar = SidebarViewController(services: environment.services)
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        let folders = try #require(sidebar.children.first as? FolderTreeController)
        let outline = try #require(folders.focusView as? NSOutlineView)
        // Home's folders arrive meanwhile and move the rows below it: each is found by its node every time.
        func node(_ url: URL) throws -> FolderNode {
            let row = try #require((0..<outline.numberOfRows).first { row in
                (outline.item(atRow: row) as? FolderNode).map { PathSpelling.short($0.url) } == PathSpelling.short(url)
            })
            return try #require(outline.item(atRow: row) as? FolderNode)
        }
        func button(_ node: FolderNode) throws -> NSButton {
            try cell(outline.row(forItem: node), in: outline).ejectButton
        }
        let disk = try node(a.url), plain = try node(data.url), home = try node(Places.home)
        #expect(try !button(disk).isHidden && button(disk).accessibilityLabel() == String(localized: "Eject “\("a")”"))
        #expect(try button(plain).isHidden && button(home).isHidden)

        func ejectItems(for node: FolderNode) -> [NSMenuItem] {
            let menu = NSMenu()
            folders.addItems(for: node, to: menu)
            return menu.items.filter { $0.action == NSSelectorFromString("ejectNode:") }
        }
        #expect(ejectItems(for: disk).map(\.title) == [String(localized: "Eject “\("a")”")])
        #expect(ejectItems(for: plain).isEmpty && ejectItems(for: home).isEmpty)

        outline.selectRowIndexes([outline.row(forItem: plain)], byExtendingSelection: false)
        var navigations = 0
        sidebar.onSelect = { _ in navigations += 1 }
        try button(disk).performClick(nil)
        await unmounts.waitForAsks(1)
        #expect(outline.item(atRow: outline.selectedRow) as? FolderNode === plain && navigations == 0)
        #expect(try !button(disk).isEnabled)
        // The menu's Eject while the button's is under way asks nothing more of macOS.
        let item = try #require(ejectItems(for: disk).first)
        let action = try #require(item.action)
        _ = folders.perform(action, with: item)
        let task = try #require(environment.services.volumeEjector.tasks.values.first)
        await unmounts.answerNext()
        await task.value
        #expect(await unmounts.asked == [a.url])
        #expect(environment.services.volumeEjector.tasks.isEmpty)
        sidebar.onSelect = nil
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["Volumes/", "Volumes/Data/", "Volumes/a/"])
    }
}
