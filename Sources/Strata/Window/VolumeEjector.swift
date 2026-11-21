import AppKit
import Synchronization

extension Notification.Name {
    /// A disk started or finished ejecting; the object is the `VolumeEjector`.
    static let volumeEjectionsChanged = Notification.Name("StrataVolumeEjectionsChanged")
    /// A disk is about to be handed to macOS: what shows it lets go first. The object is the `VolumeEjector`, and
    /// `VolumeEjector.volumeKey` holds the disk's URL, as for the one below.
    static let volumeEjectionStarting = Notification.Name("StrataVolumeEjectionStarting")
    static let volumeEjected = Notification.Name("StrataVolumeEjected")
}

/// Ejects disks for one environment's windows: the sidebar's eject buttons and menus in both modes, and File ▸ Eject.
/// Only a disk the latest `PlaceChecks` read lists as ejectable is handed to macOS, and only once until it answers, even
/// after it was reported as not answering: a second call would only block another thread on the same disk.
@MainActor final class VolumeEjector {
    typealias Unmount = @Sendable (URL) async throws -> Void
    typealias Patience = @Sendable () async -> Void
    typealias Report = @MainActor (Failure, NSWindow?) -> Void

    struct Failure {
        let name: String
        let error: any Error
    }

    nonisolated struct NoAnswer: Error {}

    nonisolated static let volumeKey = "volume"

    private let places: PlaceChecks
    private let workspace: NotificationCenter
    private let unmount: Unmount
    private let patience: Patience
    private let report: Report
    private(set) var tasks: [String: Task<Void, Never>] = [:]
    /// Disks ejected or unmounted that the places read may still list, until a read begun since has landed.
    private var gone: Set<String> = []

