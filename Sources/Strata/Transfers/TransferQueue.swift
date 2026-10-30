import AppKit

/// Every copy and move in the app, and compressing and extracting. Transfer jobs start measuring and asking about
/// conflicts right away, then copy one at a time per destination disk (same-volume moves are renames and never wait).
final class TransferQueue {
    static let shared = TransferQueue()

    /// Posted (object: the queue) when jobs are added, removed, change state, or a few times a second while running.
    static let didChangeNotification = Notification.Name("StrataTransferQueueDidChange")
    /// Posted (object: the job) each time a job finishes a pass: done, failed, cancelled, or after a retry.
    static let jobDidFinishNotification = Notification.Name("StrataTransferJobDidFinish")

    private(set) var jobs: [any QueueJob] = []
    private var priority: [ObjectIdentifier] = []
    /// Called alongside `didChangeNotification`, for a single owner that prefers a closure.
    var onChange: (() -> Void)?

    private var busyDisks: [dev_t: ObjectIdentifier] = [:]
    private var waiters: [(job: ObjectIdentifier, disk: dev_t, continuation: CheckedContinuation<Bool, Never>)] = []
    private var ticker: Task<Void, Never>?
    private var notifyScheduled = false

    let preferences: Prefs
    let history: OperationLog
    let copies: CopyProviders

    init(preferences: Prefs = .shared, history: OperationLog = .shared, copies: CopyProviders? = nil) {
        self.preferences = preferences
        self.history = history
        self.copies = copies ?? .live
    }

    var defaultOptions: TransferEngine.Options {
        var options = TransferEngine.Options()
        options.verify = preferences.verifyCopies
        return options
    }

    // MARK: - Public

    /// Copies or moves `sources` into the folder `destination`. Name clashes go to `conflicts`; with `verify`, every
    /// copied file is read back and compared (SHA-256). When the job finishes, its undo is registered on `undo`.
    @discardableResult
    func enqueue(_ sources: [URL], to destination: URL, mode: TransferMode, verify: Bool? = nil,
                 undo: UndoManager?, conflicts: ConflictResolver) -> TransferJob {
        var options = TransferEngine.Options()
        options.verify = verify ?? preferences.verifyCopies
        return enqueue(sources, to: destination, mode: mode, options: options, undo: undo, conflicts: conflicts)
    }

    @discardableResult
    func enqueue(_ sources: [URL], to destination: URL, mode: TransferMode, options: TransferEngine.Options,
                 undo: UndoManager?, conflicts: ConflictResolver) -> TransferJob {
        let folder = destination.standardizedFileURL
        let moves = sources.map { TransferMove(from: $0.standardizedFileURL, to: folder.appending(path: $0.lastPathComponent)) }
        return enqueue(moves: moves, destination: folder, mode: mode, options: options, undo: undo, conflicts: conflicts)
    }

    /// Item-by-item destinations, for undoing moves whose items came from different folders.
    @discardableResult
    func enqueue(moves: [TransferMove], destination: URL? = nil, mode: TransferMode,
                 options: TransferEngine.Options? = nil, undo: UndoManager?, conflicts: ConflictResolver,
                 logHistory: Bool = true, actionName: String? = nil, containers: [URL] = [],
                 containerOwnership: CreatedFolders? = nil) -> TransferJob {
        // An archive opened as a folder is a temporary copy: nothing goes into it, and what leaves it is copied.
        let moves = moves.filter { !ReadOnlyCopies.contains($0.to, copies: copies) }
        let mode = mode == .move && moves.contains(where: { ReadOnlyCopies.contains($0.from, copies: copies) }) ? .copy : mode
        let folder = destination ?? moves.first?.to.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")
        let job = TransferJob(mode: mode, moves: moves, destination: folder, options: options ?? defaultOptions, undo: undo,
                              conflicts: conflicts, queue: self)
        job.logsHistory = logHistory
        job.actionName = actionName
        job.containers = containerOwnership ?? CreatedFolders(containers)
        jobs.append(job)
        job.start()
        notify()
        startTicking()
        return job
    }

