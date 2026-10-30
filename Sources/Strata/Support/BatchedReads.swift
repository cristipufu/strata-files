import Foundation

/// Reads asked for while views draw, made together away from the main thread and handed to `arrived` on it. A path
/// being read isn't read again meanwhile, and each batch runs on a thread of its own (`OwnThread`): one that hangs on
/// a server that stopped answering holds up only the paths it has, and no other work.
package final class BatchedReads<Value: Sendable> {
    private let read: @Sendable ([String]) -> [String: Value]
    private let arrived: ([String: Value]) -> Void
    private var waiting: [String] = []
    private var reading: Set<String> = []
    private var collecting: Task<Void, Never>?
    private var batches: [UUID: Task<Void, Never>] = [:]

    package init(read: @escaping @Sendable ([String]) -> [String: Value],
                 arrived: @escaping ([String: Value]) -> Void) {
        self.read = read
        self.arrived = arrived
    }

    /// Asks for `path`'s value, once while it's being read: with the others asked for until this run of drawing ends.
    package func request(_ path: String) {
        guard reading.insert(path).inserted else { return }
        waiting.append(path)
        guard collecting == nil else { return }
        collecting = Task { [weak self] in
            await Task.yield()
            self?.readWaiting()
        }
    }

    /// Waits for every read asked for so far.
    package func settled() async {
        while true {
            if let collecting {
                await collecting.value
            } else if let batch = batches.values.first {
                await batch.value
            } else {
                return
            }
        }
    }

    private func readWaiting() {
        collecting = nil
        let paths = waiting, id = UUID(), read = read
        waiting.removeAll()
        batches[id] = Task { [weak self] in
            let values = await OwnThread.run { read(paths) }
            guard let self else { return }
            batches[id] = nil
            reading.subtract(paths)
            arrived(values)
        }
    }
}
