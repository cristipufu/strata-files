import AppKit

@MainActor final class WindowSession {
    private static let sessionKey = "lastSession"
    private static let frameKey = "browserWindowFrame"

    private weak var services: BrowserServices?
    private let preferences: Prefs
    private let windows: BrowserWindows
    private let plan: @MainActor @Sendable (Workspace) async -> WorkspacePlan
    private var revision = UUID()
    private var reopening: Task<Void, Never>?
    private var closing: (members: Set<ObjectIdentifier>, workspace: Workspace)?
    private var closeWork: Task<Void, Never>?
    private var rememberedSession: [Workspace]?
    private var saveRevision = UUID()
    private(set) var saving: Task<Void, Never>?
    private weak var lastActive: BrowserWindowController?

    init(services: BrowserServices, plan: (@MainActor @Sendable (Workspace) async -> WorkspacePlan)? = nil) {
        self.services = services
        preferences = services.preferences
        windows = services.windows
        let workspaces = services.workspaces
        self.plan = plan ?? { await workspaces.plan($0) }
    }

    isolated deinit {
        reopening?.cancel()
        closeWork?.cancel()
        saving?.cancel()
    }

    private var controllers: [BrowserWindowController] {
        windows.controllers().filter { $0.services === services && !$0.isClosed }
    }

    func cancelRestoration() {
        finishClosing()
        let previous = reopening
        reopening = nil
        revision = UUID()
        previous?.cancel()
    }

    func windowBecameKey(_ controller: BrowserWindowController) {
        guard controller.services === services, !controller.isClosed else { return }
        lastActive = controller
    }

    func place(_ window: NSWindow, frame: SavedWindowFrame?) {
        let saved = frame ?? preferences.defaults.data(forKey: Self.frameKey)
            .flatMap(SavedWindowFrame.decode)
        if let saved, let rectangle = Self.restorationFrame(saved, in: windows.frameBounds()) {
            window.setFrame(rectangle, display: false)
        } else if !windows.restoreLegacyFrame(window) {
            window.center()
        }
    }

    nonisolated static func restorationFrame(_ saved: SavedWindowFrame, in candidates: [CGRect]) -> CGRect? {
        let bounds = candidates.filter { SavedWindowFrame($0) != nil }
        guard let first = bounds.first else { return nil }
        let desktop = bounds.dropFirst().reduce(first) { $0.union($1) }
        if SavedWindowFrame(desktop) != nil, desktop.contains(saved.rectangle),
           bounds.contains(where: { $0.intersects(saved.rectangle) }) {
            return saved.rectangle
        }
        let available = bounds.first(where: { $0.contains(saved.rectangle.origin) }) ?? first
        return saved.fitting(in: available)
    }