    /// Runs a Compress or Extract in the list, with the copies. Archive jobs run one at a time (several tools on one disk
    /// only slow each other down, and their free-space checks would race); the rest wait in the list.
    func add(_ job: ArchiveJob) {
        jobs.append(job)
        job.onChange = { [weak self] _ in self?.notify() }
        job.onFinish = { [weak self, previous = job.onFinish] job in
            previous?(job)
            self?.startNextArchiveJob()
            self?.notifyNow()
        }
        startNextArchiveJob()
        notify()
        startTicking()
    }

    /// Reading from a provider starts right away, alongside other transfers.
    func add(_ job: CopyFetchJob) {
        jobs.append(job)
        job.onChange = { [weak self] _ in self?.notify() }
        job.onFinish = { [weak self, previous = job.onFinish] job in
            previous?(job)
            self?.notifyNow()
        }
        job.start()
        notify()
        startTicking()
    }

    /// Copying onto a server: starts right away, alongside copies on this Mac.
    func add(_ job: RemoteUploadJob) {
        jobs.append(job)
        job.onChange = { [weak self] _ in self?.notify() }
        job.onFinish = { [weak self, previous = job.onFinish] job in
            previous?(job)
            self?.notifyNow()
        }
        job.start()
        notify()
        startTicking()
    }

    private func startNextArchiveJob() {
        let archiveJobs = prioritizedJobs.compactMap { $0 as? ArchiveJob }
        // Opening an archive to browse is something you're waiting on: it doesn't queue behind a long Extract.
        for job in archiveJobs where job.isBrowse && job.state == .queued { job.start(on: self) }
        guard !archiveJobs.contains(where: { !$0.isBrowse && ($0.state == .running || $0.state == .scanning) }),
              let next = archiveJobs.first(where: { !$0.isBrowse && $0.state == .queued }) else { return }
        next.start(on: self)
        startTicking()
    }

    /// Overall progress of every unfinished job, weighted by size, or nil when nothing is running.
    var overallProgress: Double? {
        let active = jobs.filter { $0.state.isActive }
        guard !active.isEmpty else { return nil }
        let total = active.reduce(0) { $0 + $1.totalWork }
        guard total > 0 else { return 0 }
        return min(1, active.reduce(0) { $0 + $1.completedWork } / total)
    }

    var hasActiveJobs: Bool { jobs.contains { $0.state.isActive } }

    var hasFailures: Bool { jobs.contains { $0.canRetry || $0.state == .failed } }

    var hasFinishedJobs: Bool { jobs.contains { !$0.state.isActive } }

    /// Removes finished, failed and cancelled jobs from the list.
    func clearFinished() {
        jobs.removeAll { !$0.state.isActive }
        let kept = Set(jobs.map(ObjectIdentifier.init))
        priority.removeAll { !kept.contains($0) }
        notify()
    }

    private var prioritizedJobs: [any QueueJob] {
        var remaining: [ObjectIdentifier: any QueueJob] = [:]
        for job in jobs { remaining[ObjectIdentifier(job)] = job }
        let ordered = priority.compactMap { remaining.removeValue(forKey: $0) }
        return ordered + jobs.filter { remaining[ObjectIdentifier($0)] != nil }
    }

    /// Running work stays visible first; waiting rows show the order the scheduler will use.
    var displayJobs: [any QueueJob] {
        jobs.filter { $0.state.isActive && $0.state != .queued }
            + prioritizedJobs.filter { $0.state == .queued }
            + jobs.reversed().filter { !$0.state.isActive }
    }

    private enum Lane: Equatable { case archives, disk(dev_t) }

