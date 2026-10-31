import AppKit

/// One copy or move. It plans every top-level item, measures them, settles name conflicts up front, then hands the
/// items one at a time to its worker queue. Errors on one file never stop the rest; they can be retried afterwards.
final class TransferJob {
    let id = UUID()
    let mode: TransferMode
    let sources: [URL]
    /// The folder items go into (for undo jobs that restore to several places, the first one).
    let destination: URL
    /// The destination folder's name as Finder shows it, once read away from the main thread; its own name until then.
    private(set) var destinationName: String
    let options: TransferEngine.Options

    private(set) var state: TransferState = .queued
    /// Queued behind another transfer writing to the same disk.
    private(set) var isWaitingForDisk = false
    /// A conflict sheet is up and the job is waiting for the answer.
    private(set) var isAwaitingDecision = false
    private(set) var totalBytes: Int64 = 0
    private(set) var totalFiles = 0
    private(set) var completedBytes: Int64 = 0
    private(set) var completedFiles = 0
    private(set) var verifiedBytes: Int64 = 0
    private(set) var isVerifying = false
    private(set) var currentItemName: String?
    /// Bytes per second averaged over the last three seconds. Nil until there's a steady reading.
    private(set) var throughput: Double?
    private(set) var estimatedTimeRemaining: TimeInterval?
    private(set) var failures: [TransferFailure] = []
    /// A problem with the job as a whole (not enough space…). Retry runs it again.
    private(set) var errorMessage: String?
    /// Items that exist at the destination because of this job, in order. Handy for selecting them afterwards.
    private(set) var createdItems: [URL] = []
    /// Reading a container's items before they're copied (stopped with the job).
    private var containerFetch: Task<Void, Error>?
    private(set) var skippedCount = 0
    /// Top-level items done (moved, copied, or copied with some failures inside).
    private(set) var completedItems = 0

    /// Called on the main actor every time the job finishes a pass (including after a retry).
    var onFinish: ((TransferJob) -> Void)?

    private var items: [TransferItem]
    private var control = TransferControl()
    private let progress = TransferProgress()
    private let worker: TransferWorker
    private let resolver: ConflictResolver
    private weak var undoManager: UndoManager?
    /// False for jobs that are an undo or redo of something History already records.
    var logsHistory = true
    /// What History and the Edit menu call the job, when not "Copy" or "Move" ("Put Back").
    var actionName: String?
    /// Folders made for the job's items beforehand: undo removes them once they're empty again.
    var containers = CreatedFolders()
    /// Items moved so far, with where they actually landed (a clash may have renamed them).
    private(set) var completedMoves: [TransferMove] = []
    private weak var queue: TransferQueue?
    /// The queue's server and container copies, kept for the job's own lifetime.
    private let copies: CopyProviders
    private var rememberedDecision: ConflictDecision?
    /// Where this job has put items so far (lowercased paths): a later item of the job never replaces one of them.
    private var placed: Set<String> = []
    private var decisionTask: Task<ConflictResolution, Never>?
    private var heldDisk: dev_t?
    /// The disk a paused job gave up, to take back when it resumes.
    private var pausedDisk: dev_t?
    private var started = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var isRunningPass = false
    private var measured = false

    private let journal = TransferJournal()
    /// What each item is where it landed, recorded as it lands (for undo; see `LandedFiles`).
    let landed = LandedFiles()

    // Throughput: rates over a sliding window of recent samples.
    private var samples: [(time: TimeInterval, work: Double, bytes: Int64)] = []
    private var workRate: Double?
    private var runningSince: TimeInterval?
    private static let rateWindow: TimeInterval = 3

    /// Per-file overhead counted as this many bytes when estimating progress, so thousands of tiny files don't
    /// look finished while they're still being created.
    private static let fileWeight: Double = 64 * 1024

