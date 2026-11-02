import Foundation

/// Whole packets share one writer. Closing never waits for a blocked write, and the write keeps its handle until
/// it returns: Foundation can raise an Objective-C exception if another thread closes that handle underneath it.
package nonisolated final class SFTPInput: @unchecked Sendable {
    private enum State { case open, writing, closing, closed }

    private let writeBytes: @Sendable (Data) throws -> Void
    private let closeHandle: @Sendable () -> Void
    private let writes = NSLock()
    private let lock = NSLock()
    private var state = State.open

    package init(write: @escaping @Sendable (Data) throws -> Void, close: @escaping @Sendable () -> Void) {
        writeBytes = write
        closeHandle = close
    }

    deinit { close() }

    package func write(_ bytes: Data) throws {
        try writes.withLock {
            let allowed = lock.withLock {
                guard state == .open else { return false }
                state = .writing
                return true
            }
            guard allowed else { throw SFTPError.disconnected("") }
            defer { finishWrite() }
            try writeBytes(bytes)
        }
    }

    package func close() {
        let closeNow = lock.withLock {
            switch state {
            case .open: state = .closed; return true
            case .writing: state = .closing; return false
            case .closing, .closed: return false
            }
        }
        if closeNow { closeHandle() }
    }

    private func finishWrite() {
        let closeNow = lock.withLock {
            switch state {
            case .writing: state = .open; return false
            case .closing: state = .closed; return true
            case .open, .closed: return false
            }
        }
        if closeNow { closeHandle() }
    }
}
