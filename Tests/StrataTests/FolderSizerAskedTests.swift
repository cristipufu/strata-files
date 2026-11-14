import AppKit
import Foundation
import Synchronization
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataIndex
@testable import StrataModel
@testable import StrataSearch
@testable import StrataSupport

/// A walk a list starts for its rows fetches nothing from a cloud provider; one you asked for fetches what it needs,
/// measures everything, and is not stopped because the index took the folder over or is busy.
@MainActor struct FolderSizerAskedTests {
    private nonisolated static func fetching() -> Int32 {
        getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    }

    @Test func aWalkNobodyAskedForFetchesNothingAndOneYouAskedForFetches() async throws {
        let tree = try TestTree("folder/file")
        let folder = tree.url("folder")
        defer { FolderSizer.invalidate(folder) }
        let delivery = FolderSizeDelivery(), whileWalking = Mutex([Int32]())
        let sizer = FolderSizer(reader: { _, _ in
            whileWalking.withLock { $0.append(Self.fetching()) }
            return FolderSize(bytes: 1, files: 1)
        }, deliver: delivery.callback)
        // One after the other on the queue's threads: each walk leaves its thread as it found it for the next.
        for _ in 0..<8 {
            for asked in [false, true] {
                FolderSizer.invalidate(folder)
                sizer.request(folder, askedBy: asked ? .inspector : nil)
                (await delivery.take())()
            }
        }
        let off = IOPOL_MATERIALIZE_DATALESS_FILES_OFF, asEver = IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT
        #expect(whileWalking.withLock { $0 } == Array(repeating: [off, asEver], count: 8).flatMap { $0 })
        #expect(tree.snapshot() == ["folder/", "folder/file"])
    }

