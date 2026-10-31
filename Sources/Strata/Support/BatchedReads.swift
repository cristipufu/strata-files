import Foundation

/// Reads asked for while views draw, made together away from the main thread and handed to `arrived` on it. A path
/// being read isn't read again meanwhile. Each disk (`DiskOfPath`) has one batch at a time, on a thread of its own
/// (`OwnThread`): one that hangs on a server that stopped answering holds up only that server's paths, and the threads
/// stay as few as the disks.
package final class BatchedReads<Value: Sendable> {
    private let read: @Sendable ([String]) -> [String: Value]
    private let arrived: ([String: Value]) -> Void
    private var waiting: [String: [String]] = [:]
    private var reading: Set<String> = []
    /// Asked for and in a batch that has begun (the rest of `reading` waits for one).
    private var underWay: Set<String> = []
    private var collecting: Task<Void, Never>?
    private var batches: [String: Task<Void, Never>] = [:]

    package init(read: @escaping @Sendable ([String]) -> [String: Value],
                 arrived: @escaping ([String: Value]) -> Void) {
        self.read = read
        self.arrived = arrived
    }

    /// Asks for `path`'s value, once while it's being read: with the others asked for until this run of drawing ends.
    package func request(_ path: String) {
        guard reading.insert(path).inserted else { return }
        waiting[DiskOfPath.of(path), default: []].append(path)
        guard collecting == nil else { return }
        collecting = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            collecting = nil
            for disk in waiting.keys where batches[disk] == nil { readWaiting(on: disk) }
        }
    }

    /// Whether `path`'s read has begun: a change since may not be in what it brings.
    package func isUnderWay(_ path: String) -> Bool { underWay.contains(path) }

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

    private func readWaiting(on disk: String) {
        guard let paths = waiting.removeValue(forKey: disk) else { return }
        underWay.formUnion(paths)
        let read = read
        batches[disk] = Task { [weak self] in
            let values = await OwnThread.run { read(paths) }
            guard let self else { return }
            batches[disk] = nil
            reading.subtract(paths)
            underWay.subtract(paths)
            arrived(values)
            readWaiting(on: disk)
        }
    }
}