    private func lane(of job: any QueueJob, waitingDisks: [ObjectIdentifier: dev_t]) -> Lane? {
        guard job.state == .queued else { return nil }
        if let archive = job as? ArchiveJob { return archive.isBrowse ? nil : .archives }
        guard job is TransferJob, let disk = waitingDisks[ObjectIdentifier(job)] else { return nil }
        return .disk(disk)
    }

    private func orderDestination(_ job: any QueueJob, _ order: TransferOrder) -> Int? {
        let jobs = prioritizedJobs
        var disks: [ObjectIdentifier: dev_t] = [:]
        for waiter in waiters { disks[waiter.job] = waiter.disk }
        guard let index = jobs.firstIndex(where: { $0 === job }), let lane = lane(of: job, waitingDisks: disks) else { return nil }
        return TransferOrdering.destination(for: index, among: jobs.indices.filter { self.lane(of: jobs[$0], waitingDisks: disks) == lane }, order: order)
    }

    func canReorder(_ job: any QueueJob, _ order: TransferOrder) -> Bool { orderDestination(job, order) != nil }

    /// Revalidate at dispatch: a menu may outlive the wait, cancellation or removal of its job.
    @discardableResult
    func reorder(_ job: any QueueJob, _ order: TransferOrder) -> Bool {
        var jobs = prioritizedJobs
        guard let target = orderDestination(job, order), let source = jobs.firstIndex(where: { $0 === job }) else { return false }
        let chosen = jobs.remove(at: source)
        jobs.insert(chosen, at: target)
        priority = jobs.map(ObjectIdentifier.init)
        notify()
        return true
    }

    func remove(_ job: any QueueJob) {
        guard !job.state.isActive else { return }
        jobs.removeAll { $0 === job }
        priority.removeAll { $0 == ObjectIdentifier(job) }
        notify()
    }

    /// For `applicationShouldTerminate`: asks before quitting while transfers run. Stopping them first removes
    /// partially written items and keeps every finished one, so nothing half-copied is left behind.
    func shouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        let active = jobs.filter { $0.state.isActive }
        guard !active.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = active.count == 1
            ? String(localized: "A copy or archive is still in progress")
            : String(localized: "\(active.count) jobs are still in progress", comment: "plural")
        alert.informativeText = String(localized: "Quitting stops them. Items already copied stay; the item being copied (or a half-made archive) is removed.")
        alert.addButton(withTitle: String(localized: "Stop and Quit", comment: "Quit alert button: stop the transfers and quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        // Return keeps the transfers going; stopping them takes a deliberate click.
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        active.forEach { $0.cancel() }
        Task {
            for job in active { await job.finished() }
            app.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Jobs

    func jobDidChange(_ job: TransferJob) {
        notify()
    }

    func jobDidFinish(_ job: TransferJob) {
        notifyNow()
        NotificationCenter.default.post(name: Self.jobDidFinishNotification, object: job)
        startTicking()
    }

    // MARK: - One writer per disk

    func isDiskFree(_ disk: dev_t, for job: TransferJob) -> Bool {
        busyDisks[disk] == nil || busyDisks[disk] == ObjectIdentifier(job)
    }

    /// Waits until no other job writes to `disk`. Returns false if the job was cancelled while waiting.
    func acquireDisk(_ disk: dev_t, for job: TransferJob) async -> Bool {
        if isDiskFree(disk, for: job) {
            busyDisks[disk] = ObjectIdentifier(job)
            return true
        }
        return await withCheckedContinuation { continuation in
            waiters.append((ObjectIdentifier(job), disk, continuation))
        }
    }

    func releaseDisk(_ disk: dev_t, for job: TransferJob) {
        guard busyDisks[disk] == ObjectIdentifier(job) else { return }
        busyDisks[disk] = nil
        // Read the current priority, including choices made after these jobs began waiting.
        let candidates = waiters.indices.filter { waiters[$0].disk == disk }
        var positions: [ObjectIdentifier: Int] = [:]
        for (index, job) in prioritizedJobs.enumerated() { positions[ObjectIdentifier(job)] = index }
        func priority(_ index: Int) -> Int { positions[waiters[index].job] ?? jobs.count }
        if let next = candidates.min(by: { priority($0) < priority($1) }) {
            let waiter = waiters.remove(at: next)
            busyDisks[disk] = waiter.job
            waiter.continuation.resume(returning: true)
        }
    }

    func stopWaiting(_ job: TransferJob) {
        let id = ObjectIdentifier(job)
        let stopped = waiters.filter { $0.job == id }
        waiters.removeAll { $0.job == id }
        stopped.forEach { $0.continuation.resume(returning: false) }
    }

    // MARK: - Updates

    /// Coalesces bursts of changes into one notification per run loop pass.
    private func notify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.notifyNow() }
        }
    }

