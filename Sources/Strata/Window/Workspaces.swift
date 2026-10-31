import AppKit

extension Notification.Name {
    /// A workspace was saved, updated, renamed or deleted.
    static let workspacesChanged = Notification.Name("StrataWorkspacesChanged")
}

final class Workspaces {
    static var shared: Workspaces { BrowserServices.shared.workspaces }

    private weak var services: BrowserServices?
    private let preferences: Prefs
    private let remote: RemoteServices
    private let key = "workspaces"

    init(services: BrowserServices) {
        self.services = services
        preferences = services.preferences
        remote = services.remote
    }

    /// Only this environment’s live tabs contribute to a saved workspace.
    func ownedControllers(of window: NSWindow) -> [BrowserWindowController] {
        guard let services else { return [] }
        return Self.controllers(of: window).filter { $0.services === services && !$0.isClosed }
    }

    /// Sorted by name.
    var all: [Workspace] {
        get {
            guard let data = preferences.defaults.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([Workspace].self, from: data)) ?? []
        }
        set {
            let sorted = newValue.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            preferences.defaults.set(try? JSONEncoder().encode(sorted), forKey: key)
            preferences.notifications.post(name: .workspacesChanged, object: nil)
        }
    }

    /// By name: spelled exactly, else ignoring case.
    func named(_ name: String) -> Workspace? {
        let saved = all
        return saved.first { $0.name == name } ?? saved.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - Saving

    /// `window`'s tabs (in tab order), each with its panes' folders and views.
    static func controllers(of window: NSWindow) -> [BrowserWindowController] {
        (window.tabbedWindows ?? [window]).compactMap { $0.windowController as? BrowserWindowController }
    }

    /// A workspace named `name` of `controllers`' tabs and panes, as they are now.
    /// Panes waiting for a share keep its address, so the folder still opens next time.
    static func workspace(named name: String, of controllers: [BrowserWindowController], includingNavigation: Bool = false) -> Workspace {
        let tabs = controllers.map(\.snapshot)
        var found = shares(for: tabs.flatMap { $0 }) ?? [:]
        for controller in controllers { found.merge(controller.waitingShares) { current, _ in current } }
        var workspace = Workspace(name: name, tabs: tabs, modes: controllers.map(\.snapshotModes), saved: Date(),
                                  shares: found.isEmpty ? nil : found)
        if includingNavigation {
            workspace.navigation = controllers.map(\.snapshotNavigation)
            workspace.activePanes = controllers.map { owner in owner.panes.firstIndex { $0 === owner.pane } ?? 0 }
            let selected = controllers.first?.window?.tabGroup?.selectedWindow
            workspace.selectedTab = controllers.firstIndex { $0.window === selected } ?? 0
            for (t, owner) in controllers.enumerated() {
                for (p, pane) in owner.panes.enumerated() where pane.waiting == nil {
                    if SavedDestination.capture(.folder(pane.location), services: owner.services) == nil {
                        workspace.tabs[t][p] = Places.home.path
                    }
                }
            }
        }
        return workspace
    }

    /// The network shares `paths` are on, with the address each mounts from. Only the kinds Connect to Server supports
    /// are kept, never with a password.
    static func shares(for paths: [String]) -> [String: String]? {
        var found: [String: String] = [:]
        for path in paths where !path.isEmpty {
            guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeURLKey, .volumeURLForRemountingKey]),
                  let volume = values.volume, let address = values.volumeURLForRemounting,
                  ServerConnection.schemes.contains(address.scheme?.lowercased() ?? "") else { continue }
            found[volume.path] = ServerConnection.displayString(address)
        }
        return found.isEmpty ? nil : found
    }

    /// Saves (or replaces, by name) `workspace`, and marks the windows it was made of as that workspace.
    func save(_ workspace: Workspace, from controllers: [BrowserWindowController]) {
        // Exactly that one: names saved before differing only by case are separate workspaces.
        var saved = all.filter { $0.name != workspace.name }
        saved.append(workspace)
        all = saved
        controllers.filter { $0.services === services && !$0.isClosed }.forEach { $0.workspaceName = workspace.name }
    }

    /// Asks for a name (showing what's saved) and saves every tab of `window` and its panes.
    func saveCurrent(from window: NSWindow) {
        let controllers = ownedControllers(of: window)
        guard !controllers.isEmpty, let content = window.contentViewController else { return }
        let sheet = SaveWorkspaceController(window: window, workspaces: self)
        content.presentAsSheet(sheet)
    }

    /// Saves `window`'s tabs and panes as they are now into the workspace it was opened from (or saved as).
    func update(_ name: String, from window: NSWindow) {
        let controllers = ownedControllers(of: window)
        guard !controllers.isEmpty, let existing = named(name) else { return }
        save(Self.workspace(named: existing.name, of: controllers), from: controllers)
    }

    enum RenameResult { case renamed, taken, gone }

    func rename(_ name: String, to newName: String) -> RenameResult {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        var saved = all
        guard !trimmed.isEmpty, let index = saved.firstIndex(where: { $0.name == name }) else { return .gone }
        if saved.contains(where: { $0.name != name && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) { return .taken }
        saved[index].name = trimmed
        all = saved
        for controller in openControllers(named: name) { controller.workspaceName = trimmed }
        return .renamed
    }

    func delete(_ name: String) {
        all.removeAll { $0.name == name }
        for controller in openControllers(named: name) { controller.workspaceName = nil }
    }

    /// Asks first (there's no undo), then deletes.
    func confirmDelete(_ name: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete the workspace “\(name)”?")
        alert.informativeText = String(localized: "Its folders stay where they are; only the saved setup goes.")
        alert.addButton(withTitle: String(localized: "Delete", comment: "Alert button: delete for good"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        if let window {
            alert.beginSheetModal(for: window) { [self] response in
                MainActor.assumeIsolated { if response == .alertFirstButtonReturn { delete(name) } }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            delete(name)
        }
    }

    /// Asks for a new name for `name`, as a sheet on `window` (or on its own).
    func askToRename(_ name: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename Workspace")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = name
        field.placeholderString = String(localized: "Name", comment: "Placeholder: the new workspace's name")
        ThemeStyle.bind(field, to: .preview)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Rename", comment: "Button: rename the workspace"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        let done: (NSApplication.ModalResponse) -> Void = { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != name else { return }
            if rename(name, to: newName) == .taken {
                let taken = NSAlert()
                taken.messageText = String(localized: "There’s already a workspace named “\(newName)”")
                taken.informativeText = String(localized: "Pick another name, or delete that workspace first.")
                if let window { taken.beginSheetModal(for: window) } else { taken.runModal() }
            }
        }
        if let window {
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { done(response) } }
        } else {
            done(alert.runModal())
        }
    }

    // MARK: - Opening

    /// The windows (tabs) opened from, or saved as, the workspace `name`.
    func openControllers(named name: String) -> [BrowserWindowController] {
        guard let services else { return [] }
        return services.windows.controllers().filter { $0.services === services && $0.workspaceName == name && !$0.isClosed }
    }

    /// Opens `workspace` as one window with a tab per saved tab, or brings its window to the front when it's open.
    /// Folders on a network share connect to it again; folders that are gone are left out, and said so.
    /// Workspaces connecting to their shares or servers right now: opening one again meanwhile only brings it forward.
    private var connecting: Set<String> = []

    /// Whether a folder is there for opening a workspace. Only one that doesn't exist is gone: one Strata may not read
    /// (access not granted yet, a folder above it locked) is still opened, and says why.
    nonisolated static func isThere(_ path: String) -> Bool {
        var info = stat()
        if stat(path, &info) == 0 { return true }
        return errno != ENOENT && errno != ENOTDIR
    }

    ///
    /// Opened from its own window (`from`: the sidebar, the menus), the window goes back to the workspace as it was
    /// saved, in the same place on screen; bringing it forward would do nothing you could see.
    func open(_ workspace: Workspace, from current: NSWindow? = nil) {
        var replacing: NSWindow?
        if !workspace.name.isEmpty, let open = openControllers(named: workspace.name).first(where: { !$0.isClosed }),
           let window = open.window {
            let front = window.tabGroup?.selectedWindow ?? window
            if front.isMiniaturized { front.deminiaturize(nil) }
            if connecting.contains(workspace.name) { return front.makeKeyAndOrderFront(nil) }
            if let current, (window.tabGroup?.windows ?? [window]).contains(current) {
                replacing = current
            } else {
                return bringForward(front, of: workspace)
            }
        }
        let plan = plan(workspace)
        guard !plan.tabs.isEmpty else {
            let alert = NSAlert()
            alert.messageText = String(localized: "None of the folders in “\(workspace.name)” are there anymore")
            alert.informativeText = Self.list(plan.missing)
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Delete Workspace"))
            if alert.runModal() == .alertSecondButtonReturn { confirmDelete(workspace.name, in: nil) }
            return
        }
        let old = replacing.map { ownedControllers(of: $0) } ?? []
        let frame = replacing.map { ($0.tabGroup?.selectedWindow ?? $0).frame }
        let controllers = openWindows(plan, name: workspace.name)
        guard !controllers.isEmpty else { return }
        old.forEach { $0.workspaceName = nil }
        if let frame { controllers.first?.window?.setFrame(frame, display: false) }
        controllers.first?.window?.makeKeyAndOrderFront(nil)
        // After this click (or menu choice) is done with the window it came from.
        DispatchQueue.main.async { old.forEach { $0.window?.close() } }
        connect(controllers, of: workspace, missing: plan.missing, offline: plan.offline)
    }

    /// Its window, open elsewhere, to the front; panes still waiting get another go.
    private func bringForward(_ window: NSWindow, of workspace: Workspace) {
        window.makeKeyAndOrderFront(nil)
        // Panes still waiting: a disk plugged in since shows its folder; a share is connected again.
        let controllers = ownedControllers(of: window)
        for controller in controllers {
            for (index, folder) in controller.waitingPanes where folder.mountPoint == nil && FileManager.default.fileExists(atPath: folder.path) {
                controller.navigatePane(index, to: URL(fileURLWithPath: folder.path), mode: folder.mode)
            }
        }
        if controllers.contains(where: { !$0.waitingShares.isEmpty || $0.waitingPanes.contains { $0.folder.server != nil } }) {
            connect(controllers, of: workspace, missing: [], offline: [])
        }
    }

    /// One window with a tab per planned tab, in order. Panes whose folder can't be shown yet start at Home and wait
    /// for it (see `WaitingFolder`).
    @discardableResult
    func openWindows(_ plan: WorkspacePlan, name: String) -> [BrowserWindowController] {
        guard let services else { return [] }
        var controllers: [BrowserWindowController] = []
        for tab in plan.tabs where !tab.isEmpty {
            let location = tab[0].waiting == nil && !tab[0].path.isEmpty ? URL(fileURLWithPath: tab[0].path) : Places.home
            let second = tab.count > 1 ? (tab[1].waiting == nil && !tab[1].path.isEmpty ? URL(fileURLWithPath: tab[1].path) : Places.home) : nil
            // Each tab goes after the one before, so they keep their order.
            guard let controller = services.windows.open(location, second, controllers.last?.window, services) else {
                controllers.forEach { $0.window?.close() }
                return []
            }
            controller.applyModes(tab.map { $0.waiting == nil ? $0.mode : nil })
            for (index, pane) in tab.enumerated() {
                if let waiting = pane.waiting { controller.wait(pane: index, for: waiting) }
            }
            controller.workspaceName = name.isEmpty ? nil : name
            controller.restoreNavigation(tab)
            controllers.append(controller)
        }
        let selected = plan.selectedTab.flatMap { controllers.indices.contains($0) ? controllers[$0].window : nil }
            ?? controllers.first?.window
        if let selected { selected.tabGroup?.selectedWindow = selected }
        return controllers
    }

    /// Resolve saved server paths against this workspace's owner, including copies not created yet.
    func plan(_ workspace: Workspace) -> WorkspacePlan {
        WorkspacePlan(workspace, exists: Self.isThere, server: { [copies = remote.copies] path in
            guard !path.isEmpty else { return nil }
            return copies.server(containing: URL(fileURLWithPath: path))?.server.id
        })
    }

    /// Connects to the shares and servers that `controllers`' panes wait for, one at a time (macOS or ssh may ask for a
    /// name and password), with a sheet that can stop it; then shows each waiting pane's folder and says what didn't
    /// work out.
    private func connect(_ controllers: [BrowserWindowController], of workspace: Workspace, missing: [String], offline: [String]) {
        guard let browsing = services?.remoteBrowsing else { return }
        var shares: [String: String] = [:]
        var servers: [String] = []
        for controller in controllers {
            shares.merge(controller.waitingShares) { current, _ in current }
            for (_, folder) in controller.waitingPanes { if let id = folder.server, !servers.contains(id) { servers.append(id) } }
        }
        // On the tab being looked at.
        let shown = controllers.first?.window.map { $0.tabGroup?.selectedWindow ?? $0 }
        guard !shares.isEmpty || !servers.isEmpty, let window = shown, let content = window.contentViewController else {
            return report(missing: missing, offline: offline, problems: [], of: workspace, controllers: controllers)
        }
        let sheet = WorkspaceConnectController()
        content.presentAsSheet(sheet)
        if !workspace.name.isEmpty { connecting.insert(workspace.name) }
        Task { [self] in
            defer { connecting.remove(workspace.name) }
            var mounted: [String: String] = [:]
            var problems: [String] = []
            for (mountPoint, address) in shares.sorted(by: { $0.key < $1.key }) {
                guard !sheet.isCancelled else { break }
                // Kept by Strata, but checked like a typed address: only the kinds of server Connect to Server allows.
                guard case .success(let url) = ServerConnection.url(from: address) else {
                    problems.append(address)
                    continue
                }
                sheet.show(ServerConnection.displayString(url))
                if let already = ServerConnection.mounted(url) {
                    mounted[mountPoint] = already.path
                    continue
                }
                let request = ServerConnection.Request()
                sheet.onCancel = { request.cancel() }
                switch await ServerConnection.mount(url, request: request) {
                case .success(let at): mounted[mountPoint] = at.path
                case .failure(let problem):
                    problems.append(String(localized: "\(ServerConnection.displayString(url)): \(problem.message)",
                                           comment: "A server address, then why it didn't connect"))
                case nil: break
                }
            }
            // SFTP servers and buckets: connected (ssh may ask for a password), then their folders listed down to each.
            var connected: Set<String> = []
            for id in servers {
                guard !sheet.isCancelled, let server = remote.servers.server(id: id) else { continue }
                sheet.show(server.name)
                do {
                    try await sheet.connect(server, using: browsing)
                    connected.insert(id)
                } catch {
                    if !sheet.isCancelled {
                        problems.append(String(localized: "\(server.name): \(RemoteFiles.message(for: error))", comment: "A server's name, then why it didn't connect"))
                    }
                }
            }
            let cancelled = sheet.isCancelled
            if content.presentedViewControllers?.contains(sheet) == true { content.dismiss(sheet) }
            for controller in controllers where !controller.isClosed {
                for (index, folder) in controller.waitingPanes {
                    guard let id = folder.server, connected.contains(id) else { continue }
                    let url = URL(fileURLWithPath: folder.path)
                    let found = await browsing.reveal(url)
                    // Moved elsewhere (or closed) while that was read: left where it is now.
                    guard !controller.isClosed, controller.waitingPanes.contains(where: { $0.index == index && $0.folder == folder }) else { continue }
                    if found {
                        controller.navigatePane(index, to: url, mode: folder.mode)
                    } else {
                        // Not on the server anymore: the pane keeps waiting (so the workspace keeps it) and it's said.
                        problems.append(String(localized: "\(remote.servers.server(id: id)?.name ?? ""): “\(url.lastPathComponent)” isn’t there.",
                                               comment: "A server's name, then a folder that wasn't found on it"))
                    }
                }
            }
            var gone = missing
            // Tabs closed meanwhile are left alone.
            for controller in controllers where !controller.isClosed {
                for (index, folder) in controller.waitingPanes {
                    guard let mountPoint = folder.mountPoint, let at = mounted[mountPoint] else { continue }
                    let path = WorkspacePlan.path(folder.path, from: mountPoint, to: at)
                    if FileManager.default.fileExists(atPath: path) {
                        controller.navigatePane(index, to: URL(fileURLWithPath: path), mode: folder.mode)
                    } else {
                        gone.append(folder.path)
                    }
                }
            }
            report(missing: gone, offline: offline, problems: cancelled ? [] : problems, of: workspace, controllers: controllers)
        }
    }

    /// Says which folders weren't there (offering to take them out of the workspace), which are on disks that aren't
    /// connected (kept), and which shares didn't connect.
    private func report(missing: [String], offline: [String], problems: [String], of workspace: Workspace,
                               controllers: [BrowserWindowController]) {
        guard !missing.isEmpty || !offline.isEmpty || !problems.isEmpty,
              let first = controllers.first(where: { !$0.isClosed })?.window else { return }
        // On the tab being looked at.
        let window = first.tabGroup?.selectedWindow ?? first
        let alert = NSAlert()
        var sections: [String] = []
        if !missing.isEmpty {
            alert.messageText = String(localized: "Some folders in “\(workspace.name)” aren’t there anymore")
            sections.append(Self.list(missing))
        } else if !offline.isEmpty {
            alert.messageText = String(localized: "Some folders in “\(workspace.name)” are on a disk that isn’t connected")
        } else {
            alert.messageText = String(localized: "Some servers in “\(workspace.name)” didn’t connect")
        }
        if !offline.isEmpty {
            sections.append(Self.list(offline) + "\n" + String(localized: "Those panes show your home folder for now. Connect the disk, then open the workspace again."))
        }
        if !problems.isEmpty { sections.append(problems.joined(separator: "\n")) }
        alert.informativeText = sections.joined(separator: "\n\n")
        alert.addButton(withTitle: String(localized: "OK"))
        let canPrune = !missing.isEmpty && !workspace.name.isEmpty && named(workspace.name) != nil
        if canPrune { alert.addButton(withTitle: String(localized: "Remove from Workspace", comment: "Button: take the missing folders out of the saved workspace")) }
        alert.beginSheetModal(for: window) { [self] response in
            MainActor.assumeIsolated {
                guard canPrune, response == .alertSecondButtonReturn, let saved = named(workspace.name) else { return }
                let gone = Set(missing)
                var others = all.filter { $0.name != saved.name }
                others.append(saved.removing(gone))
                all = others
                // Panes still kept for those folders let them go too.
                for controller in controllers where !controller.isClosed {
                    for (index, folder) in controller.waitingPanes where gone.contains(folder.path) { controller.stopWaiting(pane: index) }
                }
            }
        }
    }

    /// Folders as a short list: a few, then how many more.
    private static func list(_ paths: [String]) -> String {
        let nonEmpty = paths.filter { !$0.isEmpty }
        let shown = nonEmpty.prefix(5).map { Format.tildePath(URL(fileURLWithPath: $0)) }
        var lines = shown
        if nonEmpty.count > shown.count { lines.append(String(localized: "and \(nonEmpty.count - shown.count) more", comment: "plural")) }
        return lines.joined(separator: "\n")
    }

    /// "3 tabs · Dual pane", for menus and the palette.
    static func summary(_ workspace: Workspace) -> String {
        var parts = [String(localized: "\(workspace.tabs.count) tabs", comment: "plural")]
        if workspace.isDualPane { parts.append(String(localized: "Dual Pane")) }
        return parts.joined(separator: " · ")
    }

    /// What a workspace's row looks like: two panes, several tabs, or one window.
    static func symbol(_ workspace: Workspace) -> String {
        workspace.isDualPane ? "rectangle.split.2x1" : workspace.tabs.count > 1 ? "rectangle.stack" : "macwindow"
    }

    /// Its tabs' folders and when it was saved, for a tooltip. Names only: nothing is read from disk (a folder may be on
    /// a share that isn't there).
    func help(_ workspace: Workspace) -> String {
        var lines = workspace.tabs.map { tab in
            tab.compactMap { path -> String? in
                guard !path.isEmpty else { return nil }
                let url = URL(fileURLWithPath: path)
                if let (server, top) = remote.copies.server(containing: url), top.standardizedFileURL.path == url.standardizedFileURL.path { return server.name }
                return url.lastPathComponent.isEmpty ? path : url.lastPathComponent
            }.joined(separator: "  |  ")
        }
        if let saved = workspace.saved { lines.append(String(localized: "Saved \(Format.date(saved))", comment: "Tooltip: when the workspace was saved")) }
        return lines.joined(separator: "\n")
    }
}
