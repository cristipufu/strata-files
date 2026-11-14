import AppKit
import Synchronization
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    let browserServices: BrowserServices

    init(browserServices: BrowserServices) {
        self.browserServices = browserServices
        super.init()
    }

    let undoManager = UndoManager()
    private lazy var historyWindow = HistoryWindowController(history: browserServices.transfers.history,
                                                            undoManager: undoManager, frameAutosaveName: "StrataHistory")
    private var windowControllers: [BrowserWindowController] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before anything opens (a strata:// link or `strata -w` arrives before launching finishes): saved servers are
        // known, and copies a crash left are set aside (removed once launched).
        RemoteServerStore.shared.load()
        RemoteCopyStore.shared.setAsideForRemoval()
        Self.raiseFileLimit()
        registerRevealHandler()
        let preferences = browserServices.preferences
        FileViewStyle.applyTheme(preferences)
        ThemeStyle.apply(preferences.colorThemeOptions, windows: [])
        NotificationCenter.default.addObserver(forName: .appearanceChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                FileViewStyle.applyTheme(preferences)
                ThemeStyle.apply(preferences.colorThemeOptions, windows: NSApp.windows)
            }
        }
        NotificationCenter.default.addObserver(forName: .colorThemeChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ThemeStyle.apply(preferences.colorThemeOptions, windows: NSApp.windows) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                FileViewStyle.applyTheme(preferences)
                ThemeStyle.apply(preferences.colorThemeOptions, windows: NSApp.windows)
            }
        }
        let index = browserServices.index
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { index.saveWhenIdle() }
        }
        // Content matches follow the index's: with the index turned off nothing shows them, so they aren't gathered.
        NotificationCenter.default.addObserver(forName: .indexDidSwitch, object: index, queue: nil) { _ in
            MainActor.assumeIsolated {
                if index.isOn { StrataAI.startIndexing() } else { StrataAI.stopIndexing() }
            }
        }
        NSApp.mainMenu = MainMenu.build()
        // Your own shortcuts (Settings ▸ Shortcuts) over the built-in ones.
        if let menu = NSApp.mainMenu { ShortcutStore.shared.install(menu) }
    }

    /// macOS starts apps with room for 256 open files; folder watchers (lists, columns, folder trees), the index and
    /// copies all hold some. Raised as far as the system allows, to a sensible ceiling.
    private static func raiseFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let wanted = min(limit.rlim_max, 8192)
        guard limit.rlim_cur < wanted else { return }
        limit.rlim_cur = wanted
        setrlimit(RLIMIT_NOFILE, &limit)
    }

    private var welcome: WelcomeSheetController?
    /// Until the first windows are decided: files, folders and workspaces opened meanwhile (AppKit hands them over
    /// before launch is done) are what's shown, so the last session isn't reopened over them.
    private var launching = true
    private var openedAtLaunch = false

    /// Strata ▸ Check for Updates….
    @objc func checkForUpdates(_ sender: Any?) {
        Updates.shared.checkNow(sender)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        MainThreadWatchdog.start()
        #endif
        // Starts Sparkle (in a release build): background checks if allowed, and Check for Updates….
        _ = Updates.shared
        browserServices.index.start()
        ContainerStore.shared.start()
        ProjectEditors.warm()
        if browserServices.index.isOn { StrataAI.startIndexing() }
        // Loads history now, so a plain copy left by an earlier build is removed right away.
        _ = OperationLog.shared
        // Archives opened as folders and not looked at for a day; containers' and servers' files left by a crash.
        ContainerCopyStore.shared.setAsideForRemoval()
        DispatchQueue.global(qos: .utility).async {
            ArchiveCache.prune()
            ContainerCopyStore.shared.removeSetAside()
            RemoteCopyStore.shared.removeSetAside()
            CopyProviders.live.removeClipboardStaging()
        }
        DockSearch.shared.apply(atLaunch: true)
        Task { [weak self] in await self?.openFirstWindows() }
    }

    /// What was opened at launch, else the last session's windows, else one at the start location.
    private func openFirstWindows() async {
        guard !openedAtLaunch, windowControllers.isEmpty else {
            launching = false
            return presentWelcome()
        }
        await browserServices.windowSession.reopen(at: startLocation)?.value
        launching = false
        presentWelcome()
    }

    /// What each of `urls` opens as, in order: read on a thread for each disk, each kept as it's read, all within
    /// `patience` of asking, so a disk that doesn't answer holds up only its own paths; one not read by then goes by how
    /// it's spelled. A link is read on its own disk's thread: one into a share that stopped holds up what follows it
    /// there, which goes by its spelling.
    @concurrent nonisolated static func openings(of urls: [URL], within patience: Duration,
                                                reader: @escaping @Sendable (URL) -> FileEntry.Opening = FileEntry.readOpening,
                                                disk: @escaping @Sendable (String) -> String = DiskOfPath.of) async -> [FileEntry.Opening] {
        let end = ContinuousClock.now + patience
        let read = Mutex<[Int: FileEntry.Opening]>([:])
        let byDisk = Dictionary(grouping: urls.indices) { disk(urls[$0].path) }
        await withTaskGroup(of: Void.self) { group in
            for indices in byDisk.values {
                group.addTask { @Sendable in
                    _ = await OwnThread.run(within: max(end - .now, .zero), otherwise: false) {
                        for index in indices {
                            let opening = reader(urls[index])
                            read.withLock { $0[index] = opening }
                        }
                        return true
                    }
                }
            }
        }
        let answered = read.withLock { $0 }
        var openings: [FileEntry.Opening] = []
        for (index, url) in urls.enumerated() {
            if let found = answered[index] {
                openings.append(found)
            } else {
                openings.append(await opening(spelled: url))
            }
        }
        return openings
    }

    /// What `url` opens as by how it's spelled, for one whose disk doesn't answer: the system ends a folder's URL with a
    /// slash, and a package's too, which its extension's type tells apart (known to LaunchServices, not read from the
    /// disk, and away from the main thread all the same).
    @concurrent nonisolated static func opening(spelled url: URL) async -> FileEntry.Opening {
        guard url.hasDirectoryPath else { return .item }
        // Looked up as a folder's extension: as a file's, "app" is an application file, not a package.
        let isPackage = !url.pathExtension.isEmpty
            && UTType(filenameExtension: url.pathExtension, conformingTo: .directory)?.conforms(to: .package) == true
        return isPackage ? .item : .folder
    }

    /// Where the welcome goes, of `windows` front to back: the first one shown and free, else the first free one. One
    /// asking something in a sheet is never given it: a sheet waiting behind another can't be ended.
    static func welcomeHost<Window>(_ windows: [Window], isShown: (Window) -> Bool, isFree: (Window) -> Bool) -> Window? {
        let free = windows.filter(isFree)
        return free.first(where: isShown) ?? free.first
    }

    /// The Full Disk Access welcome, once, on the browser window in front. With every window asking something, it's
    /// shown at the next launch.
    private func presentWelcome() {
        let ours = windowControllers.filter { !$0.isClosed }
        let inFront = NSApp.orderedWindows.compactMap { window in ours.first { $0.window === window } }
        guard welcome == nil, !Privacy.hasFullDiskAccess, !Prefs.shared.defaults.bool(forKey: "welcomeShown"),
              let window = Self.welcomeHost(inFront + ours, isShown: { $0.window?.isVisible == true },
                                            isFree: { $0.window?.attachedSheet == nil })?.window else { return }
        let sheet = WelcomeSheetController()
        sheet.onGranted = { [weak self] in self?.windowControllers.forEach { $0.privacyChanged() } }
        welcome = sheet
        sheet.present(on: window)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Full Disk Access may have been switched on in Settings while we were in the background.
        let had = Privacy.hasFullDiskAccess
        Privacy.refresh()
        if Privacy.hasFullDiskAccess != had { windowControllers.forEach { $0.privacyChanged() } }
    }

    func registerRevealHandler() {
        // "Reveal in Finder" from other apps arrives as a 'misc'/'mvis' event when Strata is the file viewer.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleReveal(_:reply:)),
                                                     forEventClass: AEEventClass(kAEMiscStandards),
                                                     andEventID: AEEventID(kAEMakeObjectsVisible))
    }

    @objc private func handleReveal(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        let count = list.numberOfItems
        let urls = count == 0 ? [list.fileURLValue].compactMap { $0 } : (1...count).compactMap { list.atIndex($0)?.fileURLValue }
        reveal(urls)
    }

    /// Shows `folder` in the window in front (or a new one), from outside a window: the search box in the Dock.
    func showFolder(_ folder: URL) {
        if let controller = ((NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? BrowserWindowController) ?? windowControllers.first {
            controller.navigate(to: folder)
            controller.showWindow(nil)
        } else {
            openWindow(at: folder)
        }
        NSApp.activate()
    }

    /// Shows items selected in their folders, from outside a window: the search box in the Dock.
    func revealInStrata(_ urls: [URL]) { reveal(urls) }

    /// The window in front, or a new one when there's none: for commands run from outside a window.
    func frontController() -> BrowserWindowController {
        let front = ((NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? BrowserWindowController) ?? windowControllers.first
        if let front {
            front.showWindow(nil)
            return front
        }
        return openWindow(at: startLocation)
    }

    /// Opens each file's folder with the file selected (folders themselves open).
    private func reveal(_ urls: [URL]) {
        let byFolder = Dictionary(grouping: urls) { $0.deletingLastPathComponent() }
        for (folder, items) in byFolder {
            if let key = NSApp.keyWindow?.windowController as? BrowserWindowController {
                key.navigate(to: folder, select: items.first)
                key.showWindow(nil)
            } else {
                openWindow(at: folder, select: items.first)
            }
        }
        NSApp.activate()
    }

    /// strata://search?q=…&in=…, strata://open?path=…, strata://workspace?name=…, strata://recents, strata://duplicates
    private func handle(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        // A workspace opens its own window, once its folders are looked at: at launch it's what's shown, not the last
        // session. (The other links open a window right away, which does the same.)
        if url.host == "workspace" {
            guard let name = value("name") else { return }
            NSApp.activate()
            guard let workspace = browserServices.workspaces.named(name) else { return noSuchWorkspace() }
            if launching { openedAtLaunch = true }
            // Nothing to wait for when it's already being opened: that opening ends launch.
            guard let opening = browserServices.workspaces.open(workspace) else { return }
            let atLaunch = launching
            Task { [weak self] in
                await opening.value
                // None of its folders there (it said so): launch still ends with a window.
                guard let self else { return }
                if atLaunch, windowControllers.isEmpty { openWindow(at: startLocation) }
                presentWelcome()
            }
            return
        }
        let controller = (NSApp.keyWindow?.windowController as? BrowserWindowController) ?? windowControllers.first ?? openWindow(at: Places.home)
        switch url.host {
        case "search":
            guard let query = value("q") else { return }
            controller.search(query, in: value("in").flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) })
        case "open":
            guard let path = value("path") else { return }
            let expanded = (path as NSString).expandingTildeInPath
            guard !expanded.isEmpty else { return }
            // A folder opens; a file (or package) is shown selected in its folder.
            let target = URL(filePath: expanded, directoryHint: .inferFromPath)
            Task { [weak controller] in
                let (opening, located) = await FileEntry.locate(target)
                guard let controller, !controller.isClosed else { return }
                if opening == .item {
                    controller.navigate(to: located.deletingLastPathComponent(), select: located)
                } else {
                    controller.navigate(to: located)
                }
            }
        case "recents":
            controller.goRecents(nil)
        case "duplicates":
            controller.showDuplicates()
        case "shortcuts":
            showShortcuts(nil)
            return
        default:
            break
        }
        controller.showWindow(nil)
        NSApp.activate()
    }

    /// The name came from a link (or the command line): it isn't repeated back, and nothing blocks.
    private func noSuchWorkspace() {
        let alert = NSAlert()
        alert.messageText = String(localized: "There’s no workspace with that name")
        alert.informativeText = String(localized: "Your workspaces are in the sidebar and in Window ▸ Workspaces.")
        if let window = NSApp.keyWindow ?? windowControllers.first?.window {
            alert.beginSheetModal(for: window)
        } else {
            Sounds.beep()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "strata" { handle(url) }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if launching { openedAtLaunch = true }
        browserServices.windowSession.cancelRestoration()
        Task {
            for (url, opening) in zip(files, await Self.openings(of: files, within: .seconds(2))) {
                if opening == .folder {
                    openWindow(at: url)
                } else {
                    openWindow(at: url.deletingLastPathComponent(), select: url)
                }
            }
            presentWelcome()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Strata's own windows, not the search box in the Dock (which is always showing).
        if !launching { browserServices.windowSession.reopen(at: startLocation) }
        return true
    }

    /// Session restoration keeps its saved locations; this choice applies to newly created windows.
    private var startLocation: URL {
        newWindowLocation()
    }

    func newWindowLocation(current: URL? = nil) -> URL {
        let preferences = browserServices.preferences
        return preferences.newWindowLocation.folder(custom: preferences.customWindowFolder,
                                                     last: preferences.lastLocation, current: current, home: Places.home)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        browserServices.transfers.shouldTerminate(sender)
    }

    func applicationWillTerminate(_ notification: Notification) {
        browserServices.windowSession.save()
        browserServices.index.saveNow()
        OperationLog.waitForWrites()
        // Containers' and servers' files don't outlive Strata: removed now, as far as two seconds allow (the rest at
        // next launch). An SFTP connection's ssh ends by itself when Strata does (its input closes).
        ContainerCopyStore.shared.setAsideForRemoval()
        RemoteCopyStore.shared.setAsideForRemoval()
        let removed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            ContainerCopyStore.shared.removeSetAside()
            RemoteCopyStore.shared.removeSetAside()
            removed.signal()
        }
        _ = removed.wait(timeout: .now() + 2)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func toggleShelf(_ sender: Any?) {
        ShelfPanel.shared.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleShelf(_:)) { item.state = ShelfPanel.shared.isVisible ? .on : .off }
        if item.action == #selector(checkForUpdates(_:)) { return Updates.shared.canCheck }
        return true
    }

    @discardableResult
    func openWindow(at url: URL, select: URL? = nil, secondPane: URL? = nil, tabbedWith parent: NSWindow? = nil, services: BrowserServices? = nil, frame: SavedWindowFrame? = nil) -> BrowserWindowController {
        let controller = BrowserWindowController(location: url, select: select, secondPane: secondPane, services: services ?? browserServices, frame: frame)
        windowControllers.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self else { return }
            windowControllers.removeAll { $0 === controller }
            // The welcome goes with its window. It's shown again once the windows closing together have closed, on one
            // still open; with none left, at the next launch.
            if let welcome, welcome.parent == nil || welcome.parent === controller?.window {
                welcome.withdraw()
                self.welcome = nil
                DispatchQueue.main.async { [weak self] in self?.presentWelcome() }
            }
        }
        if let parent, let window = controller.window {
            parent.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        } else {
            if frame == nil, let key = NSApp.keyWindow, let window = controller.window {
                window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: key.frame.minX, y: key.frame.maxY)))
            }
            controller.showWindow(nil)
        }
        return controller
    }

    @objc func showShortcuts(_ sender: Any?) {
        ShortcutsWindowController.shared.show()
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc func showHistory(_ sender: Any?) {
        historyWindow.showWindow(nil)
    }

    @objc func newWindow(_ sender: Any?) {
        let current = (NSApp.keyWindow?.windowController as? BrowserWindowController)?.location
        browserServices.windowSession.openNewWindow(at: newWindowLocation(current: current))
    }

    private lazy var dockMenu = DockMenu(favorites: {
        Places.favorites(preferences: BrowserServices.shared.preferences, checks: BrowserServices.shared.places)
    }, newWindow: { [weak self] in
        self?.newWindow(nil)
        NSApp.activate()
    }, recents: { [weak self] in
        self?.frontController().goRecents(nil)
        NSApp.activate()
    }, openFolder: { [weak self] in
        self?.showFolder($0)
    })

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { dockMenu.build() }
}

// Makes `validateMenuItem` reachable (it shows the Shelf's state in the Window menu).
extension AppDelegate: NSMenuItemValidation {}