    private func notifyNow() {
        notifyScheduled = false
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        onChange?()
    }

    private func startTicking() {
        guard ticker == nil, hasActiveJobs else { return }
        ticker = Task { [weak self] in
            while let self, self.hasActiveJobs {
                let now = ProcessInfo.processInfo.systemUptime
                for job in self.jobs where job.state.isActive { job.sample(now) }
                self.notifyNow()
                try? await Task.sleep(for: .milliseconds(250))
            }
            self?.ticker = nil
            self?.notifyNow()
        }
    }
}

/// Undo for finished transfers, with the same semantics as `FileOps`: undoing a copy moves the copies to the Trash;
/// undoing a move moves the items back. Items a job replaced come back out of the Trash. The work runs away from the
/// main thread after the undo and redo steps before it (`FileOps.afterUndoWork`); each step's redo is registered at
/// once, so it lands on the right stack, and waits for what the step did.
enum TransferUndo {
    /// Folders an operation made for its items (Put Back recreating a removed folder): made again before the items go
    /// back in, removed (only while empty) after they come out.
    typealias Containers = CreatedFolders.Change

    /// `containers`: folders made for the moved items; undo removes them once they're empty again, redo makes them.
    /// `landed`: what the items are where they went, recorded as each landed (else read now).
    static func register(created: [URL], moved: [TransferMove], replaced: [TransferMove], actionName: String,
                         undo: UndoManager?, logHistory: Bool = true, containers: CreatedFolders = CreatedFolders(), landed: LandedFiles? = nil,
                         queue: TransferQueue) {
        let landed = landed ?? LandedFiles(created + moved.map(\.to) + replaced.map(\.to))
        register(receipt: TransferJournal.Receipt(created: created, moved: moved, replaced: replaced, landed: landed),
                 actionName: actionName, undo: undo, logHistory: logHistory, containers: containers, queue: queue)
    }

    static func register(receipt: TransferJournal.Receipt, actionName: String, undo: UndoManager?, logHistory: Bool,
                         containers: CreatedFolders, queue: TransferQueue) {
        if logHistory {
            receipt.historyEntry = queue.history.recordTransfer(actionName, created: receipt.created,
                moved: receipt.moved.map { (from: $0.from, to: $0.to) },
                replaced: receipt.replaced.map { (from: $0.from, to: $0.to) }, containers: containers.urls,
                containerIdentities: containers.historyIdentities, landed: receipt.landed, updating: receipt.historyEntry)
        }
        guard let undo, !receipt.isEmpty, !receipt.undoRegistered else { return }
        receipt.undoRegistered = true
        undo.registerUndo(withTarget: undo) { undo in
            MainActor.assumeIsolated {
                receipt.wasUndone = true
                let removal: Containers = containers.urls.isEmpty ? .none : .remove(containers)
                // Redo runs these last first: it moves the items again, then puts the copies back.
                let trashed = Step()
                registerInverse(of: trashed, actionName: actionName, undo: undo, containers: .none, queue: queue,
                                historyEntry: nil)
                let owns = receipt.landed.owns, created = receipt.created
                let moved = receipt.moved, replaced = receipt.replaced
                perform(actionName: actionName, undo: undo, containers: removal, queue: queue,
                        historyEntry: receipt.historyEntry) {
                    // Each copy only while it's still the one the copy made, checked as it goes.
                    let (gone, identities, _) = await FileOps.trashForUndo(created, owns: owns, copies: queue.copies)
                    let inTrash = LandedFiles()
                    for (move, identity) in zip(gone, identities) { inTrash.set(identity, at: move.to) }
                    trashed.settle(.renamed(gone.map { TransferMove(from: $0.from, to: $0.to) }, inTrash))
                    let back = await movesBack(moved: moved, replaced: replaced, vacated: gone.map(\.from), owns: owns)
                    return (back, owns)
                }
                if let entry = receipt.historyEntry {
                    queue.history.setUndone(entry, true)
                    FileOps.registerLogMark(entry, undone: false, undo, history: queue.history)
                }
                undo.setActionName(OperationLog.displayName(actionName))
            }
        }
        undo.setActionName(OperationLog.displayName(actionName))
    }