    /// `expected`: what each item must be, by its path (an undo's or redo's own items).
    init(mode: TransferMode, moves: [TransferMove], destination: URL, options: TransferEngine.Options,
         undo: UndoManager?, conflicts: ConflictResolver, queue: TransferQueue,
         expected: [String: FileIdentity]? = nil) {
        self.mode = mode
        self.sources = moves.map(\.from)
        self.destination = destination
        destinationName = destination.lastPathComponent
        self.options = options
        self.resolver = conflicts
        self.undoManager = undo
        self.queue = queue
        copies = queue.copies
        self.worker = TransferWorker(label: "dev.strata.transfer")
        self.items = moves.map {
            TransferItem(source: $0.from.standardizedFileURL, destination: $0.to, operation: .copy,
                         expected: expected?[$0.from.path])
        }
    }

    // MARK: - Derived values

    var canPause: Bool { state == .running }
    var canResume: Bool { state == .paused }
    var canCancel: Bool { state.isActive }
    var canRetry: Bool { queue != nil && (state == .finished || state == .failed) && (!failures.isEmpty || errorMessage != nil) }

    var totalWork: Double {
        Double(totalBytes) * (options.verify ? 2 : 1) + Double(totalFiles) * Self.fileWeight
    }

    var completedWork: Double {
        Double(completedBytes) + Double(verifiedBytes) + Double(completedFiles) * Self.fileWeight
    }

    /// 0…1, or nil while the size isn't known yet.
    var fractionCompleted: Double? {
        if state == .finished { return 1 }
        guard measured, state != .scanning else { return nil }
        guard totalWork > 0 else { return state.isActive ? nil : 1 }
        return min(1, completedWork / totalWork)
    }

    // MARK: - Control

    /// Stops at the next block. A paused job lets other transfers to the same disk go ahead.
    func pause() {
        guard canPause else { return }
        control.pause()
        state = .paused
        if let disk = heldDisk {
            heldDisk = nil
            pausedDisk = disk
            queue?.releaseDisk(disk, for: self)
        }
        resetRate()
        changed()
    }

    /// Carries on, after the disk is free again if another transfer took it meanwhile.
    func resume() {
        guard canResume else { return }
        Task {
            if let disk = pausedDisk, let queue {
                if !queue.isDiskFree(disk, for: self) {
                    isWaitingForDisk = true
                    state = .queued
                    changed()
                }
                let granted = await queue.acquireDisk(disk, for: self)
                isWaitingForDisk = false
                if granted {
                    pausedDisk = nil
                    heldDisk = disk
                }
                guard granted, !control.isCancelled else { return }
            }
            control.resume()
            state = .running
            runningSince = ProcessInfo.processInfo.systemUptime
            changed()
        }
    }

    func cancel() {
        guard canCancel else { return }
        control.cancel()
        decisionTask?.cancel()
        containerFetch?.cancel()
        queue?.stopWaiting(self)
        if !started { finish() } else { changed() }
    }

    /// Runs the failed parts again: whole items that failed, single files inside items, or removing originals.
    func retryFailed() {
        guard canRetry, let queue else { return }
        let previous = failures
        failures = []
        errorMessage = nil
        control = TransferControl()
        state = .scanning
        isRunningPass = true
        changed()
        Task {
            await runRetry(previous)
            withExtendedLifetime(queue) {}
        }
    }

    // MARK: - Running

    func start() {
        guard !started, let queue else { return }
        started = true
        isRunningPass = true
        // Keep the owner alive through completion, without a permanent queue → job → queue cycle.
        Task {
            await run()
            withExtendedLifetime(queue) {}
        }
    }

    /// Waits until the current pass (first run or a retry) is over: finished, failed or cancelled.
    func finished() async {
        guard isRunningPass else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }

