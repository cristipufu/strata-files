import AppKit
import Synchronization

extension Notification.Name {
    /// A disk started or finished ejecting; the object is the `VolumeEjector`.
    static let volumeEjectionsChanged = Notification.Name("StrataVolumeEjectionsChanged")
    /// A disk is about to be handed to macOS: what shows it lets go first. The object is the `VolumeEjector`, and
    /// `VolumeEjector.volumeKey` holds the disk's URL, as for the two below.
    static let volumeEjectionStarting = Notification.Name("StrataVolumeEjectionStarting")
    static let volumeEjectionFailed = Notification.Name("StrataVolumeEjectionFailed")
    static let volumeEjected = Notification.Name("StrataVolumeEjected")
}

/// Ejects disks for one environment's windows: the sidebar's eject buttons and menus in both modes, and File ▸ Eject.
/// Only a disk the latest `PlaceChecks` read lists as ejectable is handed to macOS, and only once until it answers.
@MainActor final class VolumeEjector {
    typealias Unmount = @Sendable (URL) async throws -> Void
    typealias Patience = @Sendable () async -> Void
    typealias Report = @MainActor (Failure, NSWindow?) -> Void

    struct Failure {
        let volume: URL
        let name: String
        let error: any Error
    }

    nonisolated struct NoAnswer: Error {}

    nonisolated enum Outcome: Sendable {
        case ejected
        case failed(any Error)
    }

    nonisolated static let volumeKey = "volume"

    private let places: PlaceChecks
    private let unmount: Unmount
    private let patience: Patience
    private let report: Report
    private(set) var tasks: [String: Task<Void, Never>] = [:]
    /// Disks ejected that the places read may still list, until a read begun since has landed.
    private var gone: Set<String> = []

    init(places: PlaceChecks, unmount: @escaping Unmount, patience: @escaping Patience, report: @escaping Report) {
        self.places = places
        self.unmount = unmount
        self.patience = patience
        self.report = report
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
        post(.volumeEjectionStarting, place)
        let unmount = unmount, patience = patience, report = report
        let task = Task { [weak self, weak window] in
            let outcome = await VolumeEjector.outcome(of: unmount, place.url, patience: patience)
            self?.finish(place, key: key, outcome: outcome)
            if case .failed(let error) = outcome {
                report(Failure(volume: place.url, name: place.title, error: error), window)
            }
        }
        tasks[key] = task
        NotificationCenter.default.post(name: .volumeEjectionsChanged, object: self)
        return task
    }

    private func finish(_ place: Place, key: String, outcome: Outcome) {
        tasks[key] = nil
        switch outcome {
        case .ejected:
            gone.insert(key)
            post(.volumeEjected, place)
            forgetOnceRead(key)
        case .failed:
            post(.volumeEjectionFailed, place)
        }
        NotificationCenter.default.post(name: .volumeEjectionsChanged, object: self)
    }

    private func forgetOnceRead(_ key: String) {
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

    /// macOS's answer, or `NoAnswer` once `patience` runs out first. A disk that stopped answering keeps its thread.
    nonisolated static func outcome(of unmount: @escaping Unmount, _ volume: URL, patience: @escaping Patience) async -> Outcome {
        let waiting = Mutex<CheckedContinuation<Outcome, Never>?>(nil)
        return await withCheckedContinuation { continuation in
            waiting.withLock { $0 = continuation }
            let deadline = Task { @Sendable in
                await patience()
                waiting.withLock { $0.take() }?.resume(returning: .failed(NoAnswer()))
            }
            Task { @Sendable in
                let outcome: Outcome
                do {
                    try await unmount(volume)
                    outcome = .ejected
                } catch {
                    outcome = .failed(error)
                }
                deadline.cancel()
                waiting.withLock { $0.take() }?.resume(returning: outcome)
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
    private var waiting: [ObjectIdentifier: [VolumeEjector.Failure]] = [:]

    func present(_ failure: VolumeEjector.Failure, in window: NSWindow?) {
        guard let window, FileAlerts.canStillAsk(in: window) else {
            _ = Self.alert(for: failure).runModal()
            return
        }
        let id = ObjectIdentifier(window)
        guard waiting[id] == nil else {
            waiting[id]?.append(failure)
            return
        }
        waiting[id] = []
        show(failure, in: window)
    }

    private func show(_ failure: VolumeEjector.Failure, in window: NSWindow) {
        let id = ObjectIdentifier(window)
        FileAlerts.present(Self.alert(for: failure), in: window) { [weak self, weak window] _ in
            guard let self else { return }
            guard let next = waiting[id]?.first else {
                waiting[id] = nil
                return
            }
            guard let window else {
                let unseen = waiting.removeValue(forKey: id) ?? []
                unseen.forEach { present($0, in: nil) }
                return
            }
            waiting[id]?.removeFirst()
            show(next, in: window)
        }
    }

    private static func alert(for failure: VolumeEjector.Failure) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(failure.name)” couldn’t be ejected")
        alert.informativeText = failure.error is VolumeEjector.NoAnswer
            ? String(localized: "\(failure.name) didn’t answer in time.")
            : String(localized: "Close any files from it that are open in other apps, then try again. (\(failure.error.localizedDescription))")
        return alert
    }
}
