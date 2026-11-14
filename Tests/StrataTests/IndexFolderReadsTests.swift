import CoreServices
import Foundation
import Testing
import os
@testable import Strata
@testable import StrataIndex
@testable import StrataModel
@testable import StrataSearch
@testable import StrataSupport

/// A folder that stops answering holds only the thread that reads it: the index gives the read up, leaves the folder
/// unread and goes on. Time here is a clock the tests move, and only while the read meant is the only one under
/// way: a read that should answer is never given up because the machine was slow. A read that waits has a thread of
/// its own: neither one of those the tests share, nor one of the pool Dispatch shares between every suite, which a
/// held read would keep a thread of for as long as it is held. Waits are bounded by turns, not by the clock, so that
/// other suites holding the main actor cannot make one run out.
struct IndexFolderReadsTests {
    /// A read that does not return until the test lets it go, as on a volume that stopped answering.
    private nonisolated final class HeldRead: Sendable {
        let path: String
        private let released = DispatchSemaphore(value: 0)
        private let state = OSAllocatedUnfairLock(initialState: (asked: [String](), released: false))

        init(_ path: String) { self.path = path }

        /// Everything the readers were asked for, in order.
        var asked: [String] { state.withLock { $0.asked } }
        var isReleased: Bool { state.withLock { $0.released } }

        /// Lets every read of the path return, now and later.
        func release() {
            state.withLock { $0.released = true }
            released.signal()
        }

        private func enter(_ path: String) {
            state.withLock { $0.asked.append(path) }
            guard path == self.path else { return }
            // Only ends a read whose test never lets it go: every test does, when it ends.
            _ = released.wait(timeout: .now() + 600)
            released.signal()
        }

        var reader: IndexWorker.DirectoryRead {
            { [self] path, items, names, buffer, stop in
                enter(path)
                return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
            }
        }

        var itemReader: IndexWorker.ItemRead {
            { [self] path, items, names in
                enter(path)
                return BulkDirectoryReader.readItem(path, items: &items, names: &names)
            }
        }
    }