    private func run() async {
        state = .scanning
        changed()
        let folder = destination
        destinationName = await worker.run { FileManager.default.displayName(atPath: folder.path) }
        // From a container's files: everything copied out is fetched first (folders with all they hold).
        let fromContainers = sources.filter(copies.contains)
        if !fromContainers.isEmpty {
            let fetch = Task {
                try await copies.prepareForCopying(fromContainers)
                guard !(await copies.containsPlaceholderOffMain(in: fromContainers)) else { throw CocoaError(.fileReadUnknown) }
            }
            containerFetch = fetch
            do {
                try await fetch.value
            } catch {
                errorMessage = fromContainers.first.map { copies.message(for: error, about: $0) } ?? error.localizedDescription
                return finish()
            }
        }
        await plan()
        await measure(items.indices.filter { items[$0].outcome == .pending })
        if !control.isCancelled { await resolveConflicts() }
        if !control.isCancelled, let problem = await spaceProblem() {
            errorMessage = problem
            return finish()
        }
        if !control.isCancelled {
            await execute(needsDisk: items.contains { $0.outcome == .pending && $0.operation != .rename }) {
                await self.performPending()
            }
        }
        finish()
    }

    private func runRetry(_ previous: [TransferFailure]) async {
        var entries: [Int: [TransferFailure]] = [:]
        var replanned: [Int] = []
        for failure in previous {
            switch failure.stage {
            case .item:
                items[failure.item].outcome = .pending
                items[failure.item].decision = nil
                replanned.append(failure.item)
            case .copy, .verify, .removeSource:
                entries[failure.item, default: []].append(failure)
            }
        }
        await plan(replanned)
        let pending = items.indices.filter { items[$0].outcome == .pending }
        progress.reset()
        totalBytes = 0
        totalFiles = 0
        await measure(pending)
        // Sizes of the individual files and folders being retried.
        let retrySources = entries.values.flatMap { $0 }.filter { $0.stage != .removeSource }.map(\.source)
        let control = control
        let sizes = await worker.run { retrySources.map { TransferEngine.scan($0, control: control) } }
        totalBytes = totalBytes.saturatingAdd(sizes.map { $0?.bytes ?? 0 }.saturatingSum)
        totalFiles += sizes.reduce(0) { $0 + ($1?.files ?? 0) }

        if !control.isCancelled, let problem = await spaceProblem() {
            errorMessage = problem
            failures += previous.filter { $0.stage != .item }
            return finish()
        }
        if !control.isCancelled {
            let needsDisk = !entries.isEmpty || items.contains { $0.outcome == .pending && $0.operation != .rename }
            await execute(needsDisk: needsDisk) {
                await self.performPending()
                for (index, list) in entries.sorted(by: { $0.key < $1.key }) {
                    if self.control.isCancelled {
                        self.failures += list
                        continue
                    }
                    let item = self.items[index]
                    let ownership = self.landed.identity(at: item.destination)
                    var options = self.options
                    options.sanitizeCopy = self.copies.contains(item.source)
                    options.sanitizationBoundary = self.sanitizationBoundary(for: item)
                    let control = self.control, progress = self.progress
                    let result = await self.worker.run { [options] in
                        TransferEngine.retry(index, item, landed: ownership, failures: list, options: options, control: control, progress: progress)
                    }
                    self.apply(result, to: index, isRetry: true)
                }
            }
        } else {
            failures += previous.filter { $0.stage != .item }
        }
        finish()
    }

    /// Waits for the destination disk if bytes need copying, then runs `body` in the running state.
    private func execute(needsDisk: Bool, _ body: () async -> Void) async {
        let destination = destination
        if needsDisk, let queue, let disk = await worker.run({ TransferEngine.device(destination) }) {
            if !queue.isDiskFree(disk, for: self) {
                isWaitingForDisk = true
                state = .queued
                changed()
            }
            let granted = await queue.acquireDisk(disk, for: self)
            isWaitingForDisk = false
            if granted { heldDisk = disk }
            guard granted, !control.isCancelled else { return }
        }
        state = control.isPaused ? .paused : .running
        runningSince = ProcessInfo.processInfo.systemUptime
        changed()
        await body()
    }