    init(places: PlaceChecks, workspace: NotificationCenter, unmount: @escaping Unmount, patience: @escaping Patience,
         report: @escaping Report) {
        self.places = places
        self.workspace = workspace
        self.unmount = unmount
        self.patience = patience
        self.report = report
        // Unmounted elsewhere, or taken along with a disk ejected here: offering it again would only fail.
        for name in [NSWorkspace.willUnmountNotification, NSWorkspace.didUnmountNotification] {
            workspace.addObserver(self, selector: #selector(unmounted(_:)), name: name, object: nil)
        }
    }

    isolated deinit { workspace.removeObserver(self) }

    @objc private func unmounted(_ notification: Notification) {
        guard let volume = Self.unmounting(notification) else { return }
        markGone(Self.key(volume))
    }

    /// The disk a will- or didUnmount notice names: a willUnmount notice may give only its path.
    static func unmounting(_ notice: Notification) -> URL? {
        if let url = notice.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL { return url }
        return (notice.userInfo?["NSDevicePath"] as? String).map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    private var refused: Set<String> { gone.union(tasks.keys) }

    func isEjecting(_ volume: URL) -> Bool { refused.contains(Self.key(volume)) }

    func ejectable(_ urls: [URL]) -> [URL] {
        let disks = Self.ejectable(places.snapshot.volumes, except: refused)
        guard !disks.isEmpty else { return [] }
        return urls.filter { Self.volume($0, in: disks) != nil }
    }

    /// Hands the disk at `volume` to macOS, unless it can't be ejected now. A failure is reported in `window`.
    @discardableResult
    func eject(_ volume: URL, from window: NSWindow?) -> Task<Void, Never>? {
        guard let place = Self.volume(volume, in: Self.ejectable(places.snapshot.volumes, except: refused)) else { return nil }
        let key = Self.key(place.url)
        let unmount = unmount, patience = patience, report = report, url = place.url
        let task = Task { [weak self, weak window] in
            let answer = Task.detached { await VolumeEjector.answer(of: unmount, url) }
            let timely = await VolumeEjector.outcome(of: answer, patience: patience)
            if case .failure(let error) = timely, error is NoAnswer {
                report(Failure(name: place.title, error: error), window)
                let late = await answer.value
                self?.finish(place, key: key, outcome: late)
            } else {
                self?.finish(place, key: key, outcome: timely)
                if case .failure(let error) = timely { report(Failure(name: place.title, error: error), window) }
            }
        }
        tasks[key] = task
        post(.volumeEjectionStarting, place)
        NotificationCenter.default.post(name: .volumeEjectionsChanged, object: self)
        return task
    }

    private func finish(_ place: Place, key: String, outcome: Result<Void, any Error>) {
        tasks[key] = nil
        if case .success = outcome {
            post(.volumeEjected, place)
            markGone(key)
        }
        NotificationCenter.default.post(name: .volumeEjectionsChanged, object: self)
    }

    private func markGone(_ key: String) {
        guard gone.insert(key).inserted else { return }
        NotificationCenter.default.post(name: .volumeEjectionsChanged, object: self)
        let places = places
        places.refresh()
        Task { [weak self] in
            while let read = places.task { await read.value }
            guard let self, gone.remove(key) != nil else { return }
            NotificationCenter.default.post(name: .volumeEjectionsChanged, object: self)
        }
    }

    private func post(_ name: Notification.Name, _ place: Place) {
        NotificationCenter.default.post(name: name, object: self, userInfo: [Self.volumeKey: place.url])
    }

    /// The disks that may be ejected now, by `key`: those the read lists as ejectable, never the startup disk, and
    /// none of `refused`.
    nonisolated static func ejectable(_ volumes: [Place], except refused: Set<String>) -> [String: Place] {
        var disks: [String: Place] = [:]
        for volume in volumes where volume.isEjectable {
            let id = key(volume.url)
            if id != "/", !refused.contains(id), disks[id] == nil { disks[id] = volume }
        }
        return disks
    }

    /// The disk whose root `url` is, among `disks`.
    nonisolated static func volume(_ url: URL, in disks: [String: Place]) -> Place? {
        url.isFileURL ? disks[key(url)] : nil
    }

    /// Whether `location` is the disk at `volume` or inside it, matched by whole path components.
    nonisolated static func isOnVolume(_ location: URL, _ volume: URL) -> Bool {
        let root = key(volume), path = key(location)
        return root != "/" && (path == root || path.hasPrefix(root + "/"))
    }

    nonisolated static func key(_ url: URL) -> String { PathSpelling.short(url) }

    nonisolated static func answer(of unmount: Unmount, _ volume: URL) async -> Result<Void, any Error> {
        do {
            try await unmount(volume)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// `answer`, or `NoAnswer` once `patience` runs out first. A disk that stopped answering keeps its thread.
    nonisolated static func outcome(of answer: Task<Result<Void, any Error>, Never>,
                                    patience: @escaping Patience) async -> Result<Void, any Error> {
        let waiting = Mutex<CheckedContinuation<Result<Void, any Error>, Never>?>(nil)
        return await withCheckedContinuation { continuation in
            waiting.withLock { $0 = continuation }
            let deadline = Task { @Sendable in
                await patience()
                guard !Task.isCancelled else { return }
                waiting.withLock { $0.take() }?.resume(returning: .failure(NoAnswer()))
            }
            Task { @Sendable in
                let result = await answer.value
                waiting.withLock { $0.take() }?.resume(returning: result)
                deadline.cancel()
            }
        }
    }

    nonisolated static func unmountAndEject(_ volume: URL) async throws {
        try await OwnThread.run { Result { try NSWorkspace.shared.unmountAndEjectDevice(at: volume) } }.get()
    }

    /// Long enough for a busy disk to finish writing; a share that stopped answering can hold on for minutes.
    nonisolated static func waitBeforeGivingUp() async {
        try? await Task.sleep(for: .seconds(30))
    }

    /// For environments of their own: no disk is ever handed to macOS.
    nonisolated static func refuseToUnmount(_ volume: URL) async throws {
        throw CocoaError(.featureUnsupported)
    }
}

/// An eject failure is always shown, since a disk still mounted mustn't look ejected: as a sheet on the window that
/// asked, one at a time there (a window takes one sheet), else as a dialog once that window has closed.
@MainActor final class EjectFailureAlerts {
    typealias Sheet = @MainActor (NSAlert, NSWindow, @escaping () -> Void) -> Void
    typealias Dialog = @MainActor (NSAlert) -> Void

    private struct Queue {
        weak var window: NSWindow?
        var failures: [VolumeEjector.Failure]
    }

    private let sheet: Sheet
    private let dialog: Dialog
    private let canAsk: @MainActor (NSWindow) -> Bool
    private var queues: [ObjectIdentifier: Queue] = [:]

    init(sheet: @escaping Sheet = { alert, window, done in FileAlerts.present(alert, in: window) { _ in done() } },
         dialog: @escaping Dialog = { _ = $0.runModal() },
         canAsk: @escaping @MainActor (NSWindow) -> Bool = { FileAlerts.canStillAsk(in: $0) }) {
        self.sheet = sheet
        self.dialog = dialog
        self.canAsk = canAsk
    }

    func present(_ failure: VolumeEjector.Failure, in window: NSWindow?) {
        guard let window, canAsk(window) else { return dialog(Self.alert(for: failure)) }
        let id = ObjectIdentifier(window)
        // Another window that once had this identity may have gone without its sheet ending.
        if queues[id]?.window === window {
            queues[id]?.failures.append(failure)
            return
        }
        show(failure, in: window)
    }

    private func show(_ failure: VolumeEjector.Failure, in window: NSWindow, then later: [VolumeEjector.Failure] = []) {
        let id = ObjectIdentifier(window)
        queues[id] = Queue(window: window, failures: later)
        sheet(Self.alert(for: failure), window) { [weak self, weak window] in
            guard let self else { return }
            let waiting = queues.removeValue(forKey: id)?.failures ?? []
            guard let next = waiting.first else { return }
            guard let window, canAsk(window) else { return waiting.forEach { dialog(Self.alert(for: $0)) } }
            show(next, in: window, then: Array(waiting.dropFirst()))
        }
    }

    private static func alert(for failure: VolumeEjector.Failure) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(failure.name)” couldn’t be ejected")
        alert.informativeText = failure.error is VolumeEjector.NoAnswer
            ? String(localized: "“\(failure.name)” didn’t answer in time.", comment: "Eject failed: macOS got no answer from the disk or share in time; the disk's name")
            : String(localized: "Close any files from it that are open in other apps, then try again. (\(failure.error.localizedDescription))")
        return alert
    }
}
