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

struct ProcessPipeSafetyTests {
    @Test func aClosedSFTPInputThrowsWithoutTerminatingTheApp() async throws {
        let tree = try TestTree()
        let gate = tree.url("gate"), ready = tree.url("ready")
        try #require(mkfifo(gate.path, 0o600) == 0)
        // Close stdin before announcing readiness. Keep stdout open behind a fixture FIFO so the test exercises
        // the failed write itself, independently of the SFTP reader noticing a process exit.
        let script = "exec 0<&-; printf ready > " + ShellQuote.quote(ready.path) + "; exec /bin/cat " + ShellQuote.quote(gate.path)
        let client = try SFTPClient(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], connect: false)
        defer { client.close() }
        // Fail a broken protection policy before deliberately writing to the closed pipe: mutation checks should
        // report an assertion failure, not kill the entire test process.
        try #require(client.suppressesBrokenPipeSignal)
        let deadline = ContinuousClock.now + .seconds(20)
        while !FileManager.default.fileExists(atPath: ready.path) {
            try #require(ContinuousClock.now < deadline, "The fixture did not close its input.")
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = await withCheckedContinuation { (done: CheckedContinuation<Result<Void, Error>, Never>) in
            DispatchQueue.global().async { done.resume(returning: Result { try client.connect() }) }
        }
        if case .success = result { Issue.record("A handshake unexpectedly wrote to a closed pipe.") }
        #expect(!client.isConnected)
        #expect(tree.text("ready") == "ready")
        #expect(tree.snapshot() == ["gate", "ready"])
    }

    @Test func shortOutputIsCollectedWhileItsWriterStaysOpen() throws {
        let collector = PipeCollector()
        let pipe = Pipe()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        try #require(flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0)
        try pipe.fileHandleForWriting.write(contentsOf: Data("output".utf8))
        // A nonblocking pipe makes a reader that waits for a full buffer fail deterministically,
        // instead of leaving a test hung until the writer closes.
        collector.receive(descriptor)
        #expect(collector.data == Data("output".utf8))
        #expect(collector.readError == nil)
        try pipe.fileHandleForWriting.close()
    }

    @Test func invalidOutputDescriptorsReportFailureInsteadOfRaisingAnException() {
        let collector = PipeCollector()
        // A recently closed descriptor could be reused by another suite. -1 always means EBADF.
        collector.receive(-1)
        #expect(collector.readError != nil)
        #expect(collector.data.isEmpty)
    }

    @Test func normalOutputAndEOFRemainDistinctFromReadFailure() throws {
        let collector = PipeCollector()
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("output".utf8))
        try pipe.fileHandleForWriting.close()
        collector.receive(pipe.fileHandleForReading.fileDescriptor)
        collector.receive(pipe.fileHandleForReading.fileDescriptor)
        #expect(collector.data == Data("output".utf8))
        #expect(collector.readError == nil)
    }
}