    private func performPending() async {
        // Indices, not a snapshot: merges append the copies they need while the job runs.
        var index = 0
        while index < items.count {
            defer { index += 1 }
            guard items[index].outcome == .pending else { continue }
            if control.isCancelled { break }
            guard await prepare(index) else { continue }
            let item = items[index], current = index
            var options = options
            options.sanitizeCopy = copies.contains(item.source)
            options.sanitizationBoundary = sanitizationBoundary(for: item)
            let control = control, progress = progress
            let result = await worker.run { [options] in
                TransferEngine.perform(current, item, options: options, control: control, progress: progress)
            }
            apply(result, to: current, isRetry: false)
        }
    }

    private func sanitizationBoundary(for item: TransferItem) -> URL {
        // A merge runs its children as separate items; links may still refer to siblings inside the chosen tree.
        items.first { parent in
            sources.contains(parent.source) && (parent.source == item.source || item.source.path.hasPrefix(parent.source.path + "/"))
        }?.destination ?? item.destination
    }

    // MARK: - Planning

    /// What planning needs to know of an item, read away from the main thread with every other item's.
    private nonisolated struct Facts: Sendable {
        let sourceExists: Bool
        let folderExists: Bool
        let inside: Bool
        let sameDisk: Bool
    }

    private func plan() async {
        await plan(Array(items.indices))
    }

    private func plan(_ indices: [Int]) async {
        let places = indices.map { (source: items[$0].source, destination: items[$0].destination) }, moving = mode == .move
        let facts = await worker.run { places.map { Self.facts($0.source, $0.destination, moving: moving) } }
        for (index, facts) in zip(indices, facts) { planItem(index, facts) }
    }

    nonisolated private static func facts(_ source: URL, _ destination: URL, moving: Bool) -> Facts {
        let folder = destination.deletingLastPathComponent()
        return Facts(sourceExists: TransferEngine.exists(source), folderExists: TransferEngine.exists(folder),
                     inside: isInside(folder.standardizedFileURL.path, source.path),
                     sameDisk: moving && TransferEngine.device(source) == TransferEngine.device(folder))
    }

    /// Checks an item can be transferred at all and picks how: rename, copy, or copy then delete.
    private func planItem(_ index: Int, _ facts: Facts) {
        let item = items[index]
        let source = item.source
        let parent = source.deletingLastPathComponent().standardizedFileURL.path
        let folder = item.destination.deletingLastPathComponent().standardizedFileURL.path
        let sameFolder = parent == folder
        if !facts.sourceExists {
            fail(index, String(localized: "The item couldn’t be found"))
        } else if !facts.folderExists {
            fail(index, String(localized: "The destination folder couldn’t be found"))
        } else if facts.inside {
            fail(index, mode == .copy ? String(localized: "A folder can’t be copied into itself")
                : String(localized: "A folder can’t be moved into itself"))
        } else if mode == .move, sameFolder, item.destination.lastPathComponent == source.lastPathComponent {
            items[index].outcome = .done   // Already there.
            placed.insert(item.destination.standardizedFileURL.path.lowercased())
        } else if mode == .copy {
            items[index].operation = .copy
            items[index].copyStyleName = sameFolder && item.destination.lastPathComponent == source.lastPathComponent
        } else {
            items[index].operation = facts.sameDisk ? .rename : .copyThenDelete
        }
    }

    private func measure(_ indices: [Int]) async {
        let renames = indices.filter { items[$0].operation == .rename }
        for index in renames {
            items[index].bytes = 0
            items[index].files = 1
        }
        let copies = indices.filter { items[$0].operation != .rename }
        let urls = copies.map { items[$0].source }
        let control = control
        let sizes = await worker.run { urls.map { TransferEngine.scan($0, control: control) } }
        for (index, size) in zip(copies, sizes) {
            items[index].bytes = size?.bytes ?? 0
            items[index].files = max(1, size?.files ?? 1)
        }
        totalBytes = totalBytes.saturatingAdd(indices.map { items[$0].bytes }.saturatingSum)
        totalFiles += indices.reduce(0) { $0 + items[$1].files }
        measured = true
        changed()
    }

