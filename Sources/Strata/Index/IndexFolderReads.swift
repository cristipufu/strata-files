import Foundation
import os

/// Reads folders for the index on threads kept for that, and waits for each read only while it gets somewhere. A
/// folder on a volume or cloud provider that stopped answering then holds only its own thread: the read is given up,
/// the folder stays unread like one that could not be opened, and the index goes on. A read given up is left to
/// return when it will. What it finds then is dropped, and until then that folder and what lies in it are not asked
/// again, so a folder that never answers costs one thread, however often it is wanted.
///
/// These threads never fetch what is only in the cloud. A folder whose contents are with its provider and not on the
/// Mac says so at once (`EDEADLK`) and stays unread, where a fetch would wait on the provider for as long as that
/// takes, and download listings nobody asked for.
nonisolated package final class IndexFolderReads: @unchecked Sendable {
    /// How long a read may go without getting further before it is given up.
    package static let patience: TimeInterval = 30
    /// How long a read has to notice that it should stop (quitting, the index turned off) before it is left behind.
    package static let stopGrace: TimeInterval = 0.5
    /// No more reads than this are given up at one time: each holds a thread, so past it a read is waited for.
    package static let mostGivenUp = 32
    /// How long a thread kept for reading stays once nothing has used it: a scan uses many, the hours after it one.
    package static let idleLife: TimeInterval = 30
    private static let glance: TimeInterval = 0.05

    /// One folder, or one item, as read: how the read ended, and what it found.
    package struct Listing: Sendable {
        package var status: Int32
        package var items: [ScannedItem] = []
        package var names: [UInt8] = []

        package init(status: Int32, items: [ScannedItem] = [], names: [UInt8] = []) {
            self.status = status
            self.items = items
            self.names = names
        }
    }

    private let readers: Readers
    private let patience: UInt64
    private let stopGrace: UInt64
    private let idleLife: UInt64
    private let mostGivenUp: Int
    private let now: @Sendable () -> UInt64
    private let shared = OSAllocatedUnfairLock(initialState: Shared())

    /// How folders and items are read: a refresh's folders, a full scan's, and single items.
    private struct Readers: Sendable {
        let folder: IndexWorker.DirectoryRead
        let scannedFolder: IndexWorker.DirectoryRead
        let item: IndexWorker.ItemRead
    }

    private struct Shared {
        /// Threads nobody reads on now, the one used last at the end, with when each was let go.
        var idle: [(lane: Lane, since: UInt64)] = []
        var looksAgainLater = false
        /// The folders whose reads were given up and have not returned.
        var unanswered: [String] = []
        /// Folders never given up on: without them there is nothing to index.
        var awaited: Set<String> = []
    }

    /// A thread that reads, one request at a time, for whoever holds it.
    private final class Lane: @unchecked Sendable {
        let wake = DispatchSemaphore(value: 0)
        let answered = DispatchSemaphore(value: 0)
        /// Set by the holder before `wake`; nil tells the thread to end.
        var request: Request?

        func end() {
            request = nil
            wake.signal()
        }
    }

    private enum Kind { case folder, scannedFolder, item }

    /// What one thread is asked to read, in order, for someone who waits. Whoever waits and the thread that reads
    /// agree under `lock` on how far it got and on whether anyone still waits.
    private final class Request: @unchecked Sendable {
        /// How the thread that reads finds things when it looks: someone waits, or nobody does, and then whether a
        /// folder was noted as not answering, for it to say when that folder's read has returned.
        enum Standing {
            case waitedFor
            case left(noted: String?)
        }

        let kind: Kind
        let paths: [String]
        let priority = qos_class_self()
        private let lock = NSLock()
        private var listings: [Listing] = []
        private var finished = false
        private var standing = Standing.waitedFor
        /// When the reads last got further, by the thread that reads: at first, when they were asked for.
        private var progressed: UInt64
        /// How whoever waits says whether the reads should stop. It is asked under the lock, so never from two
        /// threads at once, and is gone once nobody waits: reads left behind then stop as soon as they can.
        private var shouldStop: (() -> Bool)?

        init(_ kind: Kind, _ paths: [String], asked: UInt64) {
            self.kind = kind
            self.paths = paths
            progressed = asked
        }

        func ask(_ shouldStop: @escaping () -> Bool) {
            lock.withLock { self.shouldStop = shouldStop }
        }

        func askNoMore() {
            lock.withLock { shouldStop = nil }
        }

        var shouldStopNow: Bool {
            lock.withLock { shouldStop?() ?? true }
        }

        var lastProgress: UInt64 {
            lock.withLock { progressed }
        }

        /// The read under way has got further, at `time`. Whether it should stop.
        func gotFurther(at time: UInt64) -> Bool {
            lock.withLock {
                progressed = time
                return shouldStop?() ?? true
            }
        }

        /// Hands over what one read found, unless nobody waits any more. The next read's patience starts here.
        func deliver(_ listing: Listing, at time: UInt64) -> Standing {
            lock.withLock {
                if case .waitedFor = standing {
                    listings.append(listing)
                    progressed = time
                }
                return standing
            }
        }

        /// The reads are over.
        func finish() -> Standing {
            lock.withLock {
                if case .waitedFor = standing { finished = true }
                return standing
            }
        }

        /// What was read, once the reads are over.
        var delivered: [Listing] { lock.withLock { listings } }

        /// Stops waiting for reads that were told to stop and have not, unless they are over. What was read is
        /// taken along, and nothing is held against the folder under way, which may be slow and no more.
        func leaveStopped() -> [Listing]? {
            lock.withLock {
                guard !finished, listings.count < paths.count else { return nil }
                standing = .left(noted: nil)
                return takeListings()
            }
        }

        /// The thread left behind keeps this request for as long as its read lasts: not what was read with it.
        private func takeListings() -> [Listing] {
            defer { listings = [] }
            return listings
        }

        /// Gives up the read under way, unless the reads are over or got further since `progress` was looked at:
        /// the read judged is then not the one under way. What was read before it is taken along. `note` is asked
        /// to note its folder as not answering, and may refuse, which keeps the wait.
        func giveUp(judgedBy progress: UInt64, noting note: (String) -> String?) -> [Listing]? {
            lock.withLock {
                guard !finished, listings.count < paths.count, progressed == progress,
                      let noted = note(paths[listings.count]) else { return nil }
                standing = .left(noted: noted)
                return takeListings()
            }
        }
    }

    package init(readFolder: @escaping IndexWorker.DirectoryRead = BulkDirectoryReader.read,
                 readScannedFolder: @escaping IndexWorker.DirectoryRead = BulkDirectoryReader.read,
                 readItem: @escaping IndexWorker.ItemRead = BulkDirectoryReader.readItem,
                 patience: TimeInterval = IndexFolderReads.patience, stopGrace: TimeInterval = IndexFolderReads.stopGrace,
                 mostGivenUp: Int = IndexFolderReads.mostGivenUp, idleLife: TimeInterval = IndexFolderReads.idleLife,
                 now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.now = now
        readers = Readers(folder: readFolder, scannedFolder: readScannedFolder, item: readItem)
        self.patience = IndexQuietWait.nanoseconds(patience)
        self.stopGrace = IndexQuietWait.nanoseconds(stopGrace)
        self.idleLife = IndexQuietWait.nanoseconds(idleLife)
        self.mostGivenUp = mostGivenUp
    }

    deinit {
        for idle in shared.withLock({ $0.idle }) { idle.lane.end() }
    }

    /// The folders never given up on, however long they take: the index's own, without which there is nothing to
    /// index, and whose index is better kept as it is than replaced by one that lacks them.
    package func alwaysWait(for folders: [String]) {
        shared.withLock { $0.awaited = Set(folders) }
    }

    /// Lists `path` as `BulkDirectoryReader.read` does, appending to `items` and `names`. `ETIMEDOUT` when the read
    /// was given up, or the folder is one that has not answered yet; `ECANCELED` when it was told to stop.
    package func read(_ path: String, items: inout [ScannedItem], names: inout [UInt8], shouldStop: () -> Bool) -> Int32 {
        Self.add(perform(.folder, [path], shouldStop: shouldStop)[0], to: &items, &names)
    }

    /// The same for the folders a full scan reads next, one after another on one thread: a scan reads so many that
    /// handing each over by itself would cost more than reading it. What follows a read told to stop is cancelled too.
    package func readScanned(_ paths: [String], shouldStop: () -> Bool) -> [Listing] {
        perform(.scannedFolder, paths, shouldStop: shouldStop)
    }

    /// Reads the one item at `path` as `BulkDirectoryReader.readItem` does, with the same patience. An item that
    /// does not answer says so of the folder it is in.
    package func readItem(_ path: String, items: inout [ScannedItem], names: inout [UInt8], shouldStop: () -> Bool) -> Int32 {
        Self.add(perform(.item, [path], shouldStop: shouldStop)[0], to: &items, &names)
    }

    /// The folders whose reads were given up and have not returned.
    package var unanswered: [String] { shared.withLock { $0.unanswered } }

    /// The threads kept for reading that nobody reads on now.
    package var idleThreads: Int { shared.withLock { $0.idle.count } }

    /// Names are found by where they start in `names`: what was read starts from nothing.
    private static func add(_ listing: Listing, to items: inout [ScannedItem], _ names: inout [UInt8]) -> Int32 {
        let base = names.count
        if base == 0, items.isEmpty {
            items = listing.items
            names = listing.names
        } else {
            items.append(contentsOf: listing.items.map { item in
                var item = item
                item.nameOffset += base
                return item
            })
            names.append(contentsOf: listing.names)
        }
        return listing.status
    }

    /// One listing for each of `paths`, in order. A folder given up on costs its own patience and no more: what
    /// comes after it is read on another thread.
    private func perform(_ kind: Kind, _ paths: [String], shouldStop: () -> Bool) -> [Listing] {
        var listings: [Listing] = []
        listings.reserveCapacity(paths.count)
        var toldToStop = false
        while listings.count < paths.count, !toldToStop {
            // Their patience runs from when the reads are asked for.
            let request = Request(kind, Array(paths[listings.count...]), asked: now())
            let lane = takeLane()
            // The reads ask it too, where they run, for as long as this waits and no longer.
            let waited = withoutActuallyEscaping(shouldStop) { shouldStop -> Waited in
                request.ask(shouldStop)
                defer { request.askNoMore() }
                lane.request = request
                lane.wake.signal()
                return wait(for: request, on: lane)
            }
            switch waited {
            case .answered:
                giveBack(lane)
                listings += request.delivered
                // Reads that end early were told to stop.
                toldToStop = listings.count < paths.count
            case .leftBehind(let read, let stopped):
                listings += read
                listings.append(Listing(status: stopped ? ECANCELED : ETIMEDOUT))
                toldToStop = stopped
            }
        }
        while listings.count < paths.count { listings.append(Listing(status: ECANCELED)) }
        return listings
    }

    private func takeLane() -> Lane {
        shared.withLock { $0.idle.popLast()?.lane } ?? Self.startLane(readers, shared: shared, now: now)
    }

    private func giveBack(_ lane: Lane) {
        shared.withLock { $0.idle.append((lane, now())) }
        endUnusedLanes()
    }

    /// Ends the threads nothing has used for as long as `idleLife`, all but one, and looks again later for as long
    /// as more than one is kept: nothing may be read again by then.
    private func endUnusedLanes() {
        let (unused, looksAgain) = shared.withLock { shared -> ([Lane], Bool) in
            // Read under the lock: the times kept are then in order, whichever thread gives a lane back.
            let now = now()
            var unused: [Lane] = []
            while shared.idle.count > 1, now >= shared.idle[0].since, now - shared.idle[0].since >= idleLife {
                unused.append(shared.idle.removeFirst().lane)
            }
            let looksAgain = shared.idle.count > 1 && !shared.looksAgainLater
            if looksAgain { shared.looksAgainLater = true }
            return (unused, looksAgain)
        }
        unused.forEach { $0.end() }
        guard looksAgain else { return }
        let life = DispatchTimeInterval.nanoseconds(Int(clamping: idleLife))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + life + Self.glance) { [weak self] in
            guard let self else { return }
            shared.withLock { $0.looksAgainLater = false }
            endUnusedLanes()
        }
    }

    private enum Waited {
        case answered
        case leftBehind(read: [Listing], toldToStop: Bool)
    }

    /// Waits for the reads until they are over or left behind: they got no further for as long as patience lasts,
    /// or were told to stop and did not.
    private func wait(for request: Request, on lane: Lane) -> Waited {
        var toldToStop: UInt64?
        while lane.answered.wait(timeout: .now() + Self.glance) == .timedOut {
            let now = now()
            if toldToStop == nil, request.shouldStopNow { toldToStop = now }
            // A clock is not trusted to run forward: one that stepped back counts as no time gone by.
            if let toldToStop {
                guard now >= toldToStop, now - toldToStop >= stopGrace, let read = request.leaveStopped() else { continue }
                return .leftBehind(read: read, toldToStop: true)
            }
            let progressed = request.lastProgress
            guard now >= progressed, now - progressed >= patience,
                  let read = request.giveUp(judgedBy: progressed, noting: { note($0, read: request.kind) })
            else { continue }
            return .leftBehind(read: read, toldToStop: false)
        }
        return .answered
    }

    /// Notes the folder a read is given up at, and returns it: for an item, the folder it is in, which answers no
    /// better. Nil for a folder that is always waited for, or when too many are given up already.
    private func note(_ path: String, read kind: Kind) -> String? {
        let folder = kind == .item ? IndexRefresh.splitPath(path).parent : path
        return shared.withLock { shared in
            guard shared.unanswered.count < mostGivenUp, !shared.awaited.contains(folder) else { return nil }
            shared.unanswered.append(folder)
            return folder
        }
    }

    /// The read of a folder noted as not answering has returned: the folder may be asked again.
    private static func forget(_ folder: String, in shared: OSAllocatedUnfairLock<Shared>) {
        shared.withLock { shared in
            if let index = shared.unanswered.firstIndex(of: folder) { shared.unanswered.remove(at: index) }
        }
    }

    /// Whether `path` is a folder that has not answered yet, or lies in one: asking again would hold another thread
    /// the same way.
    private static func waitsStill(_ path: String, in shared: OSAllocatedUnfairLock<Shared>) -> Bool {
        shared.withLock { shared in
            shared.unanswered.contains { path == $0 || IndexRefresh.lies(path, in: $0) }
        }
    }

    /// The thread holds what it reads with and nothing of the index: one left behind keeps nothing else alive.
    private static func startLane(_ readers: Readers, shared: OSAllocatedUnfairLock<Shared>,
                                  now: @escaping @Sendable () -> UInt64) -> Lane {
        let lane = Lane()
        let thread = Thread {
            // For this thread alone: whoever asked for the read goes on fetching what it opens itself.
            setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            let buffer = BulkDirectoryReader.ReadBuffer()
            defer { buffer.deallocate() }
            var priority = qos_class_self()
            while true {
                lane.wake.wait()
                guard let request = lane.request else { return }
                lane.request = nil
                // The reads run as whoever asked for them would have: the index keeps to the background it chose.
                if request.priority != priority, pthread_set_qos_class_self_np(request.priority, 0) == 0 {
                    priority = request.priority
                }
                var standing = Request.Standing.waitedFor
                for path in request.paths {
                    guard case .waitedFor = standing, !request.shouldStopNow else { break }
                    let listing = read(path, of: request, with: readers, buffer: buffer, shared: shared, now: now)
                    standing = request.deliver(listing, at: now())
                }
                if case .waitedFor = standing { standing = request.finish() }
                guard case .left(let noted) = standing else {
                    lane.answered.signal()
                    continue
                }
                // Nobody waits any more, and what was found is dropped.
                if let noted { forget(noted, in: shared) }
                return
            }
        }
        thread.name = "dev.strata.index.read"
        thread.qualityOfService = .utility
        thread.start()
        return lane
    }

    private static func read(_ path: String, of request: Request, with readers: Readers,
                             buffer: BulkDirectoryReader.ReadBuffer, shared: OSAllocatedUnfairLock<Shared>,
                             now: @Sendable () -> UInt64) -> Listing {
        guard !waitsStill(path, in: shared) else { return Listing(status: ETIMEDOUT) }
        var listing = Listing(status: 0)
        switch request.kind {
        case .folder, .scannedFolder:
            let read = request.kind == .folder ? readers.folder : readers.scannedFolder
            // A listing asks before each batch: each time it has got further.
            listing.status = read(path, &listing.items, &listing.names, buffer.raw) { request.gotFurther(at: now()) }
        case .item:
            listing.status = readers.item(path, &listing.items, &listing.names)
        }
        return listing
    }
}
