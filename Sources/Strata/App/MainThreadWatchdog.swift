#if DEBUG
import Foundation
import os

/// Debug builds only: logs each time the main thread takes longer than a tenth of a second to answer, and for how
/// long, so a change that blocks it shows up while you try it (`log stream --predicate 'category == "stalls"'`;
/// Instruments' Hangs shows where).
nonisolated enum MainThreadWatchdog {
    private static let logger = Logger(subsystem: "dev.strata", category: "stalls")

    static func start() {
        let thread = Thread {
            while true {
                let asked = ContinuousClock.now
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
                    answered.wait()
                    let stalled = (ContinuousClock.now - asked).components
                    let milliseconds = stalled.seconds * 1000 + stalled.attoseconds / 1_000_000_000_000_000
                    logger.warning("The main thread stalled for \(milliseconds, privacy: .public) ms")
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        thread.name = "Strata main-thread watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }
}
#endif