    /// Moves `moves()` as an undo or redo step does: after the steps before, away from the main thread. The inverse is
    /// registered right away, so it lands on the right stack, and moves back what the step moved once that's known.
    /// `moves()` also says which items are still the ones it means (nil: any), asked just before each one moves.
    static func perform(actionName: String, undo: UndoManager?, containers: Containers = .none, queue: TransferQueue,
                        historyEntry: UUID? = nil,
                        moves: @escaping () async -> ([TransferMove], (@Sendable (URL) -> Bool)?)) {
        let step = Step()
        if let undo {
            registerInverse(of: step, actionName: actionName, undo: undo, containers: containers.inverse, queue: queue,
                            historyEntry: historyEntry)
        }
        FileOps.afterUndoWork {
            let (moving, owns) = await moves()
            step.settle(await start(moving, owns: owns, containers: containers, queue: queue,
                                    historyEntry: historyEntry))
        }
    }

    /// Moved items go back first, then whatever they replaced comes out of the Trash into the spots freed: by the
    /// copies gone to the Trash (`vacated`) or the items moved back, or never taken.
    @concurrent
    private static func movesBack(moved: [TransferMove], replaced: [TransferMove], vacated: [URL],
                                  owns: @Sendable (URL) -> Bool) async -> [TransferMove] {
        let returning = moved.filter { owns($0.to) }
        let freed = Set((vacated + returning.map(\.to)).map { $0.standardizedFileURL.path })
        let restoring = replaced.filter {
            owns($0.to) && (freed.contains($0.from.standardizedFileURL.path) || !TransferEngine.exists($0.from))
        }
        return returning.reversed().map(\.reversed) + restoring.reversed().map(\.reversed)
    }

    /// One step of undo or redo and what it moved: known at once for renames on one disk, once its job is done across
    /// disks. The step undoing it waits for that, so an undo or redo pressed meanwhile still moves exactly what landed.
    final class Step {
        fileprivate enum Outcome {
            case renamed([TransferMove], LandedFiles)
            case moving(TransferJob)
            case nothing
        }

        private var outcome: Outcome?
        private var waiters: [CheckedContinuation<Void, Never>] = []

        fileprivate func settle(_ outcome: Outcome) {
            self.outcome = outcome
            waiters.forEach { $0.resume() }
            waiters = []
        }

        /// What it moved that's still where it went (clashes may have renamed items on the way), and which items are
        /// those very ones, for checking again just before each moves back.
        func landed() async -> (moves: [TransferMove], owns: @Sendable (URL) -> Bool) {
            if outcome == nil { await withCheckedContinuation { waiters.append($0) } }
            switch outcome {
            case .renamed(let done, let landed):
                let still = Set(await landed.holding(done.map(\.to)))
                return (done.filter { still.contains($0.to) }, landed.owns)
            case .moving(let job):
                await job.finished()
                let still = Set(await job.landed.holding(job.completedMoves.map(\.to)))
                return (job.completedMoves.filter { still.contains($0.to) }, job.landed.owns)
            case .nothing, nil: return ([], { _ in false })
            }
        }
    }