    /// Asks about every name clash before any byte moves, so a long copy never stalls halfway on a question.
    private func resolveConflicts() async {
        let candidates = items.indices.filter { items[$0].outcome == .pending && !items[$0].copyStyleName }
        let destinations = candidates.map { items[$0].destination }
        let taken = await worker.run { destinations.map(TransferEngine.exists) }
        let clashes = zip(candidates, taken).filter(\.1).map(\.0)
        for (position, index) in clashes.enumerated() {
            guard !control.isCancelled else { return }
            let decision = await decide(index, remaining: clashes.count - position)
            if decision == .merge { await merge(index) } else { apply(decision, to: index) }
        }
    }

    /// Replaces a folder-onto-folder item by the copies its merge needs (appended, so they run after it). A "merge"
    /// applied to all that meets two files settles them the same way: the newer wins.
    private func merge(_ index: Int) async {
        let item = items[index]
        guard TransferEngine.isPlainFolder(item.source), TransferEngine.isPlainFolder(item.destination) else {
            let incoming = try? item.source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let existing = try? item.destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let newer = (incoming ?? .distantPast) > (existing ?? .distantPast)
            apply(newer ? .replace : .skip, to: index)
            return
        }
        let control = control
        let steps = await worker.run { TransferEngine.mergePlan(item.source, into: item.destination) }
        let sizes = await worker.run { steps.map { TransferEngine.scan($0.source, control: control) } }
        // The folder is already there: the item itself is done; its contents follow as their own items.
        items[index].outcome = .done
        totalBytes = max(0, totalBytes.saturatingAdd(-item.bytes))
        totalFiles -= item.files
        for (step, size) in zip(steps, sizes) {
            var sub = TransferItem(source: step.source, destination: step.destination, operation: .copy)
            sub.decision = step.decision
            sub.bytes = size?.bytes ?? 0
            sub.files = max(1, size?.files ?? 1)
            items.append(sub)
            totalBytes = totalBytes.saturatingAdd(sub.bytes)
            totalFiles += sub.files
        }
        changed()
    }

    private func decide(_ index: Int, remaining: Int) async -> ConflictDecision {
        if let rememberedDecision { return rememberedDecision }
        let conflict = TransferConflict(mode: mode, source: items[index].source, existing: items[index].destination,
                                        remaining: remaining)
        isAwaitingDecision = true
        changed()
        let resolver = resolver
        let task = Task { await resolver.resolve(conflict) }
        decisionTask = task
        let answer = await task.value
        decisionTask = nil
        isAwaitingDecision = false
        if control.isCancelled { return .stop }
        if answer.applyToAll, answer.decision != .stop { rememberedDecision = answer.decision }
        return answer.decision
    }

    private func apply(_ decision: ConflictDecision, to index: Int) {
        let item = items[index]
        switch decision {
        case .replace:
            let existing = item.destination.standardizedFileURL.path
            if Self.isInside(item.source.path, existing) {
                fail(index, String(localized: "“\(item.destination.lastPathComponent)” can’t be replaced by an item inside it"))
            } else {
                items[index].decision = .replace
            }
        case .keepBoth:
            items[index].decision = .keepBoth
        case .skip:
            items[index].decision = .skip
            items[index].outcome = .skipped
            skippedCount += 1
            totalBytes = max(0, totalBytes.saturatingAdd(-item.bytes))
            totalFiles -= item.files
        case .stop:
            cancel()
        case .merge:
            // Expanded by `merge(_:)` before it gets here; settle as keep-both if not.
            items[index].decision = .keepBoth
        }
        changed()
    }

