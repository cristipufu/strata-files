import Foundation
import Testing
import os
@testable import StrataConnections

struct SFTPInputTests {
    private nonisolated final class HeldWrite: Sendable {
        let started = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let fails: Bool

        init(fails: Bool) { self.fails = fails }

        func write(_ bytes: Data) throws {
            let first = events.withLock { events in
                let first = events.isEmpty
                events.append(String(decoding: bytes, as: UTF8.self))
                return first
            }
            if first { started.signal(); resume.wait() }
            events.withLock { $0.append("finished") }
            if fails { throw POSIXError(.EPIPE) }
        }

        func close() { events.withLock { $0.append("closed") } }
    }

    @Test(arguments: [false, true])
    func disconnectReturnsWithoutClosingAnActiveWritesHandle(_ fails: Bool) async throws {
        let held = HeldWrite(fails: fails)
        let input = SFTPInput(write: held.write, close: held.close)
        defer { held.resume.signal(); input.close() }
        let writing = Task { try await TestWork.run { try input.write(Data("packet".utf8)) } }
        let started = try await TestWork.run { held.started.wait(timeout: .now() + 10) == .success }
        try #require(started, "The fixture write did not start.")

        input.close()
        input.close()
        #expect(held.events.withLock { $0 } == ["packet"])
        let queued = Task { try await TestWork.run { try input.write(Data("obsolete".utf8)) } }
        held.resume.signal()
        if fails {
            await #expect(throws: POSIXError(.EPIPE)) { try await writing.value }
        } else {
            try await writing.value
        }
        await #expect(throws: SFTPError.disconnected("")) { try await queued.value }
        input.close()
        #expect(held.events.withLock { $0 } == ["packet", "finished", "closed"])
    }

    @Test func aClosedInputNeverCallsItsHandleAgain() throws {
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let input = SFTPInput(write: { _ in events.withLock { $0.append("write") } },
                              close: { events.withLock { $0.append("close") } })
        try input.write(Data("packet".utf8))
        input.close()
        input.close()
        #expect(throws: SFTPError.disconnected("")) { try input.write(Data()) }
        #expect(events.withLock { $0 } == ["write", "close"])
    }

    @Test func releasingAnUnusedInputClosesItsHandleOnce() {
        let closes = OSAllocatedUnfairLock(initialState: 0)
        var input: SFTPInput? = SFTPInput(write: { _ in }, close: { closes.withLock { $0 += 1 } })
        withExtendedLifetime(input) { #expect(closes.withLock { $0 } == 0) }
        input = nil
        #expect(closes.withLock { $0 } == 1)
    }
}
