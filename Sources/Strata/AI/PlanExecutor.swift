import AppKit

/// Applies the enabled steps of a validated plan as one undoable action ("AI Rename").
///
/// Renames and moves go through `FileOps.move` one pair at a time (so a failure part-way still knows exactly what happened).
/// New folders and Trash are coordinated here so per-item failures and the plan's ordering stay part of one action.
/// Undo restores Trash items, reverses moves and removes only the plan's own empty folders; redo applies it again.
enum PlanExecutor {
    struct Outcome {
        var applied = 0
        var failures: [String] = []
        /// Where the changed items are now (for selecting them afterwards).
        var results: [URL] = []
    }

    /// `actionName` is the English name History records (and translates when it shows it); the Edit menu shows
    /// `undoName` when given ("Rename 3 Items"), else that translation.
    static func apply(_ plan: Plan, actionName: String, undoName: String? = nil, undo: UndoManager?,
                      copies: CopyProviders, history: OperationLog) async -> Outcome {
        // Nothing inside an archive opened as a folder changes (a temporary copy).
        let touched = plan.steps.flatMap { [$0.source, $0.destination].compactMap { $0 } }
        guard !touched.contains(where: { ReadOnlyCopies.contains($0, copies: copies) }) else {
            return Outcome(failures: [FileOps.insideArchiveError.localizedDescription])
        }
        let transaction = PlanTransaction(plan: plan, copies: copies)
        let outcome = await transaction.perform()
        // One History entry for the whole plan, named like its undo action.
        let entry = transaction.hasChanges ? transaction.record(actionName, history: history) : nil
        if let undo, transaction.hasChanges {
            transaction.registerUndo(undo, actionName: undoName ?? OperationLog.displayName(actionName))
            if let entry { FileOps.registerLogMark(entry, undone: true, undo, history: history) }
        }
        return outcome
    }

    /// "AI Rename", "AI Move", "AI Organize", "AI Trash". English identifiers: History saves them and picks icons by
    /// them; `OperationLog.displayName` translates them for display.
    static func actionName(for plan: Plan) -> String {
        let kinds = Set(plan.enabledSteps.map(\.kind)).subtracting([.createFolder])
        if kinds == [.rename] { return "AI Rename" }
        if kinds == [.trash] { return "AI Move to Trash" }
        if kinds == [.move] { return plan.enabledSteps.contains { $0.kind == .createFolder } ? "AI Organize" : "AI Move" }
        return "AI Changes"
    }
}

final class PlanTransaction {
    typealias Pair = (from: URL, to: URL)

    private let folders: [URL]
    private let moves: [Pair]
    private let copies: CopyProviders
    private let trashItems: [URL]
    private var created: [URL] = []
    private var done: [Pair] = []
    private var trashed: [Pair] = []
    /// What `perform` left where, and what `revert` put back: undo and redo each touch only those very items, never
    /// one put in an item's place since. Nil before the first undo: the plan first runs on the items it was checked
    /// against.
    private var applied = LandedFiles()
    private var createdFolders = CreatedFolders()
    private var restored: LandedFiles?
    private var queue: Task<Void, Never>?

    init(plan: Plan, copies: CopyProviders) {
        self.copies = copies
        let enabled = plan.enabledSteps
        let moves = enabled.compactMap { step -> Pair? in
            guard step.kind == .rename || step.kind == .move, let from = step.source, let to = step.destination else { return nil }
            return (from, to)
        }
        folders = Self.needed(enabled.filter { $0.kind == .createFolder }.compactMap(\.destination), by: moves)
        self.moves = moves
        trashItems = enabled.filter { $0.kind == .trash }.compactMap(\.source)
    }

    /// Of `folders`, only those `moves` need (outermost first, as given).
    private static func needed(_ folders: [URL], by moves: [Pair]) -> [URL] {
        let needed = Set(moves.map { PlanValidator.key($0.to.deletingLastPathComponent()) })
        return folders.filter { folder in
            needed.contains { $0 == PlanValidator.key(folder) || $0.hasPrefix(PlanValidator.key(folder) + "/") }
        }
    }

