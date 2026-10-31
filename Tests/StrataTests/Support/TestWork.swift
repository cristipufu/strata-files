import Foundation
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

/// Blocking fixture tools use a dedicated queue so Process.waitUntilExit cannot pump a nested AppKit run loop
/// while another test is changing files. Errors return to the test's own task for Swift Testing to report.
nonisolated enum TestWork {
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let result = await TransferWorker(label: "strata.tests.fixture-work").run { Result { try body() } }
        return try result.get()
    }
}
