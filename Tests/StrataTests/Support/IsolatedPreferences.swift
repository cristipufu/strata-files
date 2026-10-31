import Foundation
import Synchronization
import Testing
@testable import Strata
@testable import StrataFiles

extension Prefs {
    /// Preferences in a suite of their own, with their own notification center. The suite is removed when the last
    /// object using it is released, or when the test process exits, so it can't disappear while a test still reads it.
    static func isolated() throws -> Prefs {
        let defaults = try #require(ThrowawayDefaults.make())
        return Prefs(defaults: defaults, domainName: defaults.domain)
    }
}

/// For a test that needs a suite before any `Prefs` exists; others use `Prefs.isolated()`.
nonisolated final class ThrowawayDefaults: UserDefaults {
    let domain: String

    static func make() -> ThrowawayDefaults? {
        ThrowawayDefaults(domain: Prefs.testPreferencesFolder.appending(path: "StrataTests.\(UUID().uuidString)").path)
    }

    private init?(domain: String) {
        self.domain = domain
        super.init(suiteName: domain)
        ThrowawaySuites.track(domain)
    }

    deinit { ThrowawaySuites.remove(domain) }
}

nonisolated enum ThrowawaySuites {
    private static let inUse = Mutex<Set<String>>([])
    private static let prepareRun: Void = {
        markThisRun()
        removeFoldersOfEndedRuns(in: Prefs.testPreferencesFolder.deletingLastPathComponent())
        atexit { ThrowawaySuites.removeAll() }
    }()

    static func track(_ domain: String) {
        prepareRun
        inUse.withLock { _ = $0.insert(domain) }
    }

    static func remove(_ domain: String) {
        guard inUse.withLock({ $0.remove(domain) }) != nil else { return }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        // Emptying a suite leaves its file behind.
        try? FileManager.default.removeItem(atPath: domain + ".plist")
    }

    private static func removeAll() {
        for domain in inUse.withLock({ $0 }) { remove(domain) }
    }

    /// This run's folder names its process, so a later run can tell it has ended even once its number is given again.
    private static func markThisRun() {
        let folder = Prefs.testPreferencesFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? RunOwner.current?.marker.write(to: folder.appending(path: RunOwner.file))
    }

    /// The system can write a suite's file back after its process exits, so a later run removes the folders of test
    /// processes that have ended; a run still going elsewhere keeps its own.
    static func removeFoldersOfEndedRuns(in runs: URL) {
        for folder in (try? FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil)) ?? []
        where hasEnded(folder) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Whether the run a folder belongs to has ended: as its marker names it, or, for a folder made before runs marked
    /// theirs, as its name does, by number alone. One that can't be told about counts as running.
    private static func hasEnded(_ folder: URL) -> Bool {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        do {
            if let owner = try RunOwner(markerIn: fd) { return !owner.isRunning }
        } catch {
            return false
        }
        guard let process = pid_t(folder.lastPathComponent), process > 0 else { return false }
        return kill(process, 0) != 0 && errno == ESRCH
    }
}