    /// Picks the final name right before writing, and catches clashes that appeared since planning
    /// (another app, or two sources with the same name). Returns false when the item shouldn't be written.
    private func prepare(_ index: Int) async -> Bool {
        let item = items[index]
        // Two of the job's own items with one name (from different folders, say): the later one goes beside the one
        // this job just put there, whatever was decided for the name; replacing it would trash one of your originals.
        let placedByThisJob = placed.contains(item.destination.standardizedFileURL.path.lowercased())
        // Checked away from the main thread: a copy to a slow disk waits for it between items, the window doesn't.
        let destination = item.destination
        let available = { (copyStyle: Bool) in await self.worker.run { FileOps.available(destination, copyStyle: copyStyle) } }
        if item.copyStyleName {
            items[index].destination = await available(true)
        } else if item.decision == .keepBoth || placedByThisJob {
            items[index].decision = .keepBoth
            items[index].destination = await available(false)
        } else if item.decision == .replace {
            if !(await worker.run { TransferEngine.exists(destination) }) { items[index].decision = nil }
        } else if await worker.run({ TransferEngine.exists(destination) }) {
            let decision = await decide(index, remaining: 1)
            if decision == .merge {
                await merge(index)
                return false
            }
            apply(decision, to: index)
            if items[index].decision == .keepBoth {
                items[index].destination = await available(false)
            }
        }
        return items[index].outcome == .pending && !control.isCancelled
    }

    /// Bytes that will really land on the destination disk (clones on the same APFS volume are free), read away from
    /// the main thread.
    private func spaceProblem() async -> String? {
        let destination = destination, clone = options.clone
        let copies = items.filter { $0.outcome == .pending && $0.operation != .rename }.map { (source: $0.source, bytes: $0.bytes) }
        guard let (needed, available, volumeName) = await worker.run({
            Self.space(on: destination, clone: clone, copies: copies)
        }), needed > available else { return nil }
        let need = Format.bytes(needed), have = Format.bytes(available)
        guard let volume = volumeName else {
            return String(localized: "Not enough space on the disk: \(need) needed, \(have) available")
        }
        return String(localized: "Not enough space on “\(volume)”: \(need) needed, \(have) available")
    }

