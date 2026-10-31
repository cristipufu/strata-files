import CryptoKit
import Foundation

/// The blocking work behind transfers. Everything here runs on a job's worker queue.
package nonisolated enum TransferEngine {
    package struct Options: Sendable {
        package var verify = false
        /// APFS clones when source and destination share a volume. Tests turn it off to get real byte copies.
        package var clone = true
        package var sanitizeCopy = false
        package var sanitizationBoundary: URL?

        package init(verify: Bool = false, clone: Bool = true, sanitizeCopy: Bool = false, sanitizationBoundary: URL? = nil) {
            self.verify = verify
            self.clone = clone
            self.sanitizeCopy = sanitizeCopy
            self.sanitizationBoundary = sanitizationBoundary
        }
    }

    /// Test-only knobs: throttle data copies and tamper with a copy before it's verified.
    package struct Hooks: Sendable {
        package var throttleBytesPerSecond: Int64?
        package var beforeVerify: (@Sendable (URL) -> Void)?
        /// Report a controlled failure after copyfile finishes an entry, while its descriptor is still available.
        package var copyFailure: (@Sendable (URL) -> Int32?)?
        /// Called with an item's place the moment it has landed there and been recorded (for undo), before anything
        /// else happens to it: a test swaps the file right then.
        package var afterLanding: (@Sendable (URL) -> Void)?
        /// The worker has finished, before its result is applied on the main actor.
        package var afterResult: (@Sendable (TransferItemResult) -> Void)?
        /// A folder's merge is about to be read: a test holds it there and stops the job meanwhile.
        package var beforeMergePlan: (@Sendable (URL) -> Void)?
    }

    private static let hooksLock = NSLock()
    nonisolated(unsafe) private static var storedHooks = Hooks()

    // Workers read snapshots while tests configure hooks. Keep field updates atomic too; callbacks run after
    // the getter has released the lock, so they may safely update the configuration themselves.
    package static var hooks: Hooks {
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
    package static func perform(_ index: Int, _ item: TransferItem, options: Options, control: TransferControl,
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
            failures += dropMismatches(check.mismatches, item: index, root: target, created: copy.created,
                                       source: item.source, sourceIdentities: copy.sourceIdentities,
                                       showsDestination: !replacing)
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
                return finish(.failed)
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
    package static func retry(_ index: Int, _ item: TransferItem, landed: FileIdentity?, failures: [TransferFailure], options: Options,
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
        func target(of failure: TransferFailure, at destination: URL) -> TransferRetryTarget? {
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
            result.failures += dropMismatches(check.mismatches, item: index, root: item.destination, created: mergedCreated,
                                              source: item.source, sourceIdentities: latestSourceIdentities,
                                              showsDestination: true)
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

    /// A bad copy is worse than none: each part that failed to verify goes, so a retry starts clean, and becomes a
    /// failure that retry can repair. `showsDestination` is off while a replacement is still under its temporary name.
    private static func dropMismatches(_ mismatches: [EntryError], item index: Int, root: URL, created: [String: FileIdentity],
                                       source: URL, sourceIdentities: [String: FileIdentity],
                                       showsDestination: Bool) -> [TransferFailure] {
        mismatches.map { mismatch in
            let mismatchURL = URL(fileURLWithPath: mismatch.destination)
            removeIfPresent(mismatchURL, in: root, created: created)
            let remaining = FileIdentity.read(mismatch.destination) == mismatch.identity ? mismatch.identity : nil
            return TransferFailure(item: index, stage: .verify, source: URL(fileURLWithPath: mismatch.source),
                                   destination: showsDestination ? mismatchURL : nil, message: mismatch.message,
                                   retryTarget: TransferRetryTarget(mismatchURL, identity: remaining, root: root, created: created,
                                                                    source: source, sourceIdentities: sourceIdentities))
        }
    }

    /// A failed folder's retry includes its descendants. Retrying them separately could remove files the parent
    /// has just repaired, and descendants may not have had a destination parent to record on the first attempt.
    package static func retryFailures(_ failures: [TransferFailure]) -> [TransferFailure] {
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
}
