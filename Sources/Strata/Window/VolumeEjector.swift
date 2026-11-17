import AppKit

extension Notification.Name {
    /// A disk started or finished ejecting; the object is the `VolumeEjector`.
    static let volumeEjectionsChanged = Notification.Name("StrataVolumeEjectionsChanged")
    /// A disk was ejected; the object is the `VolumeEjector`, and `VolumeEjector.volumeKey` holds the disk's URL.
    static let volumeEjected = Notification.Name("StrataVolumeEjected")
}

/// Ejects disks for one environment's windows: the sidebar's eject buttons and menus in both modes, and File ▸ Eject.
/// Only a disk the latest `PlaceChecks` read lists as ejectable is handed to macOS, and only once until it answers.
@MainActor final class VolumeEjector {
    typealias Unmount = @Sendable (URL) async throws -> Void
    typealias Report = @MainActor (Failure, NSWindow?) -> Void

    struct Failure {
        let volume: URL
        let name: String
        let error: any Error
    }

    nonisolated static let volumeKey = "volume"

    private let places: PlaceChecks
    private let unmount: Unmount
    private let report: Report
    /// The ejections under way, by `key`.
    private(set) var tasks: [String: Task<Void, Never>] = [:]

    init(places: PlaceChecks, unmount: @escaping Unmount, report: @escaping Report) {
        self.places = places
        self.unmount = unmount
        self.report = report
    }

    func isEjecting(_ volume: URL) -> Bool { tasks[Self.key(volume)] != nil }

    /// The ones of `urls` that can be ejected now.
    func ejectable(_ urls: [URL]) -> [URL] {
        let volumes = places.snapshot.volumes
        guard volumes.contains(where: \.isEjectable) else { return [] }
        let underway = Set(tasks.keys)
        return urls.filter { Self.volume($0, among: volumes, underway: underway) != nil }
    }

    /// Hands the disk at `volume` to macOS, unless it can't be ejected now. A failure is reported in `window`.
    @discardableResult
    func eject(_ volume: URL, from window: NSWindow?) -> Task<Void, Never>? {
        guard let place = Self.volume(volume, among: places.snapshot.volumes, underway: Set(tasks.keys)) else { return nil }
        let key = Self.key(place.url)
        let unmount = unmount
        let task = Task { [weak self, weak window] in
            let failure: (any Error)?
            do {
                try await unmount(place.url)
                failure = nil
            } catch {
                failure = error
            }
            self?.finish(place, key: key, failure: failure, window: window)
        }
        tasks[key] = task
        NotificationCenter.default.post(name: .volumeEjectionsChanged, object: self)
        return task
    }

    private func finish(_ place: Place, key: String, failure: (any Error)?, window: NSWindow?) {
        tasks[key] = nil
        NotificationCenter.default.post(name: .volumeEjectionsChanged, object: self)
        if let failure {
            report(Failure(volume: place.url, name: place.title, error: failure), window)
            return
        }
        NotificationCenter.default.post(name: .volumeEjected, object: self, userInfo: [Self.volumeKey: place.url])
        // Until the next read, the sidebar still lists the disk: read now rather than wait for macOS's notice.
        places.refresh()
    }

    /// The disk `url` names when it can be ejected now: the root of one the latest read lists as ejectable, never the
    /// startup disk, and not one being ejected already.
    nonisolated static func volume(_ url: URL, among volumes: [Place], underway: Set<String>) -> Place? {
        guard url.isFileURL else { return nil }
        let wanted = key(url)
        guard wanted != "/", !underway.contains(wanted) else { return nil }
        return volumes.first { $0.isEjectable && key($0.url) == wanted }
    }

    /// Whether `location` is the disk at `volume` or inside it, matched by whole path components.
    nonisolated static func isOnVolume(_ location: URL, _ volume: URL) -> Bool {
        let root = key(volume), path = key(location)
        return root != "/" && (path == root || path.hasPrefix(root + "/"))
    }

    nonisolated static func key(_ url: URL) -> String { PathSpelling.short(url) }

    /// A disk that stopped answering holds only a thread of its own.
    nonisolated static func unmountAndEject(_ volume: URL) async throws {
        try await OwnThread.run { Result { try NSWorkspace.shared.unmountAndEjectDevice(at: volume) } }.get()
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
        alert.informativeText = String(localized: "Close any files from it that are open in other apps, then try again. (\(failure.error.localizedDescription))")
        return alert
    }
}