    /// The bytes `copies` need on `destination`'s disk and what it has, if it says.
    nonisolated private static func space(on destination: URL, clone: Bool, copies: [(source: URL, bytes: Int64)])
        -> (needed: Int64, available: Int64, volumeName: String?)? {
        guard let disk = TransferEngine.device(destination) else { return nil }
        let values = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                               .volumeAvailableCapacityKey,
                                                               .volumeSupportsFileCloningKey, .volumeNameKey])
        // "Important usage" counts purgeable space on the startup disk but reads 0 on many other volumes.
        let available = max(values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeAvailableCapacity ?? 0))
        guard available > 0 else { return nil }
        let clones = clone && (values?.volumeSupportsFileCloning ?? false)
        let needed = copies.filter { !(clones && TransferEngine.device($0.source) == disk) }.map(\.bytes).saturatingSum
        return (needed, available, values?.volumeName)
    }

    /// Whether `folder` is `item` or inside it, comparing real paths: a symlink can make a folder look like it's
    /// elsewhere, and copying a folder into itself recurses until names get too long. The item itself isn't
    /// resolved (moving or copying a symlink moves or copies the link, not what it points to).
    nonisolated static func isInside(_ folder: String, _ item: String) -> Bool {
        isInside(resolvedFolder: realPath(folder), item)
    }

    /// `isInside` with `folder` already resolved by `realPath` (resolve it once when testing many items).
    nonisolated static func isInside(resolvedFolder folder: String, _ item: String) -> Bool {
        let parent = (item as NSString).deletingLastPathComponent
        let name = (item as NSString).lastPathComponent
        let resolved = parent == item ? item : (realPath(parent) as NSString).appendingPathComponent(name)
        return folder == resolved || folder.hasPrefix(resolved == "/" ? "/" : resolved + "/")
    }

    /// The path with symlinks resolved (or standardized, if it doesn't exist).
    nonisolated static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Results

    private func fail(_ index: Int, _ message: String) {
        items[index].outcome = .failed
        failures.append(TransferFailure(item: index, stage: .item, source: items[index].source,
                                        destination: items[index].destination, message: message))
    }

    private func apply(_ result: TransferItemResult, to index: Int, isRetry: Bool) {
        items[index].outcome = result.outcome
        items[index].destination = result.destination
        failures += result.failures
        switch result.outcome {
        case .done, .partial:
            placed.insert(result.destination.standardizedFileURL.path.lowercased())
            // Both the first pass and retries carry ownership captured by the worker.
            landed.set(result.landed, at: result.destination)
            if let replaced = result.replaced { landed.set(result.replacedIdentity, at: replaced.to) }
            // A move whose original couldn't be (or wasn't) removed leaves the only complete copy at the destination:
            // undo must not trash it.
            let originalKept = mode == .move && result.failures.contains { $0.stage == .removeSource }
            if result.sourceRemoved {
                completedMoves.append(TransferMove(from: items[index].source, to: result.destination))
            }
            if !isRetry {
                completedItems += 1
                createdItems.append(result.destination)
            }
            journal.append(result, source: items[index].source, originalKept: originalKept)
        case .cancelled:
            items[index].outcome = .pending
        case .pending, .failed, .skipped:
            break
        }
        changed()
    }

    private func finish() {
        if let disk = heldDisk {
            queue?.releaseDisk(disk, for: self)
            heldDisk = nil
        }
        pausedDisk = nil
        isWaitingForDisk = false
        queue?.stopWaiting(self)
        sample(ProcessInfo.processInfo.systemUptime)
        resetRate()
        currentItemName = nil
        isVerifying = false
        isAwaitingDecision = false
        if control.isCancelled {
            state = .cancelled
        } else if errorMessage != nil || (!failures.isEmpty && completedItems == 0) {
            state = .failed
        } else {
            state = .finished
        }
        registerUndo()
        FolderSizer.invalidate(destination)
        for source in Set(sources.map { $0.deletingLastPathComponent() }) { FolderSizer.invalidate(source) }
        changed()
        queue?.jobDidFinish(self)
        isRunningPass = false
        onFinish?(self)
        let waiters = finishWaiters
        finishWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func registerUndo() {
        guard let queue else { return }
        journal.finish(actionName: actionName ?? (mode == .copy ? "Copy" : "Move"), undo: undoManager,
                       logHistory: logsHistory, containers: containers, queue: queue)
    }

    // MARK: - Progress

    /// Pulls the worker's counters and updates throughput and time left. Called a few times a second by the queue.
    func sample(_ now: TimeInterval) {
        let snapshot = progress.snapshot
        completedBytes = snapshot.bytes
        completedFiles = snapshot.files
        verifiedBytes = snapshot.verifiedBytes
        isVerifying = snapshot.isVerifying
        if state.isActive { currentItemName = snapshot.currentName }
        guard state == .running else {
            resetRate()
            return
        }
        let work = completedWork
        let bytes = completedBytes + verifiedBytes
        if let last = samples.last, now - last.time < 0.1 { return }
        samples.append((now, work, bytes))
        while samples.count > 2, now - samples[0].time > Self.rateWindow { samples.removeFirst() }
        if let first = samples.first, now - first.time >= 0.5 {
            let dt = now - first.time
            workRate = (work - first.work) / dt
            throughput = Double(bytes - first.bytes) / dt
        }
        // Give the estimate a moment to settle before showing it.
        if let since = runningSince, now - since >= 1.5, let rate = workRate, rate > 1 {
            estimatedTimeRemaining = max(0, (totalWork - work) / rate)
        } else {
            estimatedTimeRemaining = nil
        }
    }

    private func resetRate() {
        samples = []
        workRate = nil
        throughput = nil
        estimatedTimeRemaining = nil
        runningSince = state == .running ? ProcessInfo.processInfo.systemUptime : nil
    }

    private func changed() {
        queue?.jobDidChange(self)
    }
}