    @Test func aWalkThatMayNotFetchMeasuresNothingOfAFolderOnlyInTheCloudAndPassesOverOneDeeperIn() throws {
        let tree = try TestTree("folder/local/a", "folder/cloud/b", "folder/cloud/deeper/c", "folder/d")
        let folder = tree.url("folder").path, cloud = tree.url("folder/cloud").path
        let cloudOnly: (FTSENT) -> Bool = { String(cString: $0.fts_path).hasSuffix("/cloud") }
        // Left to fts, a folder it may not fetch reads as an empty one, and the size would pass for one of everything.
        let passedOver = DatalessFile.withoutMaterializing {
            FolderSizer.measure(folder, isOnlyInTheCloud: cloudOnly) { false }
        }
        #expect(passedOver?.files == 2 && passedOver?.allocationComplete == false)
        // Asked about that folder itself, such a walk has nothing to measure: no size, not a size of nothing.
        let ofTheCloudOnly = DatalessFile.withoutMaterializing {
            FolderSizer.measure(cloud, isOnlyInTheCloud: cloudOnly) { false }
        }
        #expect(ofTheCloudOnly == nil)
        // A walk that fetches reads it, and so does any walk of a folder that is on the Mac.
        let fetched = FolderSizer.measure(folder, isOnlyInTheCloud: cloudOnly) { false }
        #expect(fetched?.files == 4 && fetched?.allocationComplete == true)
        #expect(FolderSizer.measure(cloud, isOnlyInTheCloud: cloudOnly) { false }?.files == 2)
        let onTheMac = DatalessFile.withoutMaterializing { FolderSizer.measure(folder) { false } }
        #expect(onTheMac?.files == 4 && onTheMac?.allocationComplete == true)
        #expect(tree.snapshot() == ["folder/", "folder/cloud/", "folder/cloud/b", "folder/cloud/deeper/",
                                    "folder/cloud/deeper/c", "folder/d", "folder/local/", "folder/local/a"])
    }

    @Test func aWalkThatMeasuredNothingLeavesNoSizeAndAskingMeasures() async throws {
        let tree = try TestTree("cloud/file")
        let cloud = tree.url("cloud")
        defer { FolderSizer.invalidate(cloud) }
        let delivery = FolderSizeDelivery(), fetched = Mutex([Bool]())
        // As for a folder that is only in the cloud: nothing to measure unless the walk may fetch.
        let sizer = FolderSizer(reader: { _, _ in
            let fetches = Self.fetching() != IOPOL_MATERIALIZE_DATALESS_FILES_OFF
            fetched.withLock { $0.append(fetches) }
            return fetches ? FolderSize(bytes: 7, files: 1) : nil
        }, deliver: delivery.callback)
        var told: [URL] = []
        sizer.onUpdate = { told.append($0) }
        sizer.request(cloud)
        (await delivery.take())()
        #expect(FolderSizer.cached(cloud) == nil && !sizer.hasPending && told == [])
        // You ask: it is fetched and measured, and has a size from then on.
        sizer.request(cloud, askedBy: .inspector)
        try #require(sizer.isAskedFor(cloud))
        (await delivery.take())()
        #expect(FolderSizer.cached(cloud)?.bytes == 7 && FolderSizer.askedSize(cloud)?.bytes == 7 && told == [cloud])
        #expect(fetched.withLock { $0 } == [false, true])
        #expect(tree.snapshot() == ["cloud/", "cloud/file"])
    }

    @Test func theIndexTakingAFolderOverStopsOnlyAWalkNobodyAskedFor() async throws {
        let tree = try TestTree("shown/file", "asked/file")
        let shown = tree.url("shown"), asked = tree.url("asked")
        defer { [shown, asked].forEach(FolderSizer.invalidate) }
        let delivery = FolderSizeDelivery()
        let sizer = FolderSizer(reader: { _, _ in FolderSize(bytes: 3, files: 1) }, deliver: delivery.callback)
        sizer.request(shown)
        sizer.request(asked, askedBy: .inspector)
        sizer.cancel(shown)
        sizer.cancel(asked)
        #expect(!sizer.isPending(shown) && sizer.isPending(asked))
        sizer.request(shown)
        sizer.cancel { _ in true }
        #expect(!sizer.isPending(shown) && sizer.isPending(asked))
        for _ in 0..<3 { (await delivery.take())() }
        #expect(FolderSizer.cached(shown) == nil && FolderSizer.askedSize(asked)?.bytes == 3)

        // Leaving the folder stops both kinds.
        FolderSizer.invalidate(asked)
        sizer.request(shown)
        sizer.request(asked, askedBy: .inspector)
        sizer.cancelPending()
        #expect(!sizer.hasPending)
        for _ in 0..<2 { (await delivery.take())() }
        #expect(FolderSizer.cached(shown) == nil && FolderSizer.cached(asked) == nil)
        #expect(tree.snapshot() == ["asked/", "asked/file", "shown/", "shown/file"])
    }

    @Test func aSizerKeepsWhatItMeasuredUntilItsBrowserLeavesAndLetsGoOnlyOfItsOwn() async throws {
        let tree = try TestTree("a/", "b/", "c/", "d/", "e/", "other/", "gone/")
        let folders = ["a", "b", "c", "d", "e"].map(tree.url), other = tree.url("other"), gone = tree.url("gone")
        defer { (folders + [other, gone]).forEach(FolderSizer.invalidate) }
        let delivery = FolderSizeDelivery(), elsewhere = FolderSizeDelivery()
        // A view that needs more sizes than its sizer keeps, as a selection larger than any limit does.
        let sizer = FolderSizer(reader: { _, _ in FolderSize(bytes: 1, files: 1) }, keeping: 3, deliver: delivery.callback)
        for folder in folders { sizer.request(folder, askedBy: .inspector) }
        for _ in folders { (await delivery.take())() }
        // None was let go of as the others arrived: it would be asked for again, and the others let go of in turn.
        #expect(folders.allSatisfy { FolderSizer.askedSize($0)?.bytes == 1 })
        for folder in folders { sizer.request(folder, askedBy: .inspector) }
        #expect(!sizer.hasPending)

        // Another window measured a folder of its own. It leaves, having measured few: that size stays for its return.
        let window = FolderSizer(reader: { _, _ in FolderSize(bytes: 2, files: 1) }, deliver: elsewhere.callback)
        window.request(other)
        (await elsewhere.take())()
        window.cancelPending()
        #expect(FolderSizer.cached(other)?.bytes == 2)
        // The first leaves its folder, having measured many: it lets go of those, and of nothing another measured.
        sizer.cancelPending()
        #expect(folders.allSatisfy { FolderSizer.cached($0) == nil } && FolderSizer.cached(other)?.bytes == 2)

        // A sizer that is gone has let go of its sizes, few as they were.
        do {
            let closed = FolderSizer(reader: { _, _ in FolderSize(bytes: 3, files: 1) }, deliver: elsewhere.callback)
            closed.request(gone)
            (await elsewhere.take())()
            #expect(FolderSizer.cached(gone)?.bytes == 3)
        }
        var turns = 0
        while FolderSizer.cached(gone) != nil {
            turns += 1
            try #require(turns < 10_000, "The sizer that is gone never let go of its size.")
            try await Task.sleep(for: .milliseconds(3))
        }
        #expect(FolderSizer.cached(other)?.bytes == 2)
        #expect(tree.snapshot() == ["a/", "b/", "c/", "d/", "e/", "gone/", "other/"])
    }

    @Test func theIndexsTotalIsShownOnceItIsOfEverythingAndASizeYouAskedForUntilThen() {
        let partly = FolderSize(bytes: 10, files: 1, allocatedBytes: 0, allocationComplete: false)
        let everything = FolderSize(bytes: 10, files: 1), asked = FolderSize(bytes: 900, files: 9)
        #expect(FolderSizer.shown(indexed: partly, asked: asked) == asked)
        #expect(FolderSizer.shown(indexed: partly, asked: nil) == partly)
        #expect(FolderSizer.shown(indexed: everything, asked: asked) == everything)
    }

    @Test func aWalkAskedForGoesOnOnlyWhileSomeoneStillWantsIt() async throws {
        let tree = try TestTree("shown/file", "left/file", "both/file", "row/file")
        let shown = tree.url("shown"), left = tree.url("left"), both = tree.url("both"), row = tree.url("row")
        defer { [shown, left, both, row].forEach(FolderSizer.invalidate) }
        let released = DispatchSemaphore(value: 0)
        defer { released.signal() }
        let sizer = FolderSizer(reader: { _, _ in
            // Only stops a walk whose test never ends.
            _ = released.wait(timeout: .now() + 600)
            released.signal()
            return nil
        }, deliver: FolderSizeDelivery().callback)
        for url in [shown, left, both] { sizer.request(url, askedBy: .inspector) }
        sizer.request(both, askedBy: .diskUsage)
        sizer.request(row)
        // The Inspector shows something else: what it alone asked about stops, and nothing else does.
        sizer.keepOnly([shown], askedBy: .inspector)
        #expect(sizer.isAskedFor(shown) && !sizer.isPending(left) && sizer.isAskedFor(both))
        #expect(sizer.isPending(row) && !sizer.isAskedFor(row))
        // Disk Usage is left: what it alone still asked about stops.
        sizer.keepOnly([], askedBy: .diskUsage)
        #expect(sizer.isAskedFor(shown) && !sizer.isPending(both) && sizer.isPending(row))
        sizer.keepOnly([], askedBy: .inspector)
        #expect(!sizer.isPending(shown) && sizer.isPending(row))
        #expect(tree.snapshot() == ["both/", "both/file", "left/", "left/file", "row/", "row/file", "shown/", "shown/file"])
    }

    @Test func askingTakesThePlaceOfAWalkThatMayNotFetchAndOnlyAWholeSizeStandsForWhatYouAsk() async throws {
        let tree = try TestTree("partly/file", "whole/file")
        let partly = tree.url("partly"), whole = tree.url("whole")
        defer { [partly, whole].forEach(FolderSizer.invalidate) }
        let delivery = FolderSizeDelivery(), fetched = Mutex([String: [Bool]]())
        // What is only in the cloud in a folder is passed over by a walk that may not fetch.
        let sizer = FolderSizer(reader: { path, _ in
            let fetches = Self.fetching() != IOPOL_MATERIALIZE_DATALESS_FILES_OFF
            fetched.withLock { $0[path, default: []].append(fetches) }
            let everything = fetches || path == whole.path
            return FolderSize(bytes: everything ? 100 : 10, files: 1, allocatedBytes: 0, allocationComplete: everything)
        }, deliver: delivery.callback)
        sizer.request(partly)
        sizer.request(whole)
        for _ in 0..<2 { (await delivery.take())() }
        // A row shows what was measured. What you ask for is of everything: a size that passed something over is
        // not that, one that passed nothing over is.
        #expect(FolderSizer.cached(partly)?.bytes == 10 && FolderSizer.cached(partly, asked: true) == nil)
        #expect(FolderSizer.cached(whole, asked: true)?.bytes == 100 && FolderSizer.askedSize(whole) == nil)
        sizer.request(whole, askedBy: .inspector)
        #expect(!sizer.hasPending)
        sizer.request(partly, askedBy: .inspector)
        try #require(sizer.isPending(partly))
        (await delivery.take())()
        #expect(FolderSizer.cached(partly)?.bytes == 100 && FolderSizer.askedSize(partly)?.bytes == 100)

        // With a walk nobody asked for under way, asking starts one that fetches in its place; a row asking while
        // that one is under way starts nothing more.
        FolderSizer.invalidate(partly)
        sizer.request(partly)
        sizer.request(partly, askedBy: .inspector)
        try #require(sizer.isAskedFor(partly))
        sizer.request(partly)
        for _ in 0..<2 { (await delivery.take())() }
        #expect(!sizer.hasPending && FolderSizer.askedSize(partly)?.bytes == 100)
        // Twice by a walk that fetches: the first one you asked for, and this one.
        #expect(fetched.withLock { $0[partly.path]?.filter { $0 }.count } == 2 && fetched.withLock { $0[whole.path] } == [false])
        #expect(tree.snapshot() == ["partly/", "partly/file", "whole/", "whole/file"])
    }

    @Test func whatAWalkYouAskedForMeasuredIsNotReplacedByAnotherWindowsWalkThatMayNotFetch() async throws {
        let tree = try TestTree("folder/file")
        let folder = tree.url("folder")
        defer { FolderSizer.invalidate(folder) }
        let asking = FolderSizeDelivery(), showing = FolderSizeDelivery()
        let asked = FolderSizer(reader: { _, _ in FolderSize(bytes: 100, files: 2) }, deliver: asking.callback)
        let shown = FolderSizer(reader: { _, _ in
            FolderSize(bytes: 10, files: 1, allocatedBytes: 0, allocationComplete: false)
        }, deliver: showing.callback)
        var told: [URL] = []
        shown.onUpdate = { told.append($0) }
        // Two windows show the folder. One window's row starts a walk; in the other you ask, and that ends first.
        shown.request(folder)
        asked.request(folder, askedBy: .inspector)
        (await asking.take())()
        (await showing.take())()
        #expect(FolderSizer.askedSize(folder)?.bytes == 100)
        // The window whose walk ended last still hears that there is a size to show.
        #expect(told == [folder])
        #expect(tree.snapshot() == ["folder/", "folder/file"])
    }

    /// What the cloud badge of the folder named "cloud" shows, as its provider would have it.
    private final class CloudBadge: Sendable {
        private let state = Mutex(CloudStatus.providerOnly)

        func becomes(_ status: CloudStatus) { state.withLock { $0 = status } }

        var store: CloudStore {
            CloudStore(reader: { [self] paths, _ in
                let badge = state.withLock { $0 }
                return (paths, Dictionary(uniqueKeysWithValues: paths.filter { $0.hasSuffix("/cloud") }.map { ($0, badge) }))
            })
        }
    }

    /// A browser showing `folder` whose rows take their cloud badges from `store`, once those have been read.
    private func browser(showing folder: URL, badges store: CloudStore, in environment: IndependentEnvironment,
                         sizes: @escaping FolderSizer.Reader) async throws -> BrowserViewController {
        let owner = environment.services
        let services = BrowserServices.configured(
            transfers: owner.transfers, visits: owner.visits, windows: .headless,
            remote: owner.remote, containers: owner.containers, containerStore: owner.containerStore,
            clipboard: owner.clipboard, folderSizes: sizes, cloud: store
        )
        let browser = BrowserViewController(services: services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        browser.load(folder)
        await browser.directoryReads.task?.value
        try #require(browser.isLoaded)
        try await until { store.status(for: folder.appending(path: "cloud")) == .providerOnly }
        // Whatever a row asked for before the badges arrived is not what a test looks at.
        browser.sizer.cancelPending()
        return browser
    }

    private func until(_ condition: () -> Bool) async throws {
        var turns = 0
        while !condition() {
            turns += 1
            try #require(turns < 10_000, "What was waited for never came.")
            try await Task.sleep(for: .milliseconds(3))
        }
    }

    @Test func aRowShowsNoSizeAndStartsNoWalkWhileItsCloudBadgeSaysOnlyInTheCloud() async throws {
        let _ = NSApplication.shared
        let tree = try TestTree("home/cloud/file", "home/local/file")
        let home = tree.url("home"), cloud = tree.url("home/cloud"), local = tree.url("home/local")
        defer { [home, cloud, local].forEach(FolderSizer.invalidate) }
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let released = DispatchSemaphore(value: 0)
        defer { released.signal() }
        let badge = CloudBadge(), store = badge.store
        let browser = try await browser(showing: home, badges: store, in: environment) { path, _ in
            // Only stops a walk whose test never ends.
            _ = released.wait(timeout: .now() + 600)
            released.signal()
            // Only a walk that fetches has anything to measure of a folder that is only in the cloud.
            let fetches = Self.fetching() != IOPOL_MATERIALIZE_DATALESS_FILES_OFF
            return fetches && path == cloud.path ? FolderSize(bytes: 2_048, files: 9) : nil
        }
        defer { browser.stopBackgroundWork() }
        let cloudRow = try #require(browser.allRows.first { $0.url.lastPathComponent == "cloud" })
        let localRow = try #require(browser.allRows.first { $0.url.lastPathComponent == "local" })
        #expect(!browser.showsSize(cloudRow.entry) && browser.iconFolderSizeText(cloudRow.entry) == "—")
        #expect(!browser.sizer.isPending(cloud))
        // A folder beside it is sized as ever.
        #expect(browser.showsSize(localRow.entry) && browser.iconFolderSizeText(localRow.entry) == "…")
        #expect(browser.sizer.isPending(local) && !browser.sizer.isAskedFor(local))

        // A size known already is shown, whatever the badge still says: here one another window measured.
        let elsewhere = FolderSizeDelivery()
        let other = FolderSizer(reader: { _, _ in FolderSize(bytes: 900, files: 3) }, deliver: elsewhere.callback)
        other.request(cloud, askedBy: .inspector)
        (await elsewhere.take())()
        #expect(store.status(for: cloud) == .providerOnly && browser.showsSize(cloudRow.entry))
        #expect(browser.iconFolderSizeText(cloudRow.entry) == Format.bytes(900))
        FolderSizer.invalidate(cloud)
        #expect(!browser.showsSize(cloudRow.entry))

        // You ask here. The walk fetches the folder, so its badge is read again, and the row has its size.
        #expect(browser.folderSize(cloud, request: true, askedBy: .inspector) == nil && browser.sizer.isAskedFor(cloud))
        badge.becomes(.local)
        released.signal()
        try await until { store.status(for: cloud) == .local }
        #expect(browser.showsSize(cloudRow.entry) && browser.iconFolderSizeText(cloudRow.entry) == Format.bytes(2_048))
        #expect(tree.snapshot() == ["home/", "home/cloud/", "home/cloud/file", "home/local/", "home/local/file"])
    }

    @Test func whatAWalkOfTheFolderShownFetchedHasTheBadgesInItReadAgain() async throws {
        let _ = NSApplication.shared
        let tree = try TestTree("home/cloud/file")
        let home = tree.url("home"), cloud = tree.url("home/cloud")
        defer { [home, cloud].forEach(FolderSizer.invalidate) }
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let badge = CloudBadge(), store = badge.store
        let browser = try await browser(showing: home, badges: store, in: environment) { path, _ in
            path == home.path ? FolderSize(bytes: 2_048, files: 9) : nil
        }
        defer { browser.stopBackgroundWork() }
        // The Inspector, with nothing selected, asks for the folder shown. The walk fetches what is in it, which
        // nothing else would tell the badges of.
        badge.becomes(.local)
        #expect(browser.folderSize(home, request: true, askedBy: .inspector) == nil && browser.sizer.isAskedFor(home))
        try await until { store.status(for: cloud) == .local }
        #expect(tree.snapshot() == ["home/", "home/cloud/", "home/cloud/file"])
    }

    @Test func theWindowHearsOnceOfTheSizesThatArriveInAStretch() async throws {
        let _ = NSApplication.shared
        let tree = try TestTree("home/file")
        let home = tree.url("home")
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let browser = BrowserViewController(services: environment.services)
        var told = 0
        let observer = BrowserContentObserver { _ in told += 1 }
        browser.delegate = observer
        browser.view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        browser.load(home)
        await browser.directoryReads.task?.value
        try #require(browser.isLoaded)
        defer { browser.stopBackgroundWork() }
        // Whatever loading the folder told of has been told.
        var settled = told
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(3))
            if told != settled { settled = told }
        }
        // A selection of thousands has its sizes arrive one after the other, and the Inspector goes over the whole
        // selection each time the window hears of one.
        let arrived = try #require(browser.sizer.onUpdate)
        for _ in 0..<1_000 { arrived(home) }
        #expect(told == settled)
        try await until { told > settled }
        #expect(told == settled + 1)
        #expect(tree.snapshot() == ["home/", "home/file"])
    }

    @Test func theWindowHearsOnlyOfSizesItShows() async throws {
        let _ = NSApplication.shared
        let tree = try TestTree("home/selected/file", "home/row/file", "elsewhere/file")
        let home = tree.url("home"), selected = tree.url("home/selected"), row = tree.url("home/row")
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let browser = BrowserViewController(services: environment.services)
        var told = 0
        let observer = BrowserContentObserver { _ in told += 1 }
        browser.delegate = observer
        browser.view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        browser.load(home)
        await browser.directoryReads.task?.value
        try #require(browser.isLoaded)
        defer { browser.stopBackgroundWork() }
        browser.select([selected])
        let arrived = try #require(browser.sizer.onUpdate)
        /// How often the window hears of the sizes of `folders` arriving together.
        func hears(of folders: [URL]) -> Int {
            browser.tellOfSizesArrived()
            let before = told
            folders.forEach(arrived)
            browser.tellOfSizesArrived()
            return told - before
        }
        // A row's size, or one of a folder elsewhere, is not the Inspector's to show again.
        #expect(hears(of: [row, tree.url("elsewhere")]) == 0)
        #expect(hears(of: [row, selected]) == 1)
        // Of what arrives next, not again of what it has heard of.
        #expect(hears(of: [row]) == 0 && hears(of: [home]) == 1)
        // However its folder is spelled.
        #expect(hears(of: [URL(fileURLWithPath: selected.path, isDirectory: true)]) == 1)
        #expect(hears(of: [URL(fileURLWithPath: selected.path, isDirectory: false)]) == 1)
        #expect(tree.snapshot() == ["elsewhere/", "elsewhere/file", "home/", "home/row/", "home/row/file",
                                    "home/selected/", "home/selected/file"])
    }

    @Test func aRowLeftUntilAskedIsSortedBySizeAsItShowsThoughItsSizeIsKnown() async throws {
        let _ = NSApplication.shared
        let tree = try TestTree("Apps/", "home/asked/file", "home/left/file")
        let asked = tree.url("home/asked"), left = tree.url("home/left")
        defer { [asked, left].forEach(FolderSizer.invalidate) }
        let released = DispatchSemaphore(value: 0)
        defer { released.signal() }
        let environment = try IndependentEnvironment(folderSizes: { _, _ in
            // Only stops a walk whose test never ends.
            _ = released.wait(timeout: .now() + 600)
            released.signal()
            return nil
        }, indexedFolders: (home: tree.url("home"), applications: tree.url("Apps")))
        defer { withExtendedLifetime(environment) {} }
        // With the index off, the folders it would cover are left until you ask.
        environment.preferences.indexesFiles = false
        let browser = BrowserViewController(services: environment.services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        browser.load(tree.url("home"))
        await browser.directoryReads.task?.value
        try #require(browser.isLoaded)
        defer { browser.stopBackgroundWork() }
        // You asked for one in the Inspector: its size is known, and its row goes on showing none, as rows there do.
        let delivery = FolderSizeDelivery()
        let inspector = FolderSizer(reader: { _, _ in FolderSize(bytes: 900, files: 3) }, deliver: delivery.callback)
        inspector.request(asked, askedBy: .inspector)
        (await delivery.take())()
        let askedRow = try #require(browser.allRows.first { $0.url.lastPathComponent == "asked" })
        #expect(browser.folderSize(asked)?.bytes == 900)
        #expect(!browser.showsSize(askedRow.entry) && browser.iconFolderSizeText(askedRow.entry) == "—")
        // Sorted by size, it is ordered as a row that shows none, beside the other, not by a size nobody sees.
        browser.applySort(.size, ascending: false, remember: false)
        #expect(browser.allRows.map(\.url.lastPathComponent) == ["asked", "left"])
        browser.applySort(.size, ascending: true)
        #expect(browser.allRows.map(\.url.lastPathComponent) == ["asked", "left"])
        // Also the first time a listing is sorted, when the folder is opened again with rows sorted by size:
        // smallest first, a size nobody sees would put the row last.
        browser.load(asked)
        await browser.directoryReads.task?.value
        browser.load(tree.url("home"))
        await browser.directoryReads.task?.value
        try #require(browser.isLoaded && browser.allRows.count == 2)
        try #require(browser.ordering.choice?.key == .size && browser.ordering.choice?.ascending == true)
        #expect(browser.allRows.map(\.url.lastPathComponent) == ["asked", "left"])
        #expect(tree.snapshot() == ["Apps/", "home/", "home/asked/", "home/asked/file", "home/left/", "home/left/file"])
    }

    @Test func theInspectorIsToldOfASizeForTheFolderOfADeeperColumn() async throws {
        let _ = NSApplication.shared
        let tree = try TestTree("home/deeper/item.txt")
        let deeper = tree.url("home/deeper"), item = tree.url("home/deeper/item.txt")
        defer { [tree.url("home"), deeper].forEach(FolderSizer.invalidate) }
        let released = DispatchSemaphore(value: 0)
        defer { released.signal() }
        let environment = try IndependentEnvironment(folderSizes: { path, _ in
            // Only stops a walk whose test never ends.
            _ = released.wait(timeout: .now() + 600)
            released.signal()
            return path == deeper.path ? FolderSize(bytes: 2_048, files: 1) : nil
        })
        defer { withExtendedLifetime(environment) {} }
        let browser = BrowserViewController(services: environment.services)
        var told = 0
        let observer = BrowserContentObserver { _ in told += 1 }
        browser.delegate = observer
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        browser.setMode(.columns, remember: false)
        browser.load(tree.url("home"))
        await browser.directoryReads.task?.value
        try #require(browser.isLoaded)
        defer { browser.stopBackgroundWork() }
        browser.select([item])
        var turns = 0
        func until(_ condition: () -> Bool) async throws {
            while !condition() {
                turns += 1
                try #require(turns < 10_000, "What was waited for never came.")
                try await Task.sleep(for: .milliseconds(3))
            }
        }
        try await until { browser.selectedURLs.map(\.path) == [item.path] && browser.targetDirectory?.path == deeper.path }
        // The folder of the column you are in is neither the folder the window opened nor anything selected.
        #expect(browser.folderSize(deeper, request: true, askedBy: .inspector) == nil && browser.sizer.isAskedFor(deeper))
        var settled = told
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(3))
            if told != settled { settled = told }
        }
        released.signal()
        try await until { told > settled }
        #expect(told == settled + 1 && FolderSizer.askedSize(deeper) != nil)
        #expect(tree.snapshot() == ["home/", "home/deeper/", "home/deeper/item.txt"])
    }

    @Test(arguments: [BrowserViewMode.list, .grid])
    func theInspectorShowsASizeItAskedForWhenItArrivesInWhicheverViewHoldsTheSelection(_ mode: BrowserViewMode) async throws {
        let _ = NSApplication.shared
        let tree = try TestTree("home/selected/file", "home/row/file")
        let selected = tree.url("home/selected")
        defer { [tree.url("home"), selected, tree.url("home/row")].forEach(FolderSizer.invalidate) }
        let released = DispatchSemaphore(value: 0)
        defer { released.signal() }
        let environment = try IndependentEnvironment(folderSizes: { path, _ in
            // Only stops a walk whose test never ends.
            _ = released.wait(timeout: .now() + 600)
            released.signal()
            return path == selected.path ? FolderSize(bytes: 2_048, files: 9) : nil
        })
        defer { withExtendedLifetime(environment) {} }
        let controller = BrowserWindowController(location: tree.url("home"), services: environment.services)
        defer {
            controller.close()
            controller.window?.contentViewController = nil
        }
        let browser = controller.browser
        await browser.directoryReads.task?.value
        try #require(browser.isLoaded)
        browser.setMode(mode, remember: false)
        controller.split.inspectorItem.isCollapsed = false
        browser.select([selected])
        controller.refreshPanels()
        try #require(browser.sizer.isAskedFor(selected))
        let title = String(localized: "Logical size", comment: "Inspector row: file lengths before compression, sparse allocation or shared storage")
        func shown() -> String? {
            (controller.split.inspector.infoRows.shown.first { $0.title == title }?.value as? NSTextField)?.stringValue
        }
        #expect(shown() == String(localized: "Calculating…"))
        released.signal()
        var turns = 0
        while shown()?.hasPrefix(Format.bytes(2_048)) != true {
            turns += 1
            try #require(turns < 10_000, "The Inspector never showed the size it asked for.")
            try await Task.sleep(for: .milliseconds(3))
        }
        #expect(tree.snapshot() == ["home/", "home/row/", "home/row/file", "home/selected/", "home/selected/file"])
    }

    @Test func theInspectorAsksForTheSizeOfWhatItShowsAndNoLongerOfWhatItShowsNoMore() async throws {
        let _ = NSApplication.shared
        let tree = try TestTree("home/selected/file", "home/row/file")
        let selected = tree.url("home/selected"), row = tree.url("home/row")
        defer { [tree.url("home"), selected, row].forEach(FolderSizer.invalidate) }
        let released = DispatchSemaphore(value: 0)
        defer { released.signal() }
        let environment = try IndependentEnvironment(folderSizes: { _, _ in
            // Only stops a walk whose test never ends.
            _ = released.wait(timeout: .now() + 600)
            released.signal()
            return nil
        })
        defer { withExtendedLifetime(environment) {} }
        let controller = BrowserWindowController(location: tree.url("home"), services: environment.services)
        defer {
            controller.close()
            controller.window?.contentViewController = nil
        }
        let browser = controller.browser
        await browser.directoryReads.task?.value
        try #require(browser.isLoaded)
        controller.split.inspectorItem.isCollapsed = false
        #expect(browser.folderSize(row, request: true) == nil)
        #expect(browser.sizer.isPending(row) && !browser.sizer.isAskedFor(row))
        browser.select([selected])
        controller.refreshPanels()
        #expect(browser.sizer.isAskedFor(selected) && !browser.sizer.isAskedFor(row))

        // It shows something else: it asks about that, and no longer about what it showed. A row's own walk goes on.
        browser.select([row])
        controller.refreshPanels()
        #expect(!browser.sizer.isPending(selected) && browser.sizer.isAskedFor(row))
        browser.select([])
        controller.refreshPanels()
        #expect(!browser.sizer.isPending(row) && browser.sizer.isAskedFor(tree.url("home")))
        #expect(browser.folderSize(selected, request: true) == nil && browser.sizer.isPending(selected))
        // Hidden, it asks about nothing, from the moment it is.
        controller.split.inspectorItem.isCollapsed = true
        #expect(!browser.sizer.isPending(tree.url("home")) && browser.sizer.isPending(selected))

        // Disk Usage asks for every folder it shows. What the Inspector showed and shows no more is still wanted
        // there, until Disk Usage is left.
        controller.split.inspectorItem.isCollapsed = false
        browser.setMode(.treemap, remember: false)
        browser.select([selected])
        controller.refreshPanels()
        browser.select([row])
        controller.refreshPanels()
        #expect(browser.sizer.isAskedFor(selected) && browser.sizer.isAskedFor(row))
        browser.setMode(.list, remember: false)
        controller.refreshPanels()
        #expect(!browser.sizer.isPending(selected) && browser.sizer.isAskedFor(row))
        #expect(tree.snapshot() == ["home/", "home/row/", "home/row/file", "home/selected/", "home/selected/file"])
    }

    @Test func aSizeYouAskedForIsMeasuredToTheEndAndStandsUntilTheIndexHasReadEverything() async throws {
        let _ = NSApplication.shared
        let tree = try TestTree("cloud/file.txt", "row/file.txt")
        let cloud = tree.url("cloud"), row = tree.url("row")
        defer { [tree.root, cloud, row].forEach(FolderSizer.invalidate) }
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let owner = environment.services
        // The index holds both folders without having read them.
        let store = IndexStore()
        let ids = store.write { s -> Range<Int32> in
            let root = s.addRoot(path: tree.root.path, mtime: 0)
            s.flags[Int(root)] &= ~IndexStore.Flag.unreadDirectory
            let names = Array("cloudrow".utf8)
            let items = [5, 3].enumerated().map { index, length in
                ScannedItem(nameOffset: index == 0 ? 0 : 5, nameLength: length, isDirectory: true, isPackage: false,
                            isSymlink: false, isHidden: false, isMountPoint: false, size: 0, mtime: 1)
            }
            return names.withUnsafeBytes { s.appendChildren(items, nameBuffer: $0, of: root) }
        }
        let index = FileIndex(storage: environment.storage, copies: owner.copies, preferences: environment.preferences,
                              store: store, configuredRoots: [tree.root.path], started: true)
        index.setPhase(.ready)
        let released = DispatchSemaphore(value: 0)
        defer { released.signal() }
        let services = BrowserServices.configured(
            transfers: owner.transfers, visits: owner.visits, windows: .headless,
            remote: owner.remote, containers: owner.containers, containerStore: owner.containerStore,
            clipboard: owner.clipboard, folderSizes: { _, _ in
                // Only stops a walk whose test never ends.
                _ = released.wait(timeout: .now() + 600)
                released.signal()
                return FolderSize(bytes: 900, files: 9)
            }, index: index
        )
        let browser = BrowserViewController(services: services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        browser.load(tree.root)
        await browser.directoryReads.task?.value
        try #require(browser.isLoaded)
        defer { browser.stopBackgroundWork() }

        // You ask for one (the Inspector, Disk Usage); a list asks for the other on its own account.
        #expect(index.folderSizeLookup(cloud) == .unindexed && index.folderSizeLookup(row) == .unindexed)
        #expect(browser.folderSize(cloud, request: true, askedBy: .inspector) == nil && browser.sizer.isPending(cloud))
        #expect(browser.folderSize(row, request: true) == nil && browser.sizer.isPending(row))

        // The index reads everything again, and then holds the folder with part of it unread: the walk you asked
        // for goes on through both, the other stops, as the index will have that one's size.
        index.setPhase(.scanning(items: 0))
        #expect(index.folderSizeLookup(cloud) == .pending)
        #expect(browser.folderSize(cloud) == nil && browser.folderSize(row) == nil)
        browser.indexChanged()
        #expect(browser.sizer.isPending(cloud) && !browser.sizer.isPending(row))
        store.write { s in
            s.flags[Int(ids.lowerBound)] &= ~IndexStore.Flag.unreadDirectory
            s.flags[Int(ids.lowerBound + 1)] &= ~(IndexStore.Flag.unreadDirectory | IndexStore.Flag.unknownAllocation)
        }
        index.setPhase(.ready)
        #expect(browser.folderSize(cloud) == FolderSize(bytes: 0, files: 0, allocatedBytes: 0, allocationComplete: false))
        browser.indexChanged()
        #expect(browser.sizer.isPending(cloud))

        // It ends: its size is of everything, and is what views show while the index's total is not.
        released.signal()
        var turns = 0
        while FolderSizer.askedSize(cloud) == nil {
            turns += 1
            try #require(turns < 10_000, "The walk asked for never ended.")
            try await Task.sleep(for: .milliseconds(3))
        }
        #expect(browser.folderSize(cloud)?.bytes == 900 && browser.folderSize(row)?.bytes == 0)
        // Rows sorted by size are ordered by the size they show.
        browser.applySort(.size, ascending: true, remember: false)
        #expect(browser.allRows.map(\.url.lastPathComponent) == ["row", "cloud"])
        // And while the index reads the folder again.
        store.write { s in s.flags[Int(ids.lowerBound)] |= IndexStore.Flag.unreadDirectory }
        index.setPhase(.scanning(items: 0))
        #expect(index.folderSizeLookup(cloud) == .pending && browser.folderSize(cloud)?.bytes == 900)
        // Once the index has read all of it, the index's total is the one.
        store.write { s in
            s.flags[Int(ids.lowerBound)] &= ~(IndexStore.Flag.unreadDirectory | IndexStore.Flag.unknownAllocation)
        }
        index.setPhase(.ready)
        #expect(browser.folderSize(cloud) == FolderSize(bytes: 0, files: 0, allocatedBytes: 0, allocationComplete: true))
        // What was measured before that does not stand in for a total the index gives later.
        store.write { s in s.flags[Int(ids.lowerBound)] |= IndexStore.Flag.unreadDirectory }
        index.setPhase(.scanning(items: 0))
        #expect(index.folderSizeLookup(cloud) == .pending && browser.folderSize(cloud) == nil)
        #expect(tree.snapshot() == ["cloud/", "cloud/file.txt", "row/", "row/file.txt"])
    }
}