    /// Registers undoing `step` (moving back what it moved, once that's known), with `containers` for those moves. The
    /// undo's own inverse is registered while it runs, so it lands on the right stack.
    private static func registerInverse(of step: Step, actionName: String, undo: UndoManager, containers: Containers,
                                        queue: TransferQueue, historyEntry: UUID?) {
        undo.registerUndo(withTarget: undo) { undo in
            MainActor.assumeIsolated {
                let next = Step()
                registerInverse(of: next, actionName: actionName, undo: undo, containers: containers.inverse, queue: queue, historyEntry: historyEntry)
                FileOps.afterUndoWork {
                    let (landed, owns) = await step.landed()
                    let back = landed.reversed().map(\.reversed)
                    next.settle(await start(back, owns: owns, containers: containers, queue: queue,
                                            historyEntry: historyEntry))
                }
            }
        }
        undo.setActionName(OperationLog.displayName(actionName))
    }

    /// Same-disk moves are renames, done away from the main thread; anything crossing disks becomes a queued job with
    /// progress.
    fileprivate static func start(_ moves: [TransferMove], owns: (@Sendable (URL) -> Bool)?, containers: Containers,
                                  queue: TransferQueue, historyEntry: UUID?) async -> Step.Outcome {
        guard !moves.isEmpty else { return .nothing }
        // Made first, so the destination's disk can be told (a missing folder has none).
        try? containers.prepare(continueAfterFailure: true)
        if let historyEntry { queue.history.updateContainerIdentities(historyEntry, containers.historyIdentities) }
        guard let (done, identities) = await renameOnOneDisk(moves, owns: owns) else {
            // Part of an undo or redo: History already has the operation.
            let job = queue.enqueue(moves: moves, mode: .move, undo: nil, conflicts: .keepBoth,
                                                   logHistory: false)
            job.onFinish = { _ in containers.finish() }
            return .moving(job)
        }
        let landed = LandedFiles()
        for (move, identity) in zip(done, identities) { landed.set(identity, at: move.to) }
        containers.finish()
        for folder in Set(done.flatMap { [$0.from, $0.to] }.map { $0.deletingLastPathComponent() }) {
            FolderSizer.invalidate(folder)
        }
        return .renamed(done, landed)
    }

    /// Renames each item still one `owns` means, checked just before it goes, unless they're on more than one disk
    /// (nil). An item is what it was before it went: on one disk a rename keeps it, so one put at the destination
    /// meanwhile is never taken for it.
    @concurrent
    private static func renameOnOneDisk(_ moves: [TransferMove], owns: (@Sendable (URL) -> Bool)?) async
        -> (done: [TransferMove], identities: [FileIdentity?])? {
        let oneDisk = moves.allSatisfy {
            TransferEngine.device($0.from) == TransferEngine.device($0.to.deletingLastPathComponent())
        }
        guard oneDisk else { return nil }
        var done: [TransferMove] = []
        var identities: [FileIdentity?] = []
        for move in moves {
            var target = TransferEngine.exists(move.to) ? FileOps.available(move.to, copyStyle: false) : move.to
            if let owns, !owns(move.from) { continue }
            for _ in 0..<64 {
                let identity = FileIdentity.read(move.from.path)
                let err = TransferEngine.rename(move.from, to: target)
                if err == 0 {
                    done.append(TransferMove(from: move.from, to: target))
                    identities.append(identity)
                    TransferEngine.hooks.afterLanding?(target)
                    break
                }
                guard err == EEXIST else { break }
                target = FileOps.available(move.to, copyStyle: false)
            }
        }
        return (done, identities)
    }
}
