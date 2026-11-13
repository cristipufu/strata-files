import CoreServices
import Foundation

/// File-level changes and directory recovery events, delivered on a private serial queue in batches.
nonisolated package final class FSEventsStream: @unchecked Sendable {
    package struct Event: Sendable {
        package let path: String
        package let flags: FSEventStreamEventFlags
        package let id: FSEventStreamEventId

        package init(path: String, flags: FSEventStreamEventFlags, id: FSEventStreamEventId) {
            self.path = path
            self.flags = flags
            self.id = id
        }

        /// Changes under `path` weren't itemized (too many, or events were dropped): re-check the whole subtree.
        package var mustScanSubdirectories: Bool {
            let flags = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagUserDropped
            return self.flags & FSEventStreamEventFlags(flags) != 0
        }

        /// The journal can't be trusted any more (a watched root moved, or event ids wrapped): rebuild.
        package var invalidatesIndex: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped) != 0
        }

        /// Events were dropped by the kernel or `fseventsd`: what was delivered is not everything that changed.
        package var droppedEvents: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagUserDropped) != 0
        }

        /// The kernel dropped the events before `fseventsd` saw them, so they are in no journal either.
        package var droppedByKernel: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0
        }

        package var isHistoryDone: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0
        }
    }

    private final class CallbackContext: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable ([Event]) -> Void)?

        init(_ handler: (@Sendable ([Event]) -> Void)?) { self.handler = handler }

        func emit(_ events: [Event]) {
            let current = lock.withLock { handler }
            current?(events)
        }

        func clear() { lock.withLock { handler = nil } }
    }

    private var stream: FSEventStreamRef?
    private var contextBox: CallbackContext?
    private let queue = DispatchQueue(label: "dev.strata.fsevents", qos: .utility)
    /// Receives each batch of events. Set before `start`.
    package var handler: (@Sendable ([Event]) -> Void)?

    package init() {}

    /// Starts watching `paths`, replaying everything since `since` (or only new changes when `nil`).
    package func start(paths: [String], since: FSEventStreamEventId?, latency: TimeInterval = 0.4) -> Bool {
        stop()
        let box = CallbackContext(handler)
        let retained = Unmanaged.passRetained(box)
        var context = FSEventStreamContext(
            version: 0, info: retained.toOpaque(), retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackContext>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info, count > 0 else { return }
            let rawPaths = Unmanaged<AnyObject>.fromOpaque(paths).takeUnretainedValue()
            guard CFGetTypeID(rawPaths) == CFArrayGetTypeID(),
                  let list = rawPaths as? [String] else { return }
            let box = Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue()
            let total = min(count, list.count)
            var events: [Event] = []
            events.reserveCapacity(total)
            for index in 0..<total {
                events.append(Event(path: list[index], flags: flags[index], id: ids[index]))
            }
            box.emit(events)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            retained.release()
            return false
        }
        contextBox = box
        FSEventStreamSetDispatchQueue(stream, queue)
        self.stream = stream
        guard FSEventStreamStart(stream) else { stop(); return false }
        return true
    }

    package func stop() {
        contextBox?.clear()
        contextBox = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }

    package static var currentEventID: FSEventStreamEventId { FSEventsGetCurrentEventId() }

    /// Which journal the system keeps for the volume each of `paths` is on, or nil when one of them has none or
    /// cannot be read.
    /// Events since an earlier point can only come from the journal that recorded that point. A volume without one
    /// answers with nothing, and a journal that replaced another (after an unclean shutdown, a restore or an erased
    /// disk) holds nothing from before it. Either way the stream still says its history is complete.
    package static func journal(for paths: [String]) -> [String]? {
        var journals: [String] = []
        for path in paths {
            var info = stat()
            guard stat(path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev),
                  let name = CFUUIDCreateString(nil, uuid) else { return nil }
            journals.append(name as String)
        }
        return journals
    }
}
