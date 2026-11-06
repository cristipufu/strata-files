import Foundation
import os
import StrataArchiveClient

private final class ReadWorkerBundle {}

nonisolated package enum ReadWorker {
    package enum Route: Equatable { case service(String), harness, missingService }
    private static let log = Logger(subsystem: "dev.strata.app", category: "read-workers")
    package static func route(for bundle: URL) -> Route {
        guard bundle.pathExtension == "app" else { return .harness }
        return ArchiveService.identifier(inApp: bundle).map(Route.service) ?? .missingService
    }
    package static let selectedRoute = route(for: Bundle(for: ReadWorkerBundle.self).bundleURL)
    package static let harnessApp: URL = {
        let bundle = Bundle(for: ReadWorkerBundle.self).bundleURL
        let products = bundle.pathExtension.isEmpty ? bundle : bundle.deletingLastPathComponent()
        return products.appending(path: "StrataArchiveHarness.app")
    }()
    package static let harness = harnessApp.appending(path: "Contents/MacOS/StrataArchiveHarness")

    package static func send(_ request: ArchiveService.Secret, file: FileHandle, timeout: TimeInterval,
                             outputLimit: Int = ArchiveService.outputLimit, worker: ArchiveService.Worker = .archive,
                             limits: ArchiveService.Limits = .init()) async throws -> (Data, ArchiveService.Status) {
        switch selectedRoute {
        case .service(let service):
            let reply = try await ArchiveService.send(encoded: request, limits: limits, to: service, archive: file,
                                                      timeout: timeout, outputLimit: outputLimit, worker: worker)
            if !reply.ended { log.error("The read service didn't confirm that its worker ended.") }
            return (reply.output, reply.outcome)
        case .harness:
            try requireHarness()
            guard let input = try ArchiveService.requestPipe(request) else { return (Data(), .limit) }
            defer { try? input.close() }
            var arguments = ["--timeout-ms", String(Int((timeout * 1000).rounded())), "--output-limit", String(outputLimit)]
            if worker == .table { arguments.append("--table") }
            if worker == .media { arguments.append("--media") }
            if let heap = limits.heap { arguments += ["--heap-limit", String(max(1, heap))] }
            if let memory = limits.memory { arguments += ["--memory-limit", String(max(1, memory))] }
            if let microseconds = limits.cpuMicroseconds {
                arguments += ["--cpu-limit", String(min(UInt64(Int.max), microseconds))]
            }
            let run = try await ProcessRunner.run(harness.path, arguments, timeout: timeout + ArchiveService.answerBackstop + 5,
                                                  standardInput: input, file: file)
            if run.failed { return (run.output, .unreadable) }
            let reply = ArchiveService.Reply(output: run.output, status: run.status, timedOut: run.timedOut,
                truncated: run.truncated || run.output.count > outputLimit)
            return (reply.output, reply.outcome)
        case .missingService:
            log.error("The app has no read service (Contents/XPCServices/StrataArchiveService.xpc).")
            return (Data(), .unreadable)
        }
    }

    package static func requireHarness() throws {
        guard FileManager.default.isExecutableFile(atPath: harness.path) else {
            log.error("Outside the app, reads require \(harness.path, privacy: .public).")
            throw CocoaError(.fileReadNoSuchFile)
        }
    }
}
