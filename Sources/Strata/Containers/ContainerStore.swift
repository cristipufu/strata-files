import AppKit

extension Notification.Name {
    /// The container list or the engine changed.
    package static let containersChanged = Notification.Name("StrataContainersChanged")
}

/// The containers of the engine Strata found (see `EngineDiscovery`), kept current from the engine's events. When no
/// engine is running, it looks again now and then and whenever Strata comes to the front.
package final class ContainerStore {
    package static let shared = ContainerStore()

    package private(set) var engine: ContainerEngine?
    /// Running first, then by name.
    package private(set) var containers: [ContainerInfo] = []
    /// Containers being started, stopped…, by ID.
    package private(set) var busy: [String: ContainerAction] = [:]
    private var watcher: EventWatcher?
    private var discovering = false
    private var refreshing = false
    private var refreshAgain = false
    private var refreshScheduled = false
    private var retry: Timer?
    private var started = false

    package init(engine: ContainerEngine? = nil, containers: [ContainerInfo] = [], busy: [String: ContainerAction] = [:]) {
        self.engine = engine
        self.containers = containers
        self.busy = busy
    }

    package func start() {
        guard !started else { return }
        started = true
        discover()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    package func container(id: String) -> ContainerInfo? {
        containers.first { $0.id == id }
    }

    /// Does `action` to each container (those it applies to), a few at a time. Returns what failed: the container's
    /// name and why.
    package func perform(_ action: ContainerAction, on targets: [ContainerInfo]) async -> [(name: String, message: String)] {
        guard let engine else { return targets.map { ($0.name, String(localized: "No container engine is running.", comment: "Container action failed: no Docker Desktop, OrbStack…")) } }
        let targets = targets.filter { action.applies(to: $0.state) && busy[$0.id] == nil }
        guard !targets.isEmpty else { return [] }
        for target in targets { busy[target.id] = action }
        NotificationCenter.default.post(name: .containersChanged, object: self)
        var failures: [(name: String, message: String)] = []
        await withTaskGroup(of: (String, String)?.self) { group in
            // Four at a time: stopping waits up to 10 seconds each, and a hundred at once would hold everything up.
            var queue = targets[...]
            func next() {
                guard let target = queue.popFirst() else { return }
                group.addTask {
                    do {
                        try await blocking { try ContainerAPI.perform(action, engine, id: target.id) }
                        return nil
                    } catch {
                        return (target.name, Self.message(error, engine: engine))
                    }
                }
            }
            for _ in 0..<4 { next() }
            for await failure in group {
                if let failure { failures.append(failure) }
                next()
            }
        }
        for target in targets { busy[target.id] = nil }
        NotificationCenter.default.post(name: .containersChanged, object: self)
        refresh()
        return failures
    }

    nonisolated private static func message(_ error: Error, engine: ContainerEngine) -> String {
        switch error as? ContainerAPIError {
        case .transport(.connect)?: String(localized: "\(engine.name) isn’t running.", comment: "Container files: the engine (Docker Desktop, OrbStack…) can’t be reached")
        case .transport(.timeout)?: String(localized: "\(engine.name) didn’t answer in time.", comment: "Container files: the engine took too long")
        case .notFound?: String(localized: "It no longer exists.", comment: "Container action failed: the container was removed")
        case .status(_, let message)? where !message.isEmpty: message
        default: String(localized: "\(engine.name) refused it.", comment: "Container action failed without a reason; placeholder: Docker Desktop, OrbStack…")
        }
    }

    /// Fetches the list again (or looks for an engine when there's none).
    package func refresh() {
        guard let engine else { return discover() }
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        Task {
            let list = try? await blocking { try ContainerAPI.containers(engine) }
            refreshing = false
            guard engine == self.engine else { return }
            // The engine answers but can't list (starting up, or broken): try again later, not in a loop.
            guard let list else { return lost(retryIn: 5) }
            let sorted = list.sorted { a, b in
                a.isRunning != b.isRunning ? a.isRunning : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            if sorted != containers {
                containers = sorted
                NotificationCenter.default.post(name: .containersChanged, object: self)
            }
            if refreshAgain {
                refreshAgain = false
                refresh()
            }
        }
    }

    private func discover() {
        guard !discovering else { return }
        discovering = true
        Task {
            let found = try? await blocking { EngineDiscovery.discover() }
            discovering = false
            use(found ?? nil)
        }
    }

    private func use(_ found: ContainerEngine?) {
        if found != engine {
            watcher?.cancel()
            watcher = nil
            engine = found
            containers = []
            NotificationCenter.default.post(name: .containersChanged, object: self)
        }
        guard let found else { return scheduleDiscovery() }
        retry?.invalidate()
        retry = nil
        refresh()
        if watcher == nil {
            watcher = EventWatcher(found, changed: { [weak self] in self?.scheduleRefresh() },
                                   ended: { [weak self] in self?.eventsEnded(found) })
        }
    }

    /// Events come in bursts (a compose project starting): one refresh for each burst.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    /// The event stream closed: the engine quit or restarted, or doesn't keep a stream open. If it still answers, watch
    /// again in a while (never in a tight loop); otherwise it's gone.
    private func eventsEnded(_ ended: ContainerEngine) {
        guard ended == engine else { return }
        watcher = nil
        Task { [weak self] in
            guard let self else { return }
            let alive = (try? await blocking { try ContainerAPI.containers(ended) }) != nil
            guard ended == engine else { return }
            guard alive else { return lost(retryIn: 5) }
            refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.engine == ended, self.watcher == nil else { return }
                    self.watcher = EventWatcher(ended, changed: { [weak self] in self?.scheduleRefresh() },
                                                ended: { [weak self] in self?.eventsEnded(ended) })
                }
            }
        }
    }

    /// The engine stopped answering: forget it (the sidebar's Containers goes too) and look again after `retryIn`
    /// seconds, then every minute.
    private func lost(retryIn delay: TimeInterval = 2) {
        watcher?.cancel()
        watcher = nil
        engine = nil
        containers = []
        NotificationCenter.default.post(name: .containersChanged, object: self)
        scheduleDiscovery()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                if self?.engine == nil { self?.discover() }
            }
        }
    }

    /// No engine yet: look again in a while (also whenever Strata comes to the front).
    private func scheduleDiscovery() {
        guard retry == nil else { return }
        retry = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.discover() }
        }
    }
}

/// Follows an engine's event stream on its own thread (it can stay quiet for hours).
package nonisolated final class EventWatcher: Sendable {
    private let stop = StopFlag()

    package init(_ engine: ContainerEngine, changed: @escaping @MainActor @Sendable () -> Void, ended: @escaping @MainActor @Sendable () -> Void) {
        let stop = self.stop
        Thread.detachNewThread {
            try? ContainerAPI.watchEvents(engine, shouldStop: { stop.isSet }) {
                DispatchQueue.main.async { MainActor.assumeIsolated { changed() } }
            }
            if !stop.isSet { DispatchQueue.main.async { MainActor.assumeIsolated { ended() } } }
        }
    }

    package func cancel() {
        stop.set()
    }
}
