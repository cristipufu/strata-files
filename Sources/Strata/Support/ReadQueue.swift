/// An owner's read requests: a bounded number start at once, and only that request's completion releases its slot.
package final class ReadQueue {
    private let limit: Int
    private var active: Set<Int> = []
    private var waiting: [Int: () -> Void] = [:]
    private var order: [Int] = []
    private var head = 0
    private var draining = false

    package init(limit: Int) { self.limit = max(1, limit) }

    package func enqueue(_ id: Int, start: @escaping () -> Void) {
        guard !active.contains(id), waiting[id] == nil else { return }
        waiting[id] = start
        order.append(id)
        drain()
    }

    package func cancel(_ id: Int) {
        waiting[id] = nil
        if order.count > max(64, waiting.count * 2) {
            order = order[head...].filter { waiting[$0] != nil }
            head = 0
        }
    }

    package func cancelWaiting() {
        waiting.removeAll()
        order.removeAll()
        head = 0
    }

    package func finish(_ id: Int) {
        guard active.remove(id) != nil else { return }
        drain()
    }

    private func drain() {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while active.count < limit, head < order.count {
            let id = order[head]
            head += 1
            guard let start = waiting.removeValue(forKey: id) else { continue }
            active.insert(id)
            start()
        }
        if head == order.count { order.removeAll(keepingCapacity: true); head = 0 }
    }
}