    func rememberFrame(of window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), let frame = SavedWindowFrame(window.frame),
              let data = try? JSONEncoder().encode(frame) else { return }
        preferences.defaults.set(data, forKey: Self.frameKey)
    }

    func windowWillClose(_ controller: BrowserWindowController) {
        guard let services, controller.services === services, !controller.isClosed, let window = controller.window else { return }
        rememberFrame(of: window)
        if closing?.members.contains(ObjectIdentifier(controller)) != true {
            let group = services.workspaces.ownedControllers(of: window)
            guard !group.isEmpty else { return }
            closing = (Set(group.map(ObjectIdentifier.init)), snapshot(group))
        }
        guard closeWork == nil else { return }
        // Native tabs closing together still belong to one group when the first callback arrives.
        closeWork = Task { [weak self] in
            guard !Task.isCancelled else { return }
            self?.finishClosing()
        }
    }

    func finishClosing() {
        let previous = closeWork
        closeWork = nil
        previous?.cancel()
        guard let closing else { return }
        self.closing = nil
        guard controllers.isEmpty else { return }
        let saved = [closing.workspace]
        rememberedSession = saved
        scheduleSave(saved)
    }

    func save() {
        cancelRestoration()
        let previous = saving
        saving = nil
        previous?.cancel()
        let open = controllers
        if let first = open.first?.window { rememberFrame(of: first) }
        guard !open.isEmpty else {
            if let rememberedSession { store(SessionStorage.encode(rememberedSession)) }
            return
        }
        var seen = Set<ObjectIdentifier>()
        let saved = open.compactMap { controller -> Workspace? in
            guard let window = controller.window else { return nil }
            let group = services?.workspaces.ownedControllers(of: window) ?? []
            guard let first = group.first, seen.insert(ObjectIdentifier(first)).inserted else { return nil }
            return snapshot(group)
        }
        rememberedSession = saved
        store(SessionStorage.encode(saved))
    }

    private func snapshot(_ group: [BrowserWindowController]) -> Workspace {
        Workspaces.workspace(named: group.first?.groupWorkspaceName ?? "", of: group, includingNavigation: true)
    }

    private func store(_ data: Data?) {
        if let data { preferences.defaults.set(data, forKey: Self.sessionKey) }
    }

    private func scheduleSave(_ saved: [Workspace]) {
        let previous = saving
        let request = UUID()
        saveRevision = request
        saving = Task { [weak self] in
            let data = await Self.encode(saved)
            guard !Task.isCancelled, let self, saveRevision == request else { return }
            saving = nil
            store(data)
        }
        previous?.cancel()
    }

    @discardableResult
    func reopen(at fallback: URL) -> Task<Void, Never>? {
        finishClosing()
        let open = controllers
        let recent = lastActive.flatMap { candidate in open.first { $0 === candidate } }
        if let owner = open.first(where: { $0.window?.isVisible == true }) ?? recent ?? open.first,
           let window = owner.window {
            windows.show(windows.selectedTab(window))
            return nil
        }
        return restore(at: fallback)
    }

    @discardableResult
    func openNewWindow(at fallback: URL) -> Task<Void, Never>? {
        finishClosing()
        guard controllers.isEmpty else { openFallback(at: fallback); return nil }
        return restore(at: fallback)
    }

    private func openFallback(at location: URL) {
        guard let services else { return }
        _ = windows.open(location, nil, nil, services, nil)
    }

    private func restore(at fallback: URL) -> Task<Void, Never>? {
        if let reopening { return reopening }
        let remembered = rememberedSession
        let data = preferences.defaults.data(forKey: Self.sessionKey)
        guard preferences.reopenWindows, remembered != nil || data != nil else {
            openFallback(at: fallback)
            return nil
        }
        let request = UUID()
        revision = request
        let plan = self.plan
        reopening = Task { [weak self] in
            let saved = await Self.read(remembered, data: data)
            guard !Task.isCancelled else { return }
            let planned = await Self.plans(saved ?? [], using: plan)
            guard !Task.isCancelled, let self, revision == request else { return }
            reopening = nil
            apply(planned, fallback: fallback)
        }
        return reopening
    }

    private func apply(_ planned: [(Workspace, WorkspacePlan)], fallback: URL) {
        guard controllers.isEmpty, let services else { return }
        var opened = false
        if preferences.reopenWindows {
            for (workspace, plan) in planned.reversed() where !plan.tabs.isEmpty {
                let name = workspace.name.isEmpty ? "" : services.workspaces.named(workspace.name)?.name ?? ""
                opened = !services.workspaces.openWindows(plan, name: name).isEmpty || opened
            }
        }
        if !opened { openFallback(at: fallback) }
    }

    @concurrent private static func read(_ remembered: [Workspace]?, data: Data?) async -> [Workspace]? {
        if let remembered { return SessionStorage.bounded(remembered) }
        return data.flatMap(SessionStorage.decode)
    }

    @concurrent private static func encode(_ saved: [Workspace]) async -> Data? {
        SessionStorage.encode(saved)
    }

    private static func plans(_ saved: [Workspace], using plan: @escaping @MainActor @Sendable (Workspace) async -> WorkspacePlan)
        async -> [(Workspace, WorkspacePlan)] {
        await withTaskGroup(of: (Int, WorkspacePlan).self) { group in
            for (index, workspace) in saved.enumerated() {
                group.addTask { (index, await plan(workspace)) }
            }
            var planned: [Int: WorkspacePlan] = [:]
            for await (index, plan) in group { planned[index] = plan }
            return saved.indices.compactMap { index in planned[index].map { (saved[index], $0) } }
        }
    }
}
