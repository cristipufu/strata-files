import AppKit

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
    /// Until the first windows are decided: files and folders opened meanwhile (AppKit hands them over before launch is
    /// done) are what's shown, so the last session isn't reopened over them.
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
        StrataAI.startIndexing()
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

    /// What was opened at launch, else the last session's windows, else one at the start location. Reads slow to answer
    /// (a disk spinning up, a share that stopped) don't leave Strata without a window: after a few seconds the start
    /// window opens, and the session's windows take its place when they're read, if it hasn't been used meanwhile.
    private func openFirstWindows() async {
        launching = false
        guard !openedAtLaunch, windowControllers.isEmpty else { return presentWelcome() }
        var standIn: BrowserWindowController?
        let fallback = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, windowControllers.isEmpty else { return }
            standIn = openWindow(at: startLocation)
            presentWelcome()
        }
        let plans = await sessionPlans()
        fallback.cancel()
        if let standIn, !standIn.isClosed, Self.isUnused(standIn, at: startLocation), windowControllers.count == 1, !plans.isEmpty {
            standIn.window?.close()
        }
        if windowControllers.isEmpty {
            if !openSession(plans) { openWindow(at: startLocation) }
        }
        presentWelcome()
    }

    /// A window that's still where it opened, with nothing to go back to: one the user hasn't used yet.
    private static func isUnused(_ controller: BrowserWindowController, at location: URL) -> Bool {
        controller.panes.count == 1 && controller.pane.history == PaneHistory()
            && controller.location.standardizedFileURL == location.standardizedFileURL
    }

    /// The Full Disk Access welcome, once, on the first window.
    private func presentWelcome() {
        guard welcome == nil, !Privacy.hasFullDiskAccess, !Prefs.shared.defaults.bool(forKey: "welcomeShown"),
              let window = windowControllers.first?.window else { return }
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
        // A workspace opens its own window.
        if url.host == "workspace" {
            guard let name = value("name") else { return }
            NSApp.activate()
            if let workspace = browserServices.workspaces.named(name) { browserServices.workspaces.open(workspace) } else { noSuchWorkspace() }
            return
        }
        let controller = (NSApp.keyWindow?.windowController as? BrowserWindowController) ?? windowControllers.first ?? openWindow(at: Places.home)
        switch url.host {
        case "search":
            guard let query = value("q") else { return }
            controller.search(query, in: value("in").flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) })
        case "open":
            guard let path = value("path") else { return }
            let expanded = (path as NSString).expandingTildeInPath
            guard !expanded.isEmpty else { return }
            // A folder opens; a file (or package) is shown selected in its folder.
            let target = URL(fileURLWithPath: expanded)
            Task { [weak controller] in
                let opening = await FileEntry.opening(target)
                guard let controller, !controller.isClosed else { return }
                if opening == .item {
                    controller.navigate(to: target.deletingLastPathComponent(), select: target)
                } else {
                    controller.navigate(to: target)
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
        // In the order given, each once what it is has been read.
        if launching { openedAtLaunch = true }
        Task {
            for url in files {
                if await FileEntry.opening(url) == .folder {
                    openWindow(at: url)
                } else {
                    openWindow(at: url.deletingLastPathComponent(), select: url)
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Strata's own windows, not the search box in the Dock (which is always showing).
        if !windowControllers.contains(where: { $0.window?.isVisible == true }) { openWindow(at: startLocation) }
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
        saveSession()
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

    // MARK: - Reopening windows

    private static let sessionKey = "lastSession"

    /// Every window's tabs (and each tab's panes), frontmost first, to reopen at the next launch.
    private func saveSession() {
        var seen = Set<ObjectIdentifier>()
        var windows: [Workspace] = []
        for window in NSApp.orderedWindows where window.windowController is BrowserWindowController {
            let tabs = window.tabbedWindows ?? [window]
            guard let first = tabs.first, seen.insert(ObjectIdentifier(first)).inserted else { continue }
            let controllers = tabs.compactMap { $0.windowController as? BrowserWindowController }
            guard !controllers.isEmpty else { continue }
            // The window remembers the workspace it came from, so Update and bringing it forward still work, and panes
            // waiting for a share keep its address.
            windows.append(Workspaces.workspace(named: controllers[0].groupWorkspaceName ?? "", of: controllers, includingNavigation: true))
        }
        if let data = SessionStorage.encode(windows) {
            browserServices.preferences.defaults.set(data, forKey: Self.sessionKey)
        }
    }

    /// The last session's windows to reopen (Settings ▸ General ▸ Reopen windows), their folders looked at; none when
    /// it's off or there's no session.
    private func sessionPlans() async -> [(plan: WorkspacePlan, name: String)] {
        guard browserServices.preferences.reopenWindows, let data = browserServices.preferences.defaults.data(forKey: Self.sessionKey),
              let windows = SessionStorage.decode(data) else { return [] }
        let workspaces = browserServices.workspaces
        var plans: [(plan: WorkspacePlan, name: String)] = []
        // Back to front, so the frontmost window ends up in front again. Folders that are gone are skipped.
        for window in windows.reversed() {
            // Shares aren't connected at launch (no login windows out of nowhere): their panes wait, and opening the
            // workspace connects them.
            let plan = await workspaces.plan(window)
            guard !plan.tabs.isEmpty else { continue }
            plans.append((plan, window.name.isEmpty ? "" : workspaces.named(window.name)?.name ?? ""))
        }
        return plans
    }

    /// Opens them; false when none opened.
    private func openSession(_ plans: [(plan: WorkspacePlan, name: String)]) -> Bool {
        var opened = false
        for (plan, name) in plans {
            opened = !browserServices.workspaces.openWindows(plan, name: name).isEmpty || opened
        }
        return opened
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
    func openWindow(at url: URL, select: URL? = nil, secondPane: URL? = nil, tabbedWith parent: NSWindow? = nil, services: BrowserServices? = nil) -> BrowserWindowController {
        let controller = BrowserWindowController(location: url, select: select, secondPane: secondPane, services: services ?? browserServices)
        windowControllers.append(controller)
        controller.onClose = { [weak self, weak controller] in
            self?.windowControllers.removeAll { $0 === controller }
        }
        if let parent, let window = controller.window {
            parent.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        } else {
            if let key = NSApp.keyWindow, let window = controller.window {
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
        openWindow(at: newWindowLocation(current: current))
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
