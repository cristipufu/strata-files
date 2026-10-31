import CryptoKit
import Foundation

/// The blocking work behind transfers. Everything here runs on a job's worker queue.
nonisolated enum TransferEngine {
    struct Options: Sendable {
        var verify = false
        /// APFS clones when source and destination share a volume. Tests turn it off to get real byte copies.
        var clone = true
        var sanitizeCopy = false
        var sanitizationBoundary: URL?
    }

    /// Test-only knobs: throttle data copies and tamper with a copy before it's verified.
    struct Hooks: Sendable {
        var throttleBytesPerSecond: Int64?
        var beforeVerify: (@Sendable (URL) -> Void)?
        /// Report a controlled failure after copyfile finishes an entry, while its descriptor is still available.
        var copyFailure: (@Sendable (URL) -> Int32?)?
        /// Called with an item's place the moment it has landed there and been recorded (for undo), before anything
        /// else happens to it: a test swaps the file right then.
        var afterLanding: (@Sendable (URL) -> Void)?
        /// The worker has finished, before its result is applied on the main actor.
        var afterResult: (@Sendable (TransferItemResult) -> Void)?
    }

    private static let hooksLock = NSLock()
    nonisolated(unsafe) private static var storedHooks = Hooks()

    // Workers read snapshots while tests configure hooks. Keep field updates atomic too; callbacks run after
    // the getter has released the lock, so they may safely update the configuration themselves.
    static var hooks: Hooks {
        get { hooksLock.withLock { storedHooks } }
        set { hooksLock.withLock { storedHooks = newValue } }
        _modify {
            hooksLock.lock()
            defer { hooksLock.unlock() }
            yield &storedHooks
        }
    }

    // MARK: - Items

    /// Carries out one planned item: rename, or copy (+ verify) (+ remove the original), with "replace" done
    /// safely by copying under a temporary name and only then swapping the old item into the Trash.
    static func perform(_ index: Int, _ item: TransferItem, options: Options, control: TransferControl,
                        progress: TransferProgress) -> TransferItemResult {
        let result = performItem(index, item, options: options, control: control, progress: progress)
        hooks.afterResult?(result)
        return result
    }

    private static func performItem(_ index: Int, _ item: TransferItem, options: Options, control: TransferControl,
                                    progress: TransferProgress) -> TransferItemResult {
        var attempt = ItemAttempt(index: index, item: item, options: options, control: control, progress: progress)
        return attempt.run()
    }

    /// One item, phase by phase: each phase either finishes the item, returning its result, or lets the next one run.
    private struct ItemAttempt {
        let index: Int
        let item: TransferItem
        let options: Options
        let control: TransferControl
        let progress: TransferProgress
        let replacing: Bool
        var result: TransferItemResult

        init(index: Int, item: TransferItem, options: Options, control: TransferControl, progress: TransferProgress) {
            self.index = index
            self.item = item
            self.options = options
            self.control = control
            self.progress = progress
            replacing = item.decision == .replace
            result = TransferItemResult(outcome: .failed, destination: item.destination)
        }

        mutating func run() -> TransferItemResult {
            guard control.checkpoint() else { return finish(.cancelled) }
            progress.update { $0.currentName = item.source.lastPathComponent }
            // Read once, just before it goes: an undo or redo never takes what has taken its item's place, and a
            // rename keeps what the item is.
            let identity = item.expected != nil || item.operation == .rename ? FileIdentity.read(item.source.path) : nil
            guard item.means(identity) else { return fail(changedSince) }
            var operation = item.operation
            if operation == .rename {
                if let renamed = renameInPlace(keeping: identity) { return renamed }
                operation = .copyThenDelete
            }
            // Copy into place, or next to it under a hidden temporary name when replacing.
            let sourceParent = TransferRetryTarget.directoryIdentity(item.source.deletingLastPathComponent())
            let target = replacing ? temporaryURL(for: item.destination) : item.destination
            let copy = copy(item.source, to: target, clone: options.clone, control: control, progress: progress)
            if let ended = land(copy, at: target) { return ended }
            var failures = copyFailures(copy, at: target)
            if options.verify, let ended = verify(copy, at: target, failures: &failures) { return ended }
            if options.sanitizeCopy, let ended = finishCopyingOut(copy, at: target) { return ended }
            if replacing, let ended = replaceExisting(with: copy, at: target, failures: failures) { return ended }
            guard failures.isEmpty else {
                result.failures = failures
                return finish(.partial)
            }
            if operation == .copyThenDelete, let ended = removeOriginal(copied: copy, sourceParent: sourceParent) {
                return ended
            }
            return finish(.done)
        }

        private mutating func finish(_ outcome: TransferItem.Outcome) -> TransferItemResult {
            result.outcome = outcome
            return result
        }

        private mutating func fail(_ message: String, stage: TransferFailure.Stage = .item) -> TransferItemResult {
            result.failures.append(TransferFailure(item: index, stage: stage, source: item.source,
                                                   destination: item.destination, message: message))
            return finish(.failed)
        }

        /// A rename on the item's own disk; nil when it's on another, to copy there and remove the original instead.
        private mutating func renameInPlace(keeping identity: FileIdentity?) -> TransferItemResult? {
            var trashed: URL?
            if replacing {
                result.replacedIdentity = FileIdentity.read(item.destination.path)
                do { trashed = try trash(item.destination) } catch { return fail(trashMessage(item.destination, error)) }
            }
            let code = rename(item.source, to: item.destination)
            if code == 0 {
                result.landed = identity
                hooks.afterLanding?(item.destination)
                if let trashed { result.replaced = TransferMove(from: item.destination, to: trashed) }
                progress.update {
                    $0.files += item.files
                    $0.bytes += item.bytes
                }
                result.sourceRemoved = true
                return finish(.done)
            }
            if let trashed { _ = rename(trashed, to: item.destination) }
            guard code == EXDEV, !replacing else { return fail(describe(code)) }
            return nil
        }

        /// The copy is in place (or next to it): kept and recorded, unless it was stopped, failed whole, or isn't of
        /// the item meant.
        private mutating func land(_ copy: CopyOutcome, at target: URL) -> TransferItemResult? {
            result.created = copy.created
            if copy.cancelled {
                removeIfPresent(target, in: target, created: copy.created)
                return finish(.cancelled)
            }
            if let fatal = copy.fatal {
                if !copy.destinationExisted { removeIfPresent(target, in: target, created: copy.created) }
                return fail(fatal)
            }
            // Swapped in the moment before the copy began: what was copied isn't the item meant, and its copy goes.
            guard item.means(copy.sourceIdentities[item.source.path]) else {
                removeIfPresent(target, in: target, created: copy.created)
                return fail(changedSince)
            }
            if copy.cloned {
                progress.update {
                    $0.files += item.files
                    $0.bytes += item.bytes
                }
            }
            result.landed = copy.created[target.path] ?? FileIdentity.read(target.path)
            hooks.afterLanding?(target)
            return nil
        }

        private func copyFailures(_ copy: CopyOutcome, at target: URL) -> [TransferFailure] {
            copy.errors.map { error in
                let errorURL = URL(fileURLWithPath: error.destination)
                return TransferFailure(item: index, stage: .copy, source: URL(fileURLWithPath: error.source),
                                       destination: replacing ? nil : errorURL, message: error.message,
                                       retryTarget: TransferRetryTarget(errorURL, identity: error.identity,
                                                                        root: target, created: copy.created,
                                                                        source: item.source, sourceIdentities: copy.sourceIdentities))
            }
        }

        private mutating func verify(_ copy: CopyOutcome, at target: URL,
                                     failures: inout [TransferFailure]) -> TransferItemResult? {
            hooks.beforeVerify?(target)
            let skip = Set(copy.errors.map(\.source))
            let check = TransferEngine.verify(item.source, against: target, created: copy.created, skipping: skip,
                                              control: control, progress: progress)
            if check.cancelled {
                removeIfPresent(target, in: target, created: copy.created)
                return finish(.cancelled)
            }
            for mismatch in check.mismatches {
                // A bad copy is worse than none: drop it so a retry starts clean.
                let mismatchURL = URL(fileURLWithPath: mismatch.destination)
                removeIfPresent(mismatchURL, in: target, created: copy.created)
                let remaining = FileIdentity.read(mismatch.destination) == mismatch.identity ? mismatch.identity : nil
                failures.append(TransferFailure(item: index, stage: .verify, source: URL(fileURLWithPath: mismatch.source),
                                                destination: replacing ? nil : mismatchURL,
                                                message: mismatch.message,
                                                retryTarget: TransferRetryTarget(mismatchURL, identity: remaining,
                                                                                 root: target, created: copy.created,
                                                                                 source: item.source, sourceIdentities: copy.sourceIdentities)))
            }
            return nil
        }

        /// A copy from a server's or container's files is finished like anything copied out of one.
        private mutating func finishCopyingOut(_ copy: CopyOutcome, at target: URL) -> TransferItemResult? {
            let boundary = options.sanitizationBoundary == item.destination ? target : options.sanitizationBoundary ?? target
            do {
                try ContainerCopies.finishCopyingOut(boundary, owned: copy.created)
                guard !replacing || FileIdentity.read(target.path) == result.landed else { throw CocoaError(.fileReadCorruptFile) }
            }
            catch {
                removeIfPresent(target, in: target, created: copy.created)
                return fail(error.localizedDescription)
            }
            return nil
        }

        /// The complete copy, made under a temporary name, takes the existing item's place; that one goes to the Trash.
        private mutating func replaceExisting(with copy: CopyOutcome, at target: URL,
                                              failures: [TransferFailure]) -> TransferItemResult? {
            // Never swap a complete existing item for an incomplete one.
            guard failures.isEmpty else {
                removeIfPresent(target, in: target, created: copy.created)
                result.failures = failures.map {
                    TransferFailure(item: index, stage: .item, source: item.source, destination: item.destination,
                                    message: "\($0.displayName): \($0.message)")
                }
                return result
            }
            let trashed: URL
            result.replacedIdentity = FileIdentity.read(item.destination.path)
            do { trashed = try trash(item.destination) } catch {
                removeIfPresent(target, in: target, created: copy.created)
                return fail(trashMessage(item.destination, error))
            }
            let code = rename(target, to: item.destination)
            guard code == 0 else {
                _ = rename(trashed, to: item.destination)
                removeIfPresent(target, in: target, created: copy.created)
                return fail(describe(code))
            }
            result.replaced = TransferMove(from: item.destination, to: trashed)
            result.created = Dictionary(uniqueKeysWithValues: copy.created.map { path, identity in
                (item.destination.path + path.dropFirst(target.path.count), identity)
            })
            return nil
        }

        /// A move across disks: the original goes once its copy is complete, unless it changed while being copied.
        private mutating func removeOriginal(copied copy: CopyOutcome, sourceParent: TransferRetryTarget.PathIdentity?) -> TransferItemResult? {
            let removeRetry = TransferRetryTarget(item.destination, identity: result.landed, root: item.destination,
                                                  created: copy.created, source: item.source,
                                                  sourceIdentities: copy.sourceIdentities)
            // Anything saved into the original while it was being copied isn't in the copy: keep the original then.
            if let change = changedSinceCopy(item.source, copy: item.destination) {
                let message = String(localized: "Copied, but the original was kept because it changed during the move (\(change))")
                result.failures.append(TransferFailure(item: index, stage: .removeSource, source: item.source,
                                                       destination: item.destination, message: message,
                                                       retryTarget: removeRetry))
                return finish(.partial)
            }
            if let message = removeSource(item.source, destination: item.destination, landed: result.landed,
                                          sourceParent: sourceParent, sourceIdentities: copy.sourceIdentities) {
                result.failures.append(TransferFailure(item: index, stage: .removeSource, source: item.source,
                                                       destination: item.destination, message: message,
                                                       retryTarget: removeRetry))
                return finish(.partial)
            }
            result.sourceRemoved = true
            return nil
        }
    }

    /// Second attempt at the parts of an item that failed: individual files and folders, or removing the original.
    static func retry(_ index: Int, _ item: TransferItem, landed: FileIdentity?, failures: [TransferFailure], options: Options,
                      control: TransferControl, progress: TransferProgress) -> TransferItemResult {
        var result = retryItems(index, item, landed: landed, failures: failures, options: options, control: control, progress: progress)
        sanitize(&result, options: options, index: index, source: item.source)
        hooks.afterResult?(result)
        return result
    }

    private static func sanitize(_ result: inout TransferItemResult, options: Options, index: Int, source: URL) {
        guard options.sanitizeCopy else { return }
        do { try ContainerCopies.finishCopyingOut(options.sanitizationBoundary ?? result.destination, owned: result.created) }
        catch {
            result.outcome = .failed
            result.failures.append(TransferFailure(item: index, stage: .item, source: source,
                                                   destination: result.destination, message: error.localizedDescription))
        }
    }

    private static func retryItems(_ index: Int, _ item: TransferItem, landed: FileIdentity?, failures: [TransferFailure],
                                   options: Options, control: TransferControl, progress: TransferProgress) -> TransferItemResult {
        var attempt = RetryAttempt(index: index, item: item, landed: landed, failures: failures, options: options,
                                   control: control, progress: progress)
        return attempt.run()
    }

    /// A retry, phase by phase like `ItemAttempt`: each failed part is copied again where it's still what the first
    /// attempt left, then the original of a move goes.
    private struct RetryAttempt {
        let index: Int
        let item: TransferItem
        let landed: FileIdentity?
        let failures: [TransferFailure]
        let options: Options
        let control: TransferControl
        let progress: TransferProgress
        var result: TransferItemResult
        var latestSourceParent: TransferRetryTarget.PathIdentity?
        var latestSourceIdentities: [String: FileIdentity]

        init(index: Int, item: TransferItem, landed: FileIdentity?, failures: [TransferFailure], options: Options,
             control: TransferControl, progress: TransferProgress) {
            self.index = index
            self.item = item
            self.landed = landed
            self.failures = failures
            self.options = options
            self.control = control
            self.progress = progress
            result = TransferItemResult(outcome: .done, destination: item.destination, landed: landed)
            latestSourceParent = failures.lazy.compactMap { $0.retryTarget?.sourceParent }.first
            latestSourceIdentities = failures.lazy.compactMap { $0.retryTarget?.sourceIdentities }.first { !$0.isEmpty } ?? [:]
        }

        mutating func run() -> TransferItemResult {
            // Not the item it means, or not readable just now: nothing is touched, and what's left to repair stays as
            // it was for the next retry.
            guard item.means(FileIdentity.read(item.source.path)) else {
                result.failures = failures
                return finish(landed == nil ? .failed : .partial)
            }
            for failure in retryFailures(failures) {
                guard control.checkpoint() else { return finish(.cancelled) }
                guard let destination = failure.destination else { continue }
                if let ended = repair(failure, at: destination) { return ended }
            }
            guard result.failures.isEmpty else { return finish(.partial) }
            if item.operation != .copy, let ended = removeOriginal() { return ended }
            return result
        }

        private mutating func finish(_ outcome: TransferItem.Outcome) -> TransferItemResult {
            result.outcome = outcome
            return result
        }

        /// The part's retry target while its place, and what it was copied from, are still the first attempt's.
        private func target(of failure: TransferFailure, at destination: URL) -> TransferRetryTarget? {
            let sameRoot = destination == item.destination || (landed != nil && FileIdentity.read(item.destination.path) == landed)
            guard sameRoot, let retryTarget = failure.retryTarget, retryTarget.matches(destination) else { return nil }
            return retryTarget.matchesSource(failure.source) ? retryTarget : nil
        }

        /// Copies one failed part again (a folder in place, keeping what it holds); nil unless it was stopped.
        private mutating func repair(_ failure: TransferFailure, at destination: URL) -> TransferItemResult? {
            progress.update { $0.currentName = failure.source.lastPathComponent }
            guard let retryTarget = target(of: failure, at: destination) else {
                result.failures.append(TransferFailure(item: index, stage: failure.stage, source: failure.source,
                                                       destination: destination, message: changedSince,
                                                       retryTarget: failure.retryTarget))
                return nil
            }
            let owned = retryTarget.createdIdentities(for: destination, root: item.destination, rootIdentity: result.landed)
            var dstInfo = stat()
            let keepingDirectory = lstat(destination.path, &dstInfo) == 0 && (dstInfo.st_mode & S_IFMT == S_IFDIR)
            if !keepingDirectory {
                removeIfPresent(destination, in: item.destination, created: owned)
            }
            let copy = copy(failure.source, to: destination, replacingOwned: keepingDirectory ? owned : nil,
                            clone: options.clone, control: control, progress: progress)
            result.created.merge(copy.created) { _, new in new }
            var mergedCreated = owned
            for (path, id) in copy.created { mergedCreated[path] = id }
            if copy.cancelled {
                removeIfPresent(destination, in: item.destination, created: mergedCreated, keepRootDirectory: keepingDirectory)
                return finish(.cancelled)
            }
            if let fatal = copy.fatal {
                result.failures.append(TransferFailure(item: index, stage: .copy, source: failure.source,
                                                       destination: destination, message: fatal, retryTarget: failure.retryTarget))
                return nil
            }
            for (path, id) in copy.sourceIdentities { latestSourceIdentities[path] = id }
            if latestSourceParent == nil {
                latestSourceParent = TransferRetryTarget.directoryIdentity(item.source.deletingLastPathComponent())
            }
            // Recreating a top-level file gives it a new identity. Repairing a child keeps the original folder's
            // ownership; never adopt whichever folder happens to occupy that path after the retry.
            if destination == item.destination { result.landed = copy.created[destination.path] ?? FileIdentity.read(destination.path) }
            hooks.afterLanding?(destination)
            result.failures += copy.errors.map {
                let errorURL = URL(fileURLWithPath: $0.destination)
                return TransferFailure(item: index, stage: .copy, source: URL(fileURLWithPath: $0.source),
                                       destination: errorURL, message: $0.message,
                                       retryTarget: TransferRetryTarget(errorURL, identity: $0.identity,
                                                                        root: item.destination, created: mergedCreated,
                                                                        source: item.source, sourceIdentities: latestSourceIdentities))
            }
            guard options.verify else { return nil }
            return verify(failure, copy, at: destination, created: mergedCreated, keepingDirectory: keepingDirectory)
        }

        private mutating func verify(_ failure: TransferFailure, _ copy: CopyOutcome, at destination: URL,
                                     created mergedCreated: [String: FileIdentity], keepingDirectory: Bool) -> TransferItemResult? {
            hooks.beforeVerify?(destination)
            let check = TransferEngine.verify(failure.source, against: destination, created: copy.created,
                                              skipping: Set(copy.errors.map(\.source)), control: control, progress: progress)
            if check.cancelled {
                removeIfPresent(destination, in: item.destination, created: mergedCreated, keepRootDirectory: keepingDirectory)
                return finish(.cancelled)
            }
            for mismatch in check.mismatches {
                let mismatchURL = URL(fileURLWithPath: mismatch.destination)
                removeIfPresent(mismatchURL, in: item.destination, created: mergedCreated)
                let remaining = FileIdentity.read(mismatch.destination) == mismatch.identity ? mismatch.identity : nil
                result.failures.append(TransferFailure(item: index, stage: .verify,
                                                       source: URL(fileURLWithPath: mismatch.source),
                                                       destination: mismatchURL,
                                                       message: mismatch.message,
                                                       retryTarget: TransferRetryTarget(mismatchURL, identity: remaining,
                                                                                        root: item.destination, created: mergedCreated,
                                                                                        source: item.source, sourceIdentities: latestSourceIdentities)))
            }
            return nil
        }

        /// The original of a move goes once every part is repaired, unless its copy or the original changed since.
        private mutating func removeOriginal() -> TransferItemResult? {
            let removeRetry = failures.lazy.compactMap(\.retryTarget).first
            if (result.landed != nil && FileIdentity.read(item.destination.path) != result.landed)
                || (removeRetry != nil && removeRetry?.matchesSource(item.source) == false) {
                result.failures.append(TransferFailure(item: index, stage: .removeSource, source: item.source,
                                                       destination: item.destination,
                                                       message: changedSince,
                                                       retryTarget: removeRetry))
                return finish(.partial)
            }
            // The original may hold edits the copy lacks (that's why it was kept): never delete it then.
            if let change = changedSinceCopy(item.source, copy: item.destination) {
                let message = String(localized: "The original was kept because it changed during the move (\(change)). Move it again to copy the changes.")
                result.failures.append(TransferFailure(item: index, stage: .removeSource, source: item.source,
                                                       destination: item.destination, message: message,
                                                       retryTarget: removeRetry))
                return finish(.partial)
            }
            if let message = removeSource(item.source, destination: item.destination, landed: result.landed,
                                          sourceParent: latestSourceParent, sourceIdentities: latestSourceIdentities) {
                result.failures.append(TransferFailure(item: index, stage: .removeSource, source: item.source,
                                                       destination: item.destination, message: message,
                                                       retryTarget: removeRetry))
                return finish(.partial)
            }
            result.sourceRemoved = true
            return nil
        }
    }

    /// A failed folder's retry includes its descendants. Retrying them separately could remove files the parent
    /// has just repaired, and descendants may not have had a destination parent to record on the first attempt.
    static func retryFailures(_ failures: [TransferFailure]) -> [TransferFailure] {
        let candidates = failures.filter { ($0.stage == .copy || $0.stage == .verify) && $0.destination != nil }
        let destinations = Dictionary(candidates.compactMap { failure in
            failure.destination.map { (failure.source.path, $0.path) }
        }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        return candidates.filter { failure in
            guard let destination = failure.destination,
                  seen.insert(failure.source.path + "\0" + destination.path).inserted else { return false }
            var parent = failure.source.deletingLastPathComponent()
            while parent.path != failure.source.path {
                if let target = destinations[parent.path] {
                    let relative = String(failure.source.path.dropFirst(parent.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if (target as NSString).appendingPathComponent(relative) == destination.path { return false }
                }
                let next = parent.deletingLastPathComponent()
                if next.path == parent.path { break }
                parent = next
            }
            return true
        }
    }

    // MARK: - Scanning

    /// Files and bytes under `url` (one cheap walk, no xattrs), or nil when cancelled.
    static func scan(_ url: URL, control: TransferControl) -> FolderSize? {
        FolderSizer.measure(url.path) { control.isCancelled }
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    static func device(_ url: URL) -> dev_t? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_dev : nil
    }

    // MARK: - Copying

    struct EntryError: Sendable {
        let source: String
        let destination: String
        let message: String
        var identity: FileIdentity?
    }

    struct CopyOutcome: Sendable {
        var errors: [EntryError] = []
        var cancelled = false
        /// Nothing could be copied at all.
        var fatal: String?
        /// The copy was refused because something already sits at the destination: that item isn't ours to remove.
        var destinationExisted = false
        /// Made as one APFS clone of the whole item (no per-file progress was reported).
        var cloned = false
        var created: [String: FileIdentity] = [:]
        var sourceIdentities: [String: FileIdentity] = [:]
    }

    /// Recursive `copyfile(3)` with every piece of metadata, APFS clones where possible, per-file progress, and
    /// pause/cancel at block granularity. Files that fail are recorded and skipped; copyfile removes their partial data.
    static func copy(_ source: URL, to destination: URL, replacingOwned: [String: FileIdentity]? = nil,
                     clone: Bool, control: TransferControl, progress: TransferProgress) -> CopyOutcome {
        if let owned = replacingOwned {
            return copyfile(source, to: destination, replacingOwned: owned, clone: clone, control: control, progress: progress)
        }
        guard !exists(destination) else {
            // copyfile would copy *into* an existing folder; the planner guarantees this never happens.
            return CopyOutcome(fatal: describe(EEXIST), destinationExisted: true)
        }
        let start = progress.snapshot
        let first = copyfile(source, to: destination, clone: clone, control: control, progress: progress)
        // copyfile's per-file cloning keeps every ACL and xattr, but fails inside folders without write permission
        // (it clones a read-only folder before filling it). For a folder that hit errors, start over with one clone of
        // the whole tree, then with a plain copy, which both cope with that.
        var isDirectory: ObjCBool = false
        guard clone, !first.errors.isEmpty, !first.cancelled, first.fatal == nil,
              FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue,
              canRestart(destination, created: first.created)
        else { return first }
        removeIfPresent(destination, in: destination, created: first.created)   // Ours: COPYFILE_EXCL guaranteed nothing was there.
        guard !exists(destination) else { return first }
        progress.update {
            $0.files = start.files
            $0.bytes = start.bytes
        }
        if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW | CLONE_ACL)) == 0 {
            return CopyOutcome(cloned: true, created: snapshotIdentities(destination),
                               sourceIdentities: snapshotIdentities(source))
        }
        if errno == EEXIST { return CopyOutcome(fatal: describe(EEXIST), destinationExisted: true) }
        return copyfile(source, to: destination, clone: false, control: control, progress: progress)
    }

    /// File promises and clipboard staging use the same creation receipts as queued transfers.
    @discardableResult
    static func copyForExport(_ source: URL, to destination: URL, control: TransferControl = TransferControl()) throws -> [String: FileIdentity] {
        let copied = copy(source, to: destination, clone: true, control: control, progress: TransferProgress())
        do {
            guard copied.fatal == nil, copied.errors.isEmpty, !copied.cancelled else { throw CocoaError(.fileWriteUnknown) }
            try ContainerCopies.finishCopyingOut(destination, owned: copied.created)
            return copied.created
        } catch {
            removeIfPresent(destination, in: destination, created: copied.created)
            throw error
        }
    }

    /// One recursive `copyfile` pass (see `copy`).
    static func copyfile(_ source: URL, to destination: URL, replacingOwned: [String: FileIdentity]? = nil,
                         clone: Bool, control: TransferControl, progress: TransferProgress) -> CopyOutcome {
        if let owned = replacingOwned {
            return repairOwnedDirectory(source, to: destination, owned: owned, clone: clone, control: control, progress: progress)
        }

        let hooks = hooks
        let session = CopySession(control: control, progress: progress, throttle: hooks.throttleBytesPerSecond,
                                  copyFailure: hooks.copyFailure)
        if let id = FileIdentity.read(source.path) { session.sourceIdentities[source.path] = id }
        guard let state = copyfile_state_alloc() else { return CopyOutcome(fatal: describe(ENOMEM)) }
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = copyCallback
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(session).toOpaque())
        var flags = COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL
        if clone { flags |= COPYFILE_CLONE }
        let status = Darwin.copyfile(source.path, destination.path, state, copyfile_flags_t(flags))
        let code = errno
        withExtendedLifetime(session) {}

        var outcome = CopyOutcome(errors: session.errors, created: session.created,
                                  sourceIdentities: session.sourceIdentities)
        if session.quit || control.isCancelled {
            outcome.cancelled = true
        } else if status != 0, session.errors.isEmpty {
            outcome.fatal = describe(code)
            // Something appeared at the destination meanwhile (COPYFILE_EXCL refused): leave it alone.
            outcome.destinationExisted = code == EEXIST
        } else if !exists(destination), session.errors.contains(where: { $0.source == source.path }) {
            // The top-level item itself failed (unreadable file, folder that can't be listed…).
            outcome.fatal = session.errors.first { $0.source == source.path }?.message
            outcome.errors.removeAll { $0.source == source.path }
        }
        if !outcome.destinationExisted {
            let failedDestinations = Set(session.errors.map(\.destination))
            for (path, id) in snapshotIdentities(destination) where outcome.created[path] == nil && !failedDestinations.contains(path) {
                outcome.created[path] = id
            }
            for (path, id) in snapshotIdentities(source) where outcome.sourceIdentities[path] == nil {
                outcome.sourceIdentities[path] = id
            }
        }
        return outcome
    }

    private static let copyCallback: copyfile_callback_t = { what, stage, state, source, destination, context in
        let code = errno
        guard let context else { return Int32(COPYFILE_CONTINUE) }
        let session = Unmanaged<CopySession>.fromOpaque(context).takeUnretainedValue()
        return session.handle(what: what, stage: stage, state: state, source: source, destination: destination, code: code)
    }

    // MARK: - Verifying

    struct VerifyOutcome: Sendable {
        var mismatches: [EntryError] = []
        var cancelled = false
    }

    /// SHA-256 of every regular file under `source` against its counterpart under `destination`, streamed in 1 MB
    /// chunks; symlinks must point at the same place. Paths in `skipping` (already failed) are left out.
    static func verify(_ source: URL, against destination: URL, created: [String: FileIdentity] = [:],
                       skipping: Set<String> = [], control: TransferControl,
                       progress: TransferProgress) -> VerifyOutcome {
        progress.update { $0.isVerifying = true }
        defer { progress.update { $0.isVerifying = false } }
        var outcome = VerifyOutcome()
        let root = source.path
        guard let cpath = strdup(root) else { return outcome }
        defer { free(cpath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return outcome }
        defer { fts_close(fts) }
        let buffers = (UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16),
                       UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16))
        defer {
            buffers.0.deallocate()
            buffers.1.deallocate()
        }
        while let entry = fts_read(fts) {
            let path = String(cString: entry.pointee.fts_path)
            if skipping.contains(path) {
                if Int32(entry.pointee.fts_info) == FTS_D { fts_set(fts, entry, FTS_SKIP) }
                continue
            }
            let relative = path.count > root.count ? String(path.dropFirst(root.count)) : ""
            let target = destination.path + relative
            let currentIdentity = FileIdentity.read(target)
            let expectedIdentity = created[target]
            let identity = expectedIdentity ?? currentIdentity
            if let expectedIdentity, currentIdentity != expectedIdentity {
                if Int32(entry.pointee.fts_info) == FTS_D { fts_set(fts, entry, FTS_SKIP) }
                let message = currentIdentity == nil
                    ? String(localized: "The copy can’t be read back")
                    : String(localized: "The copy doesn’t match the original")
                outcome.mismatches.append(EntryError(source: path, destination: target, message: message, identity: identity))
                continue
            }
            switch Int32(entry.pointee.fts_info) {
            case FTS_F:
                progress.update { $0.currentName = (path as NSString).lastPathComponent }
                let original = sha256(path, buffer: buffers.0, control: control) { n in
                    progress.update { $0.verifiedBytes += Int64(n) }
                }
                if control.isCancelled { outcome.cancelled = true; return outcome }
                let copy = sha256(target, expected: expectedIdentity, buffer: buffers.1, control: control) { _ in }
                if control.isCancelled { outcome.cancelled = true; return outcome }
                if original == nil || copy == nil || original != copy {
                    let reason = copy == nil ? String(localized: "The copy can’t be read back")
                        : String(localized: "The copy doesn’t match the original")
                    outcome.mismatches.append(EntryError(source: path, destination: target,
                                                         message: original == nil ? String(localized: "The original can’t be read") : reason,
                                                         identity: identity))
                }
            case FTS_SL, FTS_SLNONE:
                if readLink(path) != readLink(target) || (expectedIdentity != nil && FileIdentity.read(target) != expectedIdentity) {
                    outcome.mismatches.append(EntryError(source: path, destination: target,
                                                         message: String(localized: "The copied alias points somewhere else"), identity: identity))
                }
            default:
                break
            }
        }
        return outcome
    }

    static func sha256(_ path: String, expected: FileIdentity? = nil, buffer: UnsafeMutableRawBufferPointer,
                       control: TransferControl, onRead: (Int) -> Void) -> SHA256.Digest? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if let expected {
            var info = stat()
            guard fstat(fd, &info) == 0, FileIdentity.from(info) == expected else { return nil }
        }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        while true {
            guard control.checkpoint() else { return nil }
            let n = read(fd, buffer.baseAddress, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<n]))
            onRead(n)
        }
        return hasher.finalize()
    }

    private static func readLink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink(path, &buffer, buffer.count - 1)
        guard n >= 0 else { return nil }
        return String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Small operations

    /// `rename(2)` that refuses to overwrite. Returns 0 or an errno.
    static func rename(_ source: URL, to destination: URL, supportsExclusiveRename: Bool = true) -> Int32 {
        if !supportsExclusiveRename { errno = ENOTSUP } else
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return 0 }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else { return code }
        // File systems without RENAME_EXCL: claim the name with an exclusive placeholder, then replace only that.
        var srcInfo = stat()
        guard lstat(source.path, &srcInfo) == 0 else { return errno }
        let isFolder = (srcInfo.st_mode & S_IFMT) == S_IFDIR
        let placeholderIdentity: FileIdentity?
        if isFolder {
            if mkdir(destination.path, 0o700) != 0 { return errno }
            placeholderIdentity = FileIdentity.read(destination.path)
        } else {
            let fd = open(destination.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            if fd < 0 { return errno }
            var dstInfo = stat()
            placeholderIdentity = fstat(fd, &dstInfo) == 0 ? FileIdentity.from(dstInfo) : nil
            close(fd)
        }
        if Darwin.rename(source.path, destination.path) == 0 { return 0 }
        let error = errno
        if let placeholderIdentity, FileIdentity.read(destination.path) == placeholderIdentity {
            if isFolder { rmdir(destination.path) } else { unlink(destination.path) }
        }
        return error
    }

    static func trash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }

    static func removeIfPresent(_ url: URL, in root: URL? = nil, created: [String: FileIdentity]? = nil,
                                keepRootDirectory: Bool = false) {
        guard let created else {
            guard exists(url) else { return }
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard !created.isEmpty, let dirFD = openOwnedParent(of: url, in: root ?? url, created: created) else { return }
        defer { close(dirFD) }
        removeOwned(url, in: dirFD, created: created, keepRootDirectory: keepRootDirectory)
    }

    /// The folder `url` is in, opened from `base`'s folder down without following links, each folder below `base`'s
    /// one the operation made (`created`); nil when one isn't, or `url` isn't inside `base`.
    private static func openOwnedParent(of url: URL, in base: URL, created: [String: FileIdentity]) -> Int32? {
        let baseParent = base.deletingLastPathComponent().path
        var dirFD = open(baseParent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dirFD >= 0 else { return nil }
        guard url.path != base.path else { return dirFD }
        let prefix = base.path == "/" ? "/" : base.path + "/"
        guard url.path.hasPrefix(prefix) else {
            close(dirFD)
            return nil
        }
        let relativeParent = String(url.deletingLastPathComponent().path.dropFirst(baseParent.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var currentPath = baseParent
        for component in relativeParent.split(separator: "/").map(String.init) {
            currentPath = (currentPath as NSString).appendingPathComponent(component)
            guard let expected = created[currentPath] else {
                close(dirFD)
                return nil
            }
            let nextFD = openat(dirFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(dirFD)
            guard nextFD >= 0 else { return nil }
            var info = stat()
            guard fstat(nextFD, &info) == 0, FileIdentity.from(info) == expected else {
                close(nextFD)
                return nil
            }
            dirFD = nextFD
        }
        return dirFD
    }

    /// Removes `url` from its open folder `dirFD` while it's the item the operation made: a file or link directly, a
    /// folder through `removeOwnedTree`.
    private static func removeOwned(_ url: URL, in dirFD: Int32, created: [String: FileIdentity], keepRootDirectory: Bool) {
        let targetName = url.lastPathComponent
        let targetPath = url.path
        guard let expectedTarget = created[targetPath] else { return }
        var targetInfo = stat()
        guard fstatat(dirFD, targetName, &targetInfo, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity.from(targetInfo) == expectedTarget else {
            return
        }
        if targetInfo.st_mode & S_IFMT != S_IFDIR {
            if !keepRootDirectory { _ = unlinkat(dirFD, targetName, 0) }
            return
        }
        let rootDirFD = openat(dirFD, targetName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDirFD >= 0 else { return }
        var openedInfo = stat()
        guard fstat(rootDirFD, &openedInfo) == 0, FileIdentity.from(openedInfo) == expectedTarget else {
            close(rootDirFD)
            return
        }
        removeOwnedTree(rootDirFD, named: targetName, at: targetPath, in: dirFD, created: created, keep: keepRootDirectory)
    }

    /// Removes what in the open folder `rootFD` the operation made, depth first, each folder opened without following
    /// links and checked against `created` before anything in it goes; then the folder itself, unless `keep`. Closes
    /// `rootFD`, never `dirFD`.
    private static func removeOwnedTree(_ rootFD: Int32, named name: String, at path: String, in dirFD: Int32,
                                        created: [String: FileIdentity], keep: Bool) {
        var stack: [(parentFD: Int32, fd: Int32, name: String, path: String, expanded: Bool, keep: Bool)] = [
            (parentFD: dirFD, fd: rootFD, name: name, path: path, expanded: false, keep: keep)
        ]
        while let frame = stack.popLast() {
            if !frame.expanded {
                let currentFD: Int32
                if frame.fd >= 0 {
                    currentFD = frame.fd
                } else {
                    let opened = openat(frame.parentFD, frame.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard opened >= 0 else { continue }
                    var openedChild = stat()
                    guard let expectedChild = created[frame.path],
                          fstat(opened, &openedChild) == 0, FileIdentity.from(openedChild) == expectedChild else {
                        close(opened)
                        continue
                    }
                    currentFD = opened
                }
                var dirInfo = stat()
                if !frame.keep, fstat(currentFD, &dirInfo) == 0, (dirInfo.st_mode & S_IRWXU) != S_IRWXU {
                    _ = fchmod(currentFD, (dirInfo.st_mode & 0o7777) | S_IRWXU)
                }
                stack.append((parentFD: frame.parentFD, fd: currentFD, name: frame.name,
                              path: frame.path, expanded: true, keep: frame.keep))
                let frame = (parentFD: frame.parentFD, fd: currentFD, name: frame.name, path: frame.path, expanded: false, keep: frame.keep)
                for childName in Archiver.entries(frame.fd) {
                    let childPath = (frame.path as NSString).appendingPathComponent(childName)
                    guard let expectedChild = created[childPath] else { continue }
                    var childInfo = stat()
                    guard fstatat(frame.fd, childName, &childInfo, AT_SYMLINK_NOFOLLOW) == 0,
                          FileIdentity.from(childInfo) == expectedChild else { continue }
                    if childInfo.st_mode & S_IFMT == S_IFDIR {
                        stack.append((parentFD: frame.fd, fd: -1, name: childName,
                                      path: childPath, expanded: false, keep: false))
                    } else {
                        _ = unlinkat(frame.fd, childName, 0)
                    }
                }
            } else {
                close(frame.fd)
                if !frame.keep { _ = unlinkat(frame.parentFD, frame.name, AT_REMOVEDIR) }
            }
        }
    }

    /// The first difference between `source` and its copy (an item added, or a file whose size or modification date
    /// changed after it was copied), or nil when the copy has everything the original has.
    static func changedSinceCopy(_ source: URL, copy: URL) -> String? {
        let root = source.path
        let unchecked = String(localized: "it couldn’t be checked", comment: "Why a moved item’s original was kept, in parentheses")
        guard let cpath = strdup(root) else { return unchecked }
        defer { free(cpath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return unchecked }
        defer { fts_close(fts) }
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_DP { continue }
            if info == FTS_DNR || info == FTS_ERR || info == FTS_NS { return unchecked }
            let path = String(cString: entry.pointee.fts_path)
            let relative = path.count > root.count ? String(path.dropFirst(root.count)) : ""
            let name = relative.isEmpty ? source.lastPathComponent : String(relative.dropFirst())
            var original = stat(), copied = stat()
            guard lstat(path, &original) == 0 else { continue }   // Removed meanwhile: nothing to lose.
            guard lstat(copy.path + relative, &copied) == 0,
                   original.st_mode & S_IFMT == copied.st_mode & S_IFMT else {
                return String(localized: "“\(name)” is new", comment: "Why a moved item’s original was kept, in parentheses")
            }
            // An edit after the copy makes the original newer. Some disks keep coarser dates (FAT: 2 seconds, nothing
            // before 1980), so only a clearly newer original, or a different size, counts.
            let (grace, overflow) = copied.st_mtimespec.tv_sec.addingReportingOverflow(2)
            if original.st_mode & S_IFMT == S_IFREG,
               original.st_size != copied.st_size || (!overflow && original.st_mtimespec.tv_sec > grace) {
                return String(localized: "“\(name)” was modified", comment: "Why a moved item’s original was kept, in parentheses")
            }
            if original.st_mode & S_IFMT == S_IFLNK, readLink(path) != readLink(copy.path + relative) {
                return String(localized: "“\(name)” was modified", comment: "Why a moved item’s original was kept, in parentheses")
            }
        }
        return nil
    }

    static var changedSince: String { String(localized: "The items have moved or been changed since.") }

    /// Removes the original after a cross-volume move. Returns an error message, or nil on success.
    private static func removeSource(_ url: URL, destination: URL? = nil, landed: FileIdentity? = nil,
                                     sourceParent: TransferRetryTarget.PathIdentity? = nil,
                                     sourceIdentities: [String: FileIdentity] = [:]) -> String? {
        if let destination, let landed, FileIdentity.read(destination.path) != landed {
            let reason = describe(EACCES)
            return String(localized: "Copied, but the original couldn’t be removed: \(reason)")
        }
        if let sourceParent, FileIdentity.read(sourceParent.path) != sourceParent.identity {
            let reason = describe(EACCES)
            return String(localized: "Copied, but the original couldn’t be removed: \(reason)")
        }
        let owned = sourceIdentities.isEmpty ? snapshotIdentities(url) : sourceIdentities
        guard let rootID = owned[url.path], FileIdentity.read(url.path) == rootID else {
            guard exists(url) else { return nil }
            let reason = describe(EACCES)
            return String(localized: "Copied, but the original couldn’t be removed: \(reason)")
        }
        for (path, expected) in owned {
            if let current = FileIdentity.read(path), current != expected {
                let reason = describe(EACCES)
                return String(localized: "Copied, but the original couldn’t be removed: \(reason)")
            }
        }
        removeIfPresent(url, in: url, created: owned)
        guard !exists(url) else {
            let reason = describe(EACCES)
            return String(localized: "Copied, but the original couldn’t be removed: \(reason)")
        }
        return nil
    }

    /// A folder that isn't a package (apps and bundles are replaced, never merged into).
    static func isPlainFolder(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        return (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true
    }

    /// One copy a merge needs: `decision` is nil (new item), `.replace` (incoming is newer) or `.keepBoth` (a file
    /// meets a folder).
    struct MergeStep: Sendable {
        let source: URL
        let destination: URL
        let decision: ConflictDecision?
    }

    /// What merging folder `source` into folder `destination` copies: everything missing, subfolders merged in turn,
    /// and same-named items only where the incoming one is newer.
    static func mergePlan(_ source: URL, into destination: URL) -> [MergeStep] {
        var steps: [MergeStep] = []
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []).sorted()
        for name in names where name != ".DS_Store" {
            let from = source.appending(path: name), to = destination.appending(path: name)
            var incoming = stat(), existing = stat()
            guard lstat(from.path, &incoming) == 0 else { continue }
            guard lstat(to.path, &existing) == 0 else {
                steps.append(MergeStep(source: from, destination: to, decision: nil))
                continue
            }
            let bothFolders = isPlainFolder(from) && isPlainFolder(to)
            if bothFolders {
                steps += mergePlan(from, into: to)
            } else if (incoming.st_mode & S_IFMT == S_IFDIR) != (existing.st_mode & S_IFMT == S_IFDIR) {
                steps.append(MergeStep(source: from, destination: to, decision: .keepBoth))
            } else if incoming.st_mtimespec.tv_sec > existing.st_mtimespec.tv_sec {
                steps.append(MergeStep(source: from, destination: to, decision: .replace))
            }
        }
        return steps
    }

    static func temporaryURL(for destination: URL) -> URL {
        let token = UUID().uuidString.prefix(8)
        // ".<name>.strata-XXXXXXXX" must stay within the 255-byte name limit.
        let name = fitting(destination.lastPathComponent, maxBytes: 255 - 17)
        return destination.deletingLastPathComponent().appending(path: ".\(name).strata-\(token)")
    }

    /// `name` cut (at a character boundary) to at most `maxBytes` of UTF-8.
    static func fitting(_ name: String, maxBytes: Int) -> String {
        guard name.utf8.count > maxBytes else { return name }
        var result = ""
        for character in name {
            guard result.utf8.count + String(character).utf8.count <= maxBytes else { break }
            result.append(character)
        }
        return result
    }

    static func describe(_ code: Int32) -> String {
        switch code {
        case EACCES, EPERM: String(localized: "You don’t have permission")
        case ENOENT: String(localized: "The item couldn’t be found")
        case ENOSPC: String(localized: "The disk is full")
        case EEXIST: String(localized: "An item with the same name already exists")
        case EROFS: String(localized: "The disk is read-only")
        case ENAMETOOLONG: String(localized: "The name is too long")
        case EXDEV: String(localized: "It’s on a different disk")
        default: String(cString: strerror(code))
        }
    }

    private static func trashMessage(_ url: URL, _ error: Error) -> String {
        String(localized: "“\(url.lastPathComponent)” couldn’t be moved to the Trash, so it wasn’t replaced")
    }
}