    /// The time reads are given, which stands still until a test moves it, and how often it was looked at.
    private nonisolated final class Time: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (nanoseconds: UInt64(1_000_000_000), looks: 0))

        var now: @Sendable () -> UInt64 {
            { [state] in
                state.withLock { state in
                    state.looks += 1
                    return state.nanoseconds
                }
            }
        }

        var looks: Int { state.withLock { $0.looks } }

        func pass(_ seconds: TimeInterval) {
            state.withLock { $0.nanoseconds += UInt64(seconds * 1_000_000_000) }
        }
    }

    /// Work that waits, on a thread of its own, and what it returned once it has.
    private nonisolated final class Pending<Value: Sendable>: Sendable {
        private let result = OSAllocatedUnfairLock<Value?>(initialState: nil)

        init(priority: QualityOfService = .default, _ work: @escaping @Sendable () -> Value) {
            let thread = Thread { [result] in
                let value = work()
                result.withLock { $0 = value }
            }
            thread.qualityOfService = priority
            thread.start()
        }

        var value: Value? { result.withLock { $0 } }
        var isOver: Bool { value != nil }
    }

    private nonisolated struct Listing: Sendable, Equatable {
        var status: Int32
        var names: [String]
    }

    private nonisolated static func names(of items: [ScannedItem], in names: [UInt8]) -> [String] {
        items.map { String(decoding: names[$0.nameOffset..<$0.nameOffset + $0.nameLength], as: UTF8.self) }.sorted()
    }

    /// Waits for `condition`, a bounded number of turns: a broken rule can keep it from ever holding.
    private func until(_ condition: @Sendable () -> Bool) async throws {
        var turns = 0
        while !condition() {
            turns += 1
            try #require(turns < 10_000, "The condition waited for never held.")
            try await Task.sleep(for: .milliseconds(3))
        }
    }

    /// What `pending` returned, once it has.
    private func finished<Value: Sendable>(_ pending: Pending<Value>) async throws -> Value {
        try await until { pending.isOver }
        return try #require(pending.value)
    }

    /// Starts one folder read for a refresh, with what it finds by name.
    private func startRead(_ path: String, with reads: IndexFolderReads,
                           shouldStop: @escaping @Sendable () -> Bool = { false }) -> Pending<Listing> {
        Pending {
            var items: [ScannedItem] = [], names: [UInt8] = []
            let status = reads.read(path, items: &items, names: &names, shouldStop: shouldStop)
            return Listing(status: status, names: Self.names(of: items, in: names))
        }
    }

    private func read(_ path: String, with reads: IndexFolderReads,
                      shouldStop: @escaping @Sendable () -> Bool = { false }) async throws -> Listing {
        try await finished(startRead(path, with: reads, shouldStop: shouldStop))
    }

    /// Starts the read of one item by itself.
    private func startItemRead(_ path: String, with reads: IndexFolderReads,
                               shouldStop: @escaping @Sendable () -> Bool = { false }) -> Pending<Listing> {
        Pending {
            var items: [ScannedItem] = [], names: [UInt8] = []
            let status = reads.readItem(path, items: &items, names: &names, shouldStop: shouldStop)
            return Listing(status: status, names: Self.names(of: items, in: names))
        }
    }

    /// Starts the read of a scan's batch.
    private func startScan(_ paths: [String], with reads: IndexFolderReads,
                           shouldStop: @escaping @Sendable () -> Bool = { false }) -> Pending<[Listing]> {
        Pending {
            reads.readScanned(paths, shouldStop: shouldStop).map {
                Listing(status: $0.status, names: Self.names(of: $0.items, in: $0.names))
            }
        }
    }

    /// Lets more than patience pass, once `held` has been asked for its path: a read of it is then under way, and
    /// in these tests nothing else is.
    private func losePatience(with held: HeldRead, on time: Time) async throws {
        try await until { held.asked.contains(held.path) }
        time.pass(IndexFolderReads.patience + 1)
    }

    /// Returns once whoever waits for a read has looked at it several times more, and so has had every chance to
    /// let go of it.
    private func lookedAtAgain(on time: Time) async throws {
        let looked = time.looks
        try await until { time.looks >= looked + 3 }
    }

    /// Lets the moment a read is given to stop pass, as often as it takes for `read` to return: the moment starts
    /// when whoever waits hears of the stop.
    private func stopGracePasses<Value: Sendable>(on time: Time, until read: Pending<Value>) async throws {
        try await until {
            time.pass(IndexFolderReads.stopGrace)
            return read.isOver
        }
    }

    /// The same, once each time whoever waits has looked again, and never as long as patience in all: a read that
    /// was not told to stop is then not given up either, and what waits for it never ends.
    private func stopGracePasses(on time: Time, shortOfPatienceUntil over: @Sendable () -> Bool) async throws {
        let state = OSAllocatedUnfairLock(initialState: (looks: time.looks, passed: TimeInterval(0)))
        try await until {
            state.withLock { state in
                let looks = time.looks
                guard looks > state.looks, state.passed + IndexFolderReads.stopGrace < IndexFolderReads.patience else { return }
                time.pass(IndexFolderReads.stopGrace)
                state = (looks, state.passed + IndexFolderReads.stopGrace)
            }
            return over()
        }
    }

    private static let tree = ["calm/a.txt", "calm/inner/b.txt", "stuck/c.txt", "stuck/inside/d.txt", "stuck2/e.txt"]
    private static let listing = ["calm/", "calm/a.txt", "calm/inner/", "calm/inner/b.txt", "stuck/", "stuck/c.txt",
                                  "stuck/inside/", "stuck/inside/d.txt", "stuck2/", "stuck2/e.txt"]

    @Test func whatAReadFindsIsHandedOverAsItWasReadAndAddedToWhatWasThere() async throws {
        let tree = try TestTree(Self.tree)
        let reads = IndexFolderReads()
        #expect(try await read(tree.url("calm").path, with: reads) == Listing(status: 0, names: ["a.txt", "inner"]))
        #expect(try await finished(startScan([tree.url("calm").path], with: reads)) == [Listing(status: 0, names: ["a.txt", "inner"])])
        #expect(try await read(tree.url("missing").path, with: reads).status == ENOENT)
        #expect(try await finished(startScan([], with: reads)) == [])
        // Items read one by one gather in the same lists, each still found by where its name starts.
        let root = tree.root
        let gathered = try await finished(Pending {
            var items: [ScannedItem] = [], names: [UInt8] = []
            let statuses = ["calm/a.txt", "stuck/c.txt", "stuck2/e.txt"].map {
                reads.readItem(root.appending(path: $0).path, items: &items, names: &names) { false }
            }
            return Listing(status: statuses.max() ?? -1, names: Self.names(of: items, in: names))
        })
        #expect(gathered == Listing(status: 0, names: ["a.txt", "c.txt", "e.txt"]))
        #expect(reads.unanswered == [])
        #expect(tree.snapshot() == Self.listing)
    }

    @Test func aFolderThatNeverAnswersIsGivenUpAndNotAskedAgainUntilItDoes() async throws {
        let tree = try TestTree(Self.tree)
        let stuck = tree.url("stuck").path
        let held = HeldRead(stuck)
        defer { held.release() }
        let time = Time()
        let reads = IndexFolderReads(readFolder: held.reader, now: time.now)
        let givenUp = startRead(stuck, with: reads)
        try await losePatience(with: held, on: time)
        #expect(try await finished(givenUp) == Listing(status: ETIMEDOUT, names: []))
        #expect(reads.unanswered == [stuck] && held.asked == [stuck])
        // While its read is out, the folder and what lies in it are refused at once, without another thread held.
        #expect(try await read(stuck, with: reads).status == ETIMEDOUT)
        #expect(try await read(stuck + "/inside", with: reads).status == ETIMEDOUT)
        #expect(held.asked == [stuck])
        // A folder beside it, and one whose name only begins like it, are read as ever.
        #expect(try await read(tree.url("calm").path, with: reads) == Listing(status: 0, names: ["a.txt", "inner"]))
        #expect(try await read(tree.url("stuck2").path, with: reads) == Listing(status: 0, names: ["e.txt"]))

        // It answers at last: what that read found is dropped, and the folder can be asked again.
        held.release()
        try await until { reads.unanswered.isEmpty }
        #expect(try await read(stuck, with: reads) == Listing(status: 0, names: ["c.txt", "inside"]))
        #expect(try await read(stuck + "/inside", with: reads) == Listing(status: 0, names: ["d.txt"]))
        #expect(tree.snapshot() == Self.listing)
    }

    @Test func aScansBatchIsReadPastAFolderThatNeverAnswersAndAsFarAsItIsNotStopped() async throws {
        let tree = try TestTree(Self.tree)
        let stuck = tree.url("stuck").path, calm = tree.url("calm").path, other = tree.url("stuck2").path
        let held = HeldRead(stuck)
        defer { held.release() }
        let time = Time()
        let stopsAfterCalm = OSAllocatedUnfairLock(initialState: false), stopping = OSAllocatedUnfairLock(initialState: false)
        let reads = IndexFolderReads(readScannedFolder: { path, items, names, buffer, stop in
            let status = held.reader(path, &items, &names, buffer, stop)
            if path == calm, stopsAfterCalm.withLock({ $0 }) { stopping.withLock { $0 = true } }
            return status
        }, now: time.now)
        // What comes before the folder is kept, the folder is given up, and what comes after it is read all the same.
        let batch = startScan([calm, stuck, other, stuck + "/inside"], with: reads)
        try await losePatience(with: held, on: time)
        #expect(try await finished(batch) == [
            Listing(status: 0, names: ["a.txt", "inner"]), Listing(status: ETIMEDOUT, names: []),
            Listing(status: 0, names: ["e.txt"]), Listing(status: ETIMEDOUT, names: []),
        ])
        #expect(reads.unanswered == [stuck] && held.asked == [calm, stuck, other])

        // Told to stop part way, a batch ends there: what was read stays, the rest is cancelled unread.
        stopsAfterCalm.withLock { $0 = true }
        let stopped = try await finished(startScan([calm, other, calm], with: reads) { stopping.withLock { $0 } })
        #expect(stopped.map(\.status) == [0, ECANCELED, ECANCELED] && stopped[0].names == ["a.txt", "inner"])
        #expect(held.asked == [calm, stuck, other, calm])
        #expect(tree.snapshot() == Self.listing)
    }

    @Test func inAScansBatchPatienceStartsAgainWithEachFolderRead() async throws {
        let tree = try TestTree(Self.tree)
        let missing = tree.url("missing").path, other = tree.url("stuck2").path
        let held = HeldRead(other)
        defer { held.release() }
        let time = Time()
        let reads = IndexFolderReads(readScannedFolder: { path, items, names, buffer, stop in
            // A folder that takes most of patience to say it cannot be read, with no sign of life on the way.
            if path == missing {
                time.pass(IndexFolderReads.patience * 0.6)
                return ENOENT
            }
            return held.reader(path, &items, &names, buffer, stop)
        }, now: time.now)
        let batch = startScan([missing, other], with: reads)
        // The folder after it has had the same again when it is looked at: more than patience since the batch was
        // asked for, and less since the folder before it was read.
        try await until { held.asked == [other] }
        time.pass(IndexFolderReads.patience * 0.6)
        try await lookedAtAgain(on: time)
        #expect(!batch.isOver)
        held.release()
        #expect(try await finished(batch) == [Listing(status: ENOENT, names: []), Listing(status: 0, names: ["e.txt"])])
        #expect(reads.unanswered == [])
        #expect(tree.snapshot() == Self.listing)
    }

    @Test func aReadThatKeepsGettingFurtherIsWaitedForHoweverLongItTakes() async throws {
        let tree = try TestTree(Self.tree)
        let calm = tree.url("calm").path
        let time = Time()
        // A folder so large that reading it outlasts patience many times over, with a sign of life between batches:
        // whoever waits looks at it more than once between two of them.
        let reads = IndexFolderReads(readFolder: { path, items, names, buffer, stop in
            for _ in 0..<12 {
                if stop() { return ECANCELED }
                time.pass(IndexFolderReads.patience / 2)
                let looked = time.looks
                while time.looks < looked + 3 { usleep(2_000) }
            }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        }, now: time.now)
        #expect(try await read(calm, with: reads) == Listing(status: 0, names: ["a.txt", "inner"]))
        #expect(reads.unanswered == [])
        #expect(tree.snapshot() == Self.listing)
    }

    @Test func aReadToldToStopIsNotStartedAndOneUnderWayThatCannotStopIsLeftWithNothingHeldAgainstItsFolder() async throws {
        let tree = try TestTree(Self.tree)
        let stuck = tree.url("stuck").path
        let held = HeldRead(stuck)
        defer { held.release() }
        let time = Time()
        let stopping = OSAllocatedUnfairLock(initialState: true)
        let reads = IndexFolderReads(readFolder: held.reader, now: time.now)
        // Told to stop before it starts, a read is not started.
        #expect(try await read(tree.url("calm").path, with: reads) { stopping.withLock { $0 } }.status == ECANCELED)
        #expect(try await read(stuck, with: reads) { stopping.withLock { $0 } }.status == ECANCELED)
        #expect(reads.unanswered == [] && held.asked == [])
        // Told to stop while it runs, a read that cannot is left where it is after a moment, long before patience
        // would run out.
        stopping.withLock { $0 = false }
        let left = startRead(stuck, with: reads) { stopping.withLock { $0 } }
        try await until { held.asked == [stuck] }
        stopping.withLock { $0 = true }
        try await stopGracePasses(on: time, until: left)
        #expect(left.value?.status == ECANCELED)
        // Its folder may be slow and no more: it is not refused, and the next read asks it.
        #expect(reads.unanswered == [])
        stopping.withLock { $0 = false }
        let again = startRead(stuck, with: reads)
        try await until { held.asked == [stuck, stuck] }
        held.release()
        #expect(try await finished(again) == Listing(status: 0, names: ["c.txt", "inside"]))
        #expect(tree.snapshot() == Self.listing)
    }

    @Test func noMoreReadsAreGivenUpThanTheLimitAndTheNextIsWaitedForUnlessItIsToldToStop() async throws {
        let tree = try TestTree(Self.tree)
        let first = HeldRead(tree.url("stuck").path), second = HeldRead(tree.url("stuck2").path)
        let third = HeldRead(tree.url("calm").path)
        defer { [first, second, third].forEach { $0.release() } }
        let time = Time()
        let reads = IndexFolderReads(readFolder: { path, items, names, buffer, stop in
            let held = [first, second, third].first { $0.path == path } ?? first
            return held.reader(path, &items, &names, buffer, stop)
        }, mostGivenUp: 1, now: time.now)
        let givenUp = startRead(first.path, with: reads)
        try await losePatience(with: first, on: time)
        #expect(try await finished(givenUp).status == ETIMEDOUT)
        // Past the limit no thread is given away: the read is waited for, as every read was before. Whoever waits
        // has looked several times since patience ran out, and not let go.
        let waitedFor = startRead(second.path, with: reads)
        try await losePatience(with: second, on: time)
        try await lookedAtAgain(on: time)
        #expect(!waitedFor.isOver && reads.unanswered == [first.path])
        second.release()
        #expect(try await finished(waitedFor) == Listing(status: 0, names: ["e.txt"]))
        // Told to stop, it is left all the same: quitting and turning the index off wait on no folder, however
        // many do not answer.
        let stopping = OSAllocatedUnfairLock(initialState: false)
        let left = startRead(third.path, with: reads) { stopping.withLock { $0 } }
        try await losePatience(with: third, on: time)
        try await lookedAtAgain(on: time)
        #expect(!left.isOver)
        stopping.withLock { $0 = true }
        try await stopGracePasses(on: time, until: left)
        #expect(left.value?.status == ECANCELED)
        #expect(reads.unanswered == [first.path])
        #expect(tree.snapshot() == Self.listing)
    }

    @Test func aFolderAlwaysWaitedForIsNotGivenUpHoweverLongItTakes() async throws {
        let tree = try TestTree(Self.tree)
        let stuck = tree.url("stuck").path
        let held = HeldRead(stuck)
        defer { held.release() }
        let time = Time()
        let reads = IndexFolderReads(readFolder: held.reader, now: time.now)
        reads.alwaysWait(for: [stuck])
        let waitedFor = startRead(stuck, with: reads)
        try await losePatience(with: held, on: time)
        try await lookedAtAgain(on: time)
        #expect(!waitedFor.isOver && reads.unanswered == [])
        held.release()
        #expect(try await finished(waitedFor) == Listing(status: 0, names: ["c.txt", "inside"]))
        #expect(tree.snapshot() == Self.listing)
    }

    @Test func anItemThatDoesNotAnswerSaysSoOfTheFolderItIsInAndCanBeToldToStop() async throws {
        let tree = try TestTree(Self.tree)
        let stuck = tree.url("stuck").path, item = stuck + "/c.txt", elsewhere = tree.url("calm/a.txt").path
        let held = HeldRead(item), heldElsewhere = HeldRead(elsewhere)
        defer { [held, heldElsewhere].forEach { $0.release() } }
        let holdsElsewhere = OSAllocatedUnfairLock(initialState: false)
        let time = Time()
        let reads = IndexFolderReads(readItem: { path, items, names in
            path == elsewhere && holdsElsewhere.withLock { $0 }
                ? heldElsewhere.itemReader(path, &items, &names) : held.itemReader(path, &items, &names)
        }, now: time.now)
        let givenUp = startItemRead(item, with: reads)
        try await losePatience(with: held, on: time)
        #expect(try await finished(givenUp).status == ETIMEDOUT)
        // The folder answers no better than its item: listing it instead would hold another thread the same way.
        #expect(reads.unanswered == [stuck])
        #expect(try await read(stuck, with: reads).status == ETIMEDOUT)
        #expect(try await finished(startItemRead(stuck + "/inside", with: reads)).status == ETIMEDOUT)
        #expect(held.asked == [item])
        #expect(try await finished(startItemRead(elsewhere, with: reads)) == Listing(status: 0, names: ["a.txt"]))

        // Told to stop, an item's read is left after a moment like a folder's, with nothing held against the folder.
        holdsElsewhere.withLock { $0 = true }
        let stopping = OSAllocatedUnfairLock(initialState: false)
        let left = startItemRead(elsewhere, with: reads) { stopping.withLock { $0 } }
        try await until { heldElsewhere.asked == [elsewhere] }
        stopping.withLock { $0 = true }
        try await stopGracePasses(on: time, until: left)
        #expect(left.value?.status == ECANCELED)
        #expect(reads.unanswered == [stuck])

        // The item answers: its folder can be asked again.
        held.release()
        try await until { reads.unanswered.isEmpty }
        #expect(try await read(stuck, with: reads) == Listing(status: 0, names: ["c.txt", "inside"]))
        #expect(tree.snapshot() == Self.listing)
    }

    @Test func aReadRunsAtThePriorityOfWhoeverAskedForIt() async throws {
        let tree = try TestTree(Self.tree)
        let seen = OSAllocatedUnfairLock(initialState: [qos_class_t]())
        let reads = IndexFolderReads(readFolder: { path, items, names, buffer, stop in
            seen.withLock { $0.append(qos_class_self()) }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        }, now: Time().now)
        let calm = tree.url("calm").path
        // Not the background priority: a machine kept busy by other work may give such a thread no time at all.
        for priority in [QualityOfService.utility, .userInitiated, .default, .utility] {
            let status = try await finished(Pending(priority: priority) {
                var items: [ScannedItem] = [], names: [UInt8] = []
                return reads.read(calm, items: &items, names: &names) { false }
            })
            #expect(status == 0)
        }
        #expect(seen.withLock { $0 } == [QOS_CLASS_UTILITY, QOS_CLASS_USER_INITIATED, QOS_CLASS_DEFAULT, QOS_CLASS_UTILITY])
        #expect(tree.snapshot() == Self.listing)
    }

    /// Reads `count` folders at one time, so that as many threads are kept for reading afterwards.
    private func readTogether(_ count: Int, _ path: String, with reads: IndexFolderReads,
                              started: OSAllocatedUnfairLock<Int>, together: DispatchSemaphore) async throws {
        let all = (0..<count).map { _ in startRead(path, with: reads) }
        try await until { started.withLock { $0 } == count }
        for _ in 0..<count { together.signal() }
        for one in all { #expect(try await finished(one).status == 0) }
    }

    @Test func threadsKeptForReadingEndOnceNothingHasUsedThemForAWhile() async throws {
        let tree = try TestTree(Self.tree)
        let calm = tree.url("calm").path
        let together = DispatchSemaphore(value: 0)
        let started = OSAllocatedUnfairLock(initialState: 0)
        let time = Time()
        // Reads under way at one time need a thread each.
        let reader: IndexWorker.DirectoryRead = { path, items, names, buffer, stop in
            started.withLock { $0 += 1 }
            _ = together.wait(timeout: .now() + 600)
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        }
        let reads = IndexFolderReads(readFolder: reader, now: time.now)
        try await readTogether(4, calm, with: reads, started: started, together: together)
        #expect(reads.idleThreads == 4)
        // Used again at once, all are kept; after a while unused, the next read keeps one.
        together.signal()
        #expect(try await read(calm, with: reads).status == 0)
        #expect(reads.idleThreads == 4)
        time.pass(IndexFolderReads.idleLife + 1)
        together.signal()
        #expect(try await read(calm, with: reads).status == 0)
        #expect(reads.idleThreads == 1)

        // With nothing read again, they end by themselves.
        started.withLock { $0 = 0 }
        let unused = IndexFolderReads(readFolder: reader, patience: 3_600, idleLife: 0.2)
        try await readTogether(3, calm, with: unused, started: started, together: together)
        try await until { unused.idleThreads == 1 }
        #expect(tree.snapshot() == Self.listing)
    }

    @Test func manyReadsAtOnceShareTheThreadsKeptForReadingAndEachGetsItsOwnAnswer() async throws {
        let tree = try TestTree(Self.tree)
        let folders = ["calm": ["a.txt", "inner"], "calm/inner": ["b.txt"], "stuck": ["c.txt", "inside"], "stuck2": ["e.txt"]]
        let paths = folders.keys.sorted().map { (name: $0, path: tree.url($0).path) }
        // Threads are given back and taken all the time, and ones unused a moment end meanwhile.
        let reads = IndexFolderReads(patience: 3_600, idleLife: 0.001)
        let workers = (0..<12).map { worker in
            Pending<[String]> {
                var wrong: [String] = []
                for round in 0..<400 {
                    let folder = paths[(worker + round) % paths.count]
                    var items: [ScannedItem] = [], names: [UInt8] = []
                    let status: Int32
                    if round % 3 == 0, let listing = reads.readScanned([folder.path, folder.path]) { false }.last {
                        (status, items, names) = (listing.status, listing.items, listing.names)
                    } else {
                        status = reads.read(folder.path, items: &items, names: &names) { false }
                    }
                    if status != 0 || Self.names(of: items, in: names) != folders[folder.name] {
                        wrong.append("\(folder.name): \(status)")
                    }
                }
                return wrong
            }
        }
        for worker in workers { #expect(try await finished(worker) == []) }
        #expect(reads.unanswered == [] && (1...12).contains(reads.idleThreads))
        #expect(tree.snapshot() == Self.listing)
    }

    // MARK: - Folders that are only in the cloud

    @Test func theThreadsThatReadForTheIndexNeverFetchWhatIsOnlyInTheCloud() async throws {
        let tree = try TestTree(Self.tree)
        let calm = tree.url("calm").path
        let fetching: @Sendable () -> Int32 = { getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) }
        let whileReading = OSAllocatedUnfairLock(initialState: [Int32]())
        let folder: IndexWorker.DirectoryRead = { path, items, names, buffer, stop in
            whileReading.withLock { $0.append(fetching()) }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        }
        let reads = IndexFolderReads(readFolder: folder, readScannedFolder: folder, readItem: { path, items, names in
            whileReading.withLock { $0.append(fetching()) }
            return BulkDirectoryReader.readItem(path, items: &items, names: &names)
        }, now: Time().now)
        let whoeverAsks = try await finished(Pending { () -> [Int32] in
            var items: [ScannedItem] = [], names: [UInt8] = []
            let before = fetching()
            let statuses = [reads.read(calm, items: &items, names: &names) { false },
                            reads.readScanned([calm]) { false }[0].status,
                            reads.readItem(calm + "/a.txt", items: &items, names: &names) { false }]
            return [before, fetching()] + statuses
        })
        // A folder that is only in the cloud then says so at once, where a fetch would wait on its provider.
        let off = IOPOL_MATERIALIZE_DATALESS_FILES_OFF, asItWas = IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT
        #expect(whileReading.withLock { $0 } == [off, off, off])
        // Whoever asks is left as it was: what it opens itself is fetched as ever.
        #expect(whoeverAsks == [asItWas, asItWas, 0, 0, 0])
        #expect(tree.snapshot() == Self.listing)
    }

    @Test func aFolderThatIsOnlyInTheCloudStaysUnreadAndIsReadOnceItIsOnTheMac() async throws {
        let tree = try TestTree([".state/"] + Self.tree)
        let cloud = tree.url("stuck").path
        let onlyInTheCloud = OSAllocatedUnfairLock(initialState: true)
        // As such a folder answers a thread told not to fetch it.
        let reader: IndexWorker.DirectoryRead = { path, items, names, buffer, stop in
            if path == cloud, onlyInTheCloud.withLock({ $0 }) { return EDEADLK }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        }
        let fixture = try await IndexWorkerFixture.start(tree, read: reader, scan: reader, item: { path, items, names in
            path.hasPrefix(cloud + "/") && onlyInTheCloud.withLock { $0 }
                ? EDEADLK : BulkDirectoryReader.readItem(path, items: &items, names: &names)
        })
        // The index holds the folder, as its parent lists it, and nothing of what is in it.
        #expect(entries(fixture.store, in: tree) == ["calm", "calm/a.txt", "calm/inner", "calm/inner/b.txt", "stuck", "stuck2", "stuck2/e.txt"])
        #expect(try isUnread(cloud, in: fixture.store))
        // A change in it while it is still in the cloud leaves it as it is: not read, and not taken for gone.
        let fileChanged = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        fixture.worker.receive([.change(cloud + "/inside", id: fixture.eventID + 1),
                                .init(path: cloud + "/c.txt", flags: fileChanged, id: fixture.eventID + 2)])
        await fixture.checkpoint(force: true)
        #expect(try isUnread(cloud, in: fixture.currentStore) && !holds(cloud + "/c.txt", fixture))

        // Opened somewhere, it is on the Mac. Its first change reads it whole, though it names one file: the rest of
        // what is in it is as new to the index.
        onlyInTheCloud.withLock { $0 = false }
        fixture.worker.receive([.init(path: cloud + "/c.txt", flags: fileChanged, id: fixture.eventID + 3)])
        await fixture.checkpoint(force: true)
        #expect(try !isUnread(cloud, in: fixture.currentStore))
        #expect(holds(cloud + "/c.txt", fixture) && holds(cloud + "/inside/d.txt", fixture))
        #expect(tree.snapshot().filter { !$0.hasPrefix(".state") } == Self.listing)
    }

    @MainActor @Test func aFolderTheIndexHoldsWithoutHavingReadItShowsNoSizeUntilAsked() async throws {
        let tree = try TestTree("Apps/", "home/own/", "home/local/a.txt", "home/cloud/b.txt")
        let cloud = tree.url("home/cloud"), local = tree.url("home/local"), own = tree.url("home/own")
        // The index keeps its own state in the home folder, as Strata does, and leaves that folder out.
        let storage = SecureStorage.Context(directory: own, caches: tree.url("Caches"), key: nil)
        let copies = CopyProviders([], remoteCopies: RemoteCopyStore(root: tree.url("Servers"), server: { _ in nil }),
                                   containerCopies: ContainerCopyStore(root: tree.url("Containers")),
                                   clipboardRoot: tree.url("Clipboard"))
        // It goes on applying changes once it has scanned, as a running index does.
        let index = FileIndex(storage: storage, copies: copies, preferences: try Prefs.isolated(),
                              folders: (home: tree.url("home"), applications: tree.url("Apps")),
                              realPaths: FileIndex.realPathsHoweverLongTheyTake, makeWorker: {
            IndexWorker(saveInterval: .infinity, readScannedDirectory: { path, items, names, buffer, stop in
                path.hasSuffix("/home/cloud")
                    ? EDEADLK : BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
            }, startEvents: { _, _ in true }, journal: { _ in ["journal"] })
        })
        index.start()
        var turns = 0
        while index.folderSizeLookup(local) == .pending || index.folderSizeLookup(cloud) == .pending || index.phase != .updating {
            turns += 1
            try #require(turns < 10_000, "The folder is not one the index is about to read: it has scanned.")
            try await Task.sleep(for: .milliseconds(3))
        }
        #expect(index.folderSize(local)?.files == 1 && !index.leavesSizeUntilAsked(local))
        // Nothing of the folder was read: it has no total to show, and a walk to find one would fetch it. Views
        // leave it until it is asked for, as they leave a folder you excluded, and a size you asked for is not
        // taken back each time the index applies a change elsewhere.
        #expect(index.folderSizeLookup(cloud) == .unindexed && index.leavesSizeUntilAsked(cloud))
        #expect(index.childFolderSizes(tree.url("home")).keys.map { ($0 as NSString).lastPathComponent } == ["local"])
        // The folder that holds it is sized by what was read.
        #expect(index.folderSize(tree.url("home"))?.files == 1 && !index.leavesSizeUntilAsked(tree.url("home")))
        // The index's own folder is outside it, and measured like any folder outside it.
        #expect(index.folderSizeLookup(own) == .unindexed && !index.leavesSizeUntilAsked(own))
        #expect(tree.snapshot().filter { $0.hasPrefix("home/") && !$0.hasPrefix("home/own/") }
            == ["home/", "home/cloud/", "home/cloud/b.txt", "home/local/", "home/local/a.txt"])
    }

    // MARK: - The index past such a folder

    /// The live entries in `store`, relative to the tree.
    private func entries(_ store: IndexStore, in tree: TestTree) -> [String] {
        let root = tree.root.path + "/"
        return store.read { store in
            (0..<store.count).compactMap { i -> String? in
                guard store.flags[i] & IndexStore.Flag.deleted == 0 else { return nil }
                let path = store.path(of: Int32(i))
                return path.hasPrefix(root) && !path.hasPrefix(root + ".state") ? String(path.dropFirst(root.count)) : nil
            }
        }.sorted()
    }

    private func isUnread(_ path: String, in store: IndexStore) throws -> Bool {
        let id = try #require(store.read { $0.lookup(path) })
        return store.read { $0.flags[Int(id)] & IndexStore.Flag.unreadDirectory != 0 }
    }

    private func holds(_ path: String, _ fixture: IndexWorkerFixture) -> Bool {
        fixture.currentStore.read { $0.lookup(path) } != nil
    }

    /// Has the index take up a change in `folder`, as often as it takes for `path` to be indexed: a folder whose
    /// read has just returned may be refused a moment longer.
    private func change(in folder: String, until path: String, isIndexedBy fixture: IndexWorkerFixture,
                        from event: UInt64) async throws {
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        var event = event
        while !holds(path, fixture) {
            try #require(event < fixture.eventID + 500, "The folder was not read once its read had returned.")
            fixture.worker.receive([.init(path: folder, flags: rescan, id: event)])
            event += 1
            await fixture.checkpoint(force: true)
            try await Task.sleep(for: .milliseconds(3))
        }
    }

    private static let everyEntry = ["calm", "calm/a.txt", "calm/inner", "calm/inner/b.txt", "stuck", "stuck/c.txt",
                                     "stuck/inside", "stuck/inside/d.txt", "stuck2", "stuck2/e.txt"]
    /// One folder inside the other: a scan reads them one at a time, so the innermost is read with nothing else
    /// under way.
    private static let chain = ["calm/a.txt", "calm/inner/b.txt", "calm/inner/stuck/c.txt"]
    private static let chainListing = ["calm/", "calm/a.txt", "calm/inner/", "calm/inner/b.txt", "calm/inner/stuck/",
                                       "calm/inner/stuck/c.txt"]

    @Test func aScanGoesOnPastAFolderThatNeverAnswersAndLeavesItUnread() async throws {
        let tree = try TestTree(Self.tree)
        let stuck = tree.url("stuck").path, root = tree.root.path
        let held = HeldRead(stuck)
        defer { held.release() }
        let time = Time()
        let reads = IndexFolderReads(readScannedFolder: held.reader, now: time.now)
        let store = IndexStore()
        let id = store.write { $0.addRoot(path: root, mtime: 0) }
        let scanner = IndexScanner(store: store, excluded: [], noiseFolders: [], reads: reads)
        // One thread scans, so the folders are read one after another and the one held is read alone.
        let scanned = Pending { scanner.scan([(id: id, path: root)], threads: 1); return true }
        try await losePatience(with: held, on: time)
        #expect(try await finished(scanned))
        store.write { $0.aggregate() }
        #expect(entries(store, in: tree) == ["calm", "calm/a.txt", "calm/inner", "calm/inner/b.txt", "stuck", "stuck2", "stuck2/e.txt"])
        #expect(try isUnread(stuck, in: store) && !isUnread(tree.url("calm").path, in: store))
        #expect(tree.snapshot() == Self.listing)
    }

    @Test func aFolderGivenUpInAScanIsLeftUnreadInTheIndexItSavesAndReadAtItsNextChange() async throws {
        let tree = try TestTree([".state/"] + Self.chain)
        let stuck = tree.url("calm/inner/stuck").path
        let held = HeldRead(stuck)
        defer { held.release() }
        let time = Time()
        async let patienceLost: Void = losePatience(with: held, on: time)
        let fixture = try await IndexWorkerFixture.start(tree, scan: held.reader, readClock: time.now)
        try await patienceLost
        #expect(entries(fixture.store, in: tree) == ["calm", "calm/a.txt", "calm/inner", "calm/inner/b.txt", "calm/inner/stuck"])
        #expect(try isUnread(stuck, in: fixture.store))
        // The index it saved says the same, and is one to go on from.
        let (saved, header) = try IndexPersistence.load(from: fixture.config.file, storage: fixture.config.storage)
        #expect(entries(saved, in: tree) == entries(fixture.store, in: tree))
        #expect(header.excluded == [tree.url(".state").path])

        // Once it answers, its next change reads it, as for any folder that could not be read.
        held.release()
        try await change(in: stuck, until: stuck + "/c.txt", isIndexedBy: fixture, from: fixture.eventID + 1)
        #expect(try !isUnread(stuck, in: fixture.currentStore))
        #expect(tree.snapshot().filter { !$0.hasPrefix(".state") } == Self.chainListing)
    }

    @Test func aRootThatDoesNotAnswerIsWaitedForSoNoIndexIsMadeWithoutIt() async throws {
        let tree = try TestTree([".state/"] + Self.tree)
        let held = HeldRead(tree.root.path)
        defer { held.release() }
        let time = Time()
        async let waitedFor: Void = {
            try await losePatience(with: held, on: time)
            try await lookedAtAgain(on: time)
            held.release()
        }()
        let fixture = try await IndexWorkerFixture.start(tree, scan: held.reader, readClock: time.now)
        // The scan ended only once the root answered.
        #expect(held.isReleased)
        try await waitedFor
        #expect(entries(fixture.store, in: tree) == Self.everyEntry)
        #expect(tree.snapshot().filter { !$0.hasPrefix(".state") } == Self.listing)
    }

    @Test func aRunningIndexKeepsUpPastAFolderThatNeverAnswersAndTakesUpItsNextChange() async throws {
        let tree = try TestTree([".state/"] + Self.tree)
        let stuck = tree.url("stuck").path
        let held = HeldRead(stuck)
        defer { held.release() }
        let holding = OSAllocatedUnfairLock(initialState: false)
        let time = Time()
        let fixture = try await IndexWorkerFixture.start(tree, read: { path, items, names, buffer, stop in
            holding.withLock { $0 }
                ? held.reader(path, &items, &names, buffer, stop)
                : BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        }, readClock: time.now)
        holding.withLock { $0 = true }
        try tree.add(["stuck/new.txt", "calm/new.txt"])
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        fixture.worker.receive([.init(path: stuck, flags: rescan, id: fixture.eventID + 1)])
        let applied = OSAllocatedUnfairLock(initialState: false)
        fixture.worker.saveWhenIdle(includeDeferred: true) { applied.withLock { $0 = true } }
        try await losePatience(with: held, on: time)
        try await until { applied.withLock { $0 } }
        // The index goes on to what changes elsewhere.
        fixture.worker.receive([.change(tree.url("calm/new.txt").path, id: fixture.eventID + 2)])
        await fixture.checkpoint(force: true)
        let indexed = entries(fixture.currentStore, in: tree)
        #expect(indexed.contains("calm/new.txt") && !indexed.contains("stuck/new.txt"))
        // What the index held of the folder stays: a folder that does not answer is not one that is gone.
        #expect(indexed.contains("stuck/c.txt") && indexed.contains("stuck/inside/d.txt"))

        // Once it answers, the next change there is taken up.
        held.release()
        try await change(in: stuck, until: stuck + "/new.txt", isIndexedBy: fixture, from: fixture.eventID + 3)
        #expect(tree.snapshot().filter { !$0.hasPrefix(".state") } == (Self.listing + ["calm/new.txt", "stuck/new.txt"]).sorted())
    }

    @Test func aRebuildAskedForDuringASlowReadStillReadsThatFolder() async throws {
        let tree = try TestTree([".state/"] + Self.tree)
        let stuck = tree.url("stuck").path
        let held = HeldRead(stuck)
        defer { held.release() }
        let holding = OSAllocatedUnfairLock(initialState: false)
        let fixture = try await IndexWorkerFixture.start(tree, read: { path, items, names, buffer, stop in
            holding.withLock { $0 }
                ? held.reader(path, &items, &names, buffer, stop)
                : BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        holding.withLock { $0 = true }
        try tree.add(["stuck/new.txt"])
        fixture.worker.receive([.init(path: stuck, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
                                      id: fixture.eventID + 1)])
        fixture.worker.saveWhenIdle(includeDeferred: true)
        try await until { held.asked.contains(stuck) }
        // The refresh is told to stop and its read is left where it is. That read may be slow and no more, so the
        // scan that follows reads the folder itself.
        fixture.worker.rebuildNow()
        try await until { fixture.storeCount == 2 }
        #expect(entries(fixture.currentStore, in: tree) == (Self.everyEntry + ["stuck/new.txt"]).sorted())
        #expect(try !isUnread(stuck, in: fixture.currentStore))
        #expect(tree.snapshot().filter { !$0.hasPrefix(".state") } == (Self.listing + ["stuck/new.txt"]).sorted())
    }

    @Test func turningTheIndexOffDoesNotWaitForAnItemThatDoesNotAnswer() async throws {
        let tree = try TestTree([".state/"] + Self.tree)
        let item = tree.url("calm/a.txt").path
        let held = HeldRead(item)
        defer { held.release() }
        let time = Time()
        let fixture = try await IndexWorkerFixture.start(tree, item: held.itemReader, readClock: time.now)
        // A change to a file reads that file alone.
        fixture.worker.receive([.init(path: item, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile),
                                      id: fixture.eventID + 1)])
        // A save applies what was received first: the refresh starts, and waits in the item's read.
        fixture.worker.saveWhenIdle(includeDeferred: true)
        try await until { held.asked == [item] }
        let retired = OSAllocatedUnfairLock(initialState: false)
        fixture.worker.retire(removing: fixture.config.file) { retired.withLock { $0 = true } }
        // The moment it is given to stop passes, and nothing like patience: it is left because it was told to stop.
        try await stopGracePasses(on: time, shortOfPatienceUntil: { retired.withLock { $0 } })
        #expect(held.asked == [item])
        #expect(!tree.snapshot().contains { $0.hasPrefix(".state/index.sealed") })
        #expect(tree.snapshot().filter { !$0.hasPrefix(".state") } == Self.listing)
    }
}