    var hasChanges: Bool { !created.isEmpty || !done.isEmpty || !trashed.isEmpty }

    func record(_ name: String, history: OperationLog) -> UUID? {
        // In the order `perform` did them (Trash first), so undoing from History reverses them correctly.
        history.recordPlan(name, moved: (trashed + done).map { (from: $0.from, to: $0.to) }, containers: created,
                           containerIdentities: createdFolders.historyIdentities, landed: applied)
    }

    func perform() async -> PlanExecutor.Outcome {
        var outcome = PlanExecutor.Outcome()
        created = []
        done = []
        trashed = []
        applied = LandedFiles()
        createdFolders = CreatedFolders()
        // Redone: only what undo put back, still there.
        let moves = restored.map { restored in self.moves.filter { restored.holds($0.from) } } ?? self.moves
        let trashItems = restored.map { restored in self.trashItems.filter { restored.identity(at: $0) != nil } }
            ?? self.trashItems
        let folders = restored == nil ? self.folders : Self.needed(self.folders, by: moves)
        let fm = FileManager.default
        for folder in folders where !fm.fileExists(atPath: folder.path) {
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: false)
                created.append(folder)
                createdFolders.record([folder])
            } catch {
                outcome.failures.append(String(localized: "Couldn’t create “\(folder.lastPathComponent)”: \(error.localizedDescription)"))
            }
        }
        // Trash first: a plan may rename something into a name it frees ("trash X, rename Y to X").
        for url in trashItems {
            do {
                // Redone: only the very item undo put back, checked as it goes.
                switch try await Self.trash(url, expecting: restored?.identity(at: url)) {
                case .alreadyInTrash:
                    outcome.failures.append(String(localized: "“\(url.lastPathComponent)” is already in the Trash."))
                case let .trashed(result, identity):
                    trashed.append((url, result))
                    applied.set(identity, at: result)
                case .gone:
                    break
                }
            } catch {
                outcome.failures.append(String(localized: "“\(url.lastPathComponent)” couldn’t be moved to the Trash: \(error.localizedDescription)"))
            }
        }
        // Redone, the Trash steps above waited: what undo put back is checked again before it moves.
        let movable = restored.map { restored in moves.filter { restored.holds($0.from) } } ?? moves
        if FileOps.isChain(movable.map { (from: $0.from, to: $0.to) }) {
            // Swaps and chains move together, through temporary names, so they're checked before they start.
            for pair in movable { applied.expect(pair.from, at: pair.to) }
            let (moved, error) = await FileOps.moveAll(movable.map { (from: $0.from, to: $0.to) })
            let arrivedPaths = Set(moved.map(\.to.path))
            for pair in movable where !arrivedPaths.contains(pair.to.path) { applied.set(nil, at: pair.to) }
            for pair in moved where applied.identity(at: pair.to) == nil { applied.record([pair.to]) }
            moved.forEach { applied.arrived($0.to) }
            done = moved.map { ($0.from, $0.to) }
            outcome.results += moved.map(\.to)
            if let error { outcome.failures.append(error.localizedDescription) }
        } else {
            for pair in movable {
                // Each one waits for the one before: checked again as it goes.
                if let restored, !restored.holds(pair.from) { continue }
                do {
                    applied.expect(pair.from, at: pair.to)
                    try await Self.move(pair, copies: copies)
                    applied.arrived(pair.to)
                    done.append(pair)
                    outcome.results.append(pair.to)
                } catch {
                    applied.set(nil, at: pair.to)
                    outcome.failures.append(String(localized: "“\(pair.from.lastPathComponent)”: \(error.localizedDescription)",
                                                   comment: "An item’s name, then why it couldn’t be renamed or moved"))
                }
            }
        }
        outcome.applied = done.count + trashed.count
        return outcome
    }

    func revert() async {
        // The reverse of `perform`: moves back first (freeing names), then the Trash. Only items still where it put
        // them; what's back is recorded as it lands, for redo.
        let restored = LandedFiles()
        self.restored = restored
        func moveBack(_ pairs: [Pair]) async {
            for pair in pairs { restored.expect(pair.from, at: pair.to) }
            let moved: [Pair]
            if FileOps.isChain(pairs) {
                moved = await FileOps.moveAll(pairs).done.map { ($0.from, $0.to) }
            } else {
                var done: [Pair] = []
                for pair in pairs where (try? await Self.move(pair, copies: copies)) != nil { done.append(pair) }
                moved = done
            }
            let arrived = Set(moved.map(\.to.path))
            for pair in pairs {
                if arrived.contains(pair.to.path) { restored.arrived(pair.to) } else { restored.set(nil, at: pair.to) }
            }
        }
        await moveBack(done.filter { applied.holds($0.to) }.reversed().map { (from: $0.to, to: $0.from) })
        await moveBack(trashed.reversed().filter { applied.holds($0.to) }.map { (from: $0.to, to: $0.from) })
        // A name alone does not belong to the plan: the user may have replaced its folder while it was applied.
        createdFolders.removeEmpty()
    }

    nonisolated enum Trashed: Sendable {
        case alreadyInTrash
        /// Where it went, and what it is there, read as it landed.
        case trashed(URL, FileIdentity?)
        case gone
    }

    /// One item to the Trash, away from the main thread, and only if it's still `expecting` when given. One already in
    /// a Trash isn't: trashing it again would lose where it came from.
    @concurrent static func trash(_ url: URL, expecting: FileIdentity?) async throws -> Trashed {
        if let expecting, FileIdentity.read(url.path) != expecting { return .gone }
        if Trash.isInTrash(url) || Trash.isInTrash(url.resolvingSymlinksInPath()) { return .alreadyInTrash }
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let landed = result as URL? else { return .gone }
        return .trashed(landed, FileIdentity.read(landed.path))
    }

    /// Case-only renames ("photo.jpg" → "Photo.jpg") go through a temporary name on case-insensitive volumes.
    private static func move(_ pair: Pair, copies: CopyProviders) async throws {
        func move(_ from: URL, to: URL) async throws {
            try await FileOps.moveAsPart([(from: from, to: to)], copies: copies)
        }
        if pair.from.path != pair.to.path, pair.from.path.lowercased() == pair.to.path.lowercased() {
            let temporary = pair.from.deletingLastPathComponent().appending(path: ".strata-rename-\(UUID().uuidString)")
            try await move(pair.from, to: temporary)
            do {
                try await move(temporary, to: pair.to)
            } catch {
                // Never leave the item under its hidden temporary name.
                try? await move(temporary, to: pair.from)
                throw error
            }
        } else {
            try await move(pair.from, to: pair.to)
        }
    }

    // MARK: - Undo

    /// One undo step for the whole plan. Each handler registers its opposite synchronously, so redo works too.
    /// The undo manager is the target (it doesn't retain targets); the closure keeps the transaction alive.
    func registerUndo(_ undo: UndoManager, actionName: String) {
        undo.registerUndo(withTarget: undo) { [self] undo in
            MainActor.assumeIsolated {
                registerRedo(undo, actionName: actionName)
                enqueue { await self.revert() }
            }
        }
        undo.setActionName(actionName)
    }

    private func registerRedo(_ undo: UndoManager, actionName: String) {
        undo.registerUndo(withTarget: undo) { [self] undo in
            MainActor.assumeIsolated {
                registerUndo(undo, actionName: actionName)
                enqueue { _ = await self.perform() }
            }
        }
        undo.setActionName(actionName)
    }

    /// Runs file work in order even if the user presses ⌘Z ⇧⌘Z quickly.
    /// In the order pressed, after any other undo or redo step before it (`FileOps.undoWork`).
    private func enqueue(_ work: @escaping () async -> Void) {
        queue = FileOps.afterUndoWork { [self] in
            await work()
            NotificationCenter.default.post(name: .planTransactionDidFinish, object: self)
        }
    }

    /// Waits for queued undo/redo work (for tests).
    func waitForIdle() async {
        await queue?.value
    }
}

extension Notification.Name {
    /// Posted after an undo or redo of an AI plan has finished moving files.
    static let planTransactionDidFinish = Notification.Name("StrataPlanTransactionDidFinish")
}
