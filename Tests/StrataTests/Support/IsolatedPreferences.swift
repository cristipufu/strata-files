import Foundation
import Synchronization
import Testing
@testable import Strata

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

private nonisolated enum ThrowawaySuites {
    private static let inUse = Mutex<Set<String>>([])
    private static let prepareRun: Void = {
        removeFoldersOfEndedRuns()
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

    /// The system can write a suite's file back after its process exits, so a later run removes the folders of test
    /// processes that have ended; a run still going elsewhere keeps its own.
    private static func removeFoldersOfEndedRuns() {
        let runs = Prefs.testPreferencesFolder.deletingLastPathComponent()
        for folder in (try? FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil)) ?? [] {
            guard let process = pid_t(folder.lastPathComponent), process > 0,
                  kill(process, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
