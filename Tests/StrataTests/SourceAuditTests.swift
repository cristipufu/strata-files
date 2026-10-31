import Foundation
import Testing

/// The source audits CI runs, run by `swift test` as well.
struct SourceAuditTests {
    @Test func directSurfaceColorsHaveAReviewedReason() async throws {
        let (status, output) = try await run("scripts/audit-theme-colors.py")
        #expect(status == 0, Comment(rawValue: output))
    }

    @Test func blockingCallsOnTheMainThreadHaveAReviewedReason() async throws {
        let (status, output) = try await run("scripts/audit-main-thread.py")
        #expect(status == 0, Comment(rawValue: output))
    }

    @Test func theModelNamesNothingFromTheInterface() async throws {
        let (status, output) = try await run("scripts/audit-layers.py")
        #expect(status == 0, Comment(rawValue: output))
    }

    @Test func appWideInstancesOutsideTheApplicationsOwnCodeHaveAReviewedReason() async throws {
        let (status, output) = try await run("scripts/audit-app-wide.py")
        #expect(status == 0, Comment(rawValue: output))
    }

    private func run(_ script: String) async throws -> (Int32, String) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try await withCheckedThrowingContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = ["python3", root.appending(path: script).path]
                    process.currentDirectoryURL = root
                    process.standardInput = FileHandle.nullDevice
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    done.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
                } catch { done.resume(throwing: error) }
            }
        }
    }
}
