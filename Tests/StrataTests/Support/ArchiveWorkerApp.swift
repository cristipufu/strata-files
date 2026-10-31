import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

/// Archives are read by workers of the archive service, an XPC service with an App Sandbox of its own, which only an
/// app can carry. Suites and tests that read archives get `StrataArchiveHarness.app` assembled around the built service
/// and worker once per test process, signed as scripts/build.sh signs the app's.
nonisolated struct ArchiveWorkerApp: SuiteTrait, TestTrait, TestScoping {
    struct AssemblyFailed: Error { let status: Int32 }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        try await Self.assembled.value
        try await function()
    }

    private static let assembled = Task {
        try await assemble(PreviewArchiveReader.harnessApp)
    }

    private static let checkout = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let sources = checkout.appending(path: "Sources")
    private static let scripts = checkout.appending(path: "scripts")
    static let serviceEntitlements = sources.appending(path: "StrataArchiveService/ArchiveService.entitlements")
    static let workerEntitlements = sources.appending(path: "StrataArchiveWorker/ArchiveWorker.entitlements")

    /// Builds the host app at `app` around the built harness, with the service and worker laid out and signed by
    /// scripts/archive-service.sh as the app's build does, each with exactly the given entitlements (none: without its
    /// sandbox), and bundle identifiers ending in `name` so that apps assembled for different tests never share them.
    /// A new app each time: macOS remembers a binary's signature per file.
    static func assemble(_ app: URL, named name: String = "", service serviceEntitlements: URL? = serviceEntitlements,
                         worker workerEntitlements: URL? = workerEntitlements) async throws {
        let products = PreviewArchiveReader.harnessApp.deletingLastPathComponent()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async { done.resume(with: Result { try lay(app, named: name, from: products) }) }
        }
        let signing = ["--force", "--options", "runtime", "--sign", "-"]
        try await run("/bin/bash", [scripts.appending(path: "archive-service.sh").path, app.path, products.path,
                                    "--identifier", "dev.strata.tests.ArchiveService\(name)",
                                    "--service-entitlements", serviceEntitlements?.path ?? "",
                                    "--worker-entitlements", workerEntitlements?.path ?? "", "--"] + signing)
        try await run("/usr/bin/codesign", signing + [app.path])
    }

    /// The host's own part of the app, unsigned.
    private static func lay(_ app: URL, named name: String, from products: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: app.path) { try files.removeItem(at: app) }
        try files.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try files.copyItem(at: products.appending(path: "StrataArchiveHarness"),
                           to: app.appending(path: "Contents/MacOS/StrataArchiveHarness"))
        let info: [String: Any] = ["CFBundleIdentifier": "dev.strata.tests.ArchiveHarness\(name)",
                                   "CFBundleExecutable": "StrataArchiveHarness", "CFBundlePackageType": "APPL",
                                   "CFBundleInfoDictionaryVersion": "6.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        let run = try await ProcessRunner.run(tool, arguments, timeout: 120)
        guard !run.timedOut, run.status == 0 else { throw AssemblyFailed(status: run.status) }
    }
}

extension Trait where Self == ArchiveWorkerApp {
    static var archiveWorkerApp: Self { Self() }
}
