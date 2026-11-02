import Foundation
import os
import Synchronization

extension Notification.Name {
    package static let operationLogChanged = Notification.Name("StrataOperationLogChanged")
}

/// A journal of file operations that survives restarts, so any of them can be undone later from the History window
/// (the Edit menu's Undo only covers the current session).
package final class OperationLog {
    nonisolated private static let log = Logger(subsystem: "dev.strata.app", category: "history")
    /// An operation's name as History and the Edit menu show it. Entries keep the English name they were recorded
    /// with (it's saved, and History picks its icon by it); the known ones are translated here, anything else is shown
    /// as recorded.
    package nonisolated static func displayName(_ name: String) -> String {
        switch name {
        case "Copy": String(localized: "Copy", comment: "Undo and History action name: a copy")
        case "Move": String(localized: "Move", comment: "Undo and History action name: a move")
        case "Duplicate": String(localized: "Duplicate", comment: "Undo and History action name")
        case "Rename": String(localized: "Rename", comment: "Undo and History action name")
        case "Move to Trash": String(localized: "Move to Trash", comment: "Undo and History action name")
        case "New Folder": String(localized: "New Folder", comment: "Undo and History action name")
        case "New File": String(localized: "New File", comment: "Undo and History action name")
        case "Compress": String(localized: "Compress", comment: "Undo and History action name: making a zip")
        case "Extract": String(localized: "Extract", comment: "Undo and History action name: unpacking an archive")
        case "Put Back": String(localized: "Put Back", comment: "Undo and History action name: items taken out of the Trash")
        case "Sync": String(localized: "Sync", comment: "Undo and History action name: syncing two folders")
        case "AI Rename": String(localized: "AI Rename", comment: "Undo and History action name")
        case "AI Move": String(localized: "AI Move", comment: "Undo and History action name")
        case "AI Organize": String(localized: "AI Organize", comment: "Undo and History action name")
        case "AI Move to Trash": String(localized: "AI Move to Trash", comment: "Undo and History action name")
        case "AI Changes": String(localized: "AI Changes", comment: "Undo and History action name")
        default: name
        }
    }

    package static let shared = OperationLog(storage: .shared, copies: .live)

    package private(set) var entries: [Entry] = []
    private let file: URL
    package let storage: SecureStorage.Context
    private let limit = 500
    private var undoing: Set<UUID> = []
    private var retiredTransfers: Set<UUID> = []
    package typealias Mover = ([FileOps.Move], String) async throws -> Void
    private let moveItems: Mover
    private let unsaved = Unsaved()

    /// History is written away from the main thread, one write at a time, each time the latest entries: encoding and
    /// sealing a History of big operations after every change held the app. Opening a History and quitting wait for
    /// the writes under way.
    nonisolated private static let writes = DispatchQueue(label: "Strata.History.writes")

    /// The entries waiting to be written, if any.
    nonisolated private final class Unsaved: Sendable {
        private let entries = Mutex<[Entry]?>(nil)

        /// Keeps `latest` for the next write; true when no write is waiting already.
        func keep(_ latest: [Entry]) -> Bool {
            entries.withLock { waiting in
                defer { waiting = latest }
                return waiting == nil
            }
        }

        func take() -> [Entry]? {
            entries.withLock { waiting in
                defer { waiting = nil }
                return waiting
            }
        }
    }

    package nonisolated static func waitForWrites() { writes.sync {} }

    /// The environment's server and container copies: undo and redo refuse to change what's inside them.
    private let copies: CopyProviders

    package init(storage: SecureStorage.Context, copies: CopyProviders, moveItems: Mover? = nil) {
        self.storage = storage
        self.copies = copies
        self.moveItems = moveItems ?? { pairs, name in
            try await FileOps.moveAsPart(pairs, copies: copies)
        }
        file = storage.url("history.sealed")
        Self.waitForWrites()
        entries = Self.readEntries(from: file, storage: storage)
    }

    // A bad record must not hide valid neighbors. Authentication and the JSON array itself still have to be
    // intact; loading never repairs or overwrites the saved file.
    package nonisolated static func readEntries(from file: URL, storage: SecureStorage.Context) -> [Entry] {
        guard let data = storage.read(file),
              let decoded = try? JSONDecoder().decode([SavedEntry].self, from: data) else { return [] }
        return decoded.compactMap(\.entry)
    }

    private nonisolated struct SavedEntry: Decodable {
        let entry: Entry?

        init(from decoder: Decoder) throws {
            entry = try? Entry(from: decoder)
        }
    }

    @discardableResult
    package func recordMove(_ name: String, _ pairs: [(from: URL, to: URL)], fileIdentities: [String: String]) -> UUID? {
        guard !pairs.isEmpty else { return nil }
        return append(Entry(name: name, kind: .move, moves: Self.moves(pairs), fileIdentities: fileIdentities))
    }

    @discardableResult
    package func recordCreate(_ name: String, _ created: [URL], fileIdentities: [String: String]) -> UUID? {
        guard !created.isEmpty else { return nil }
        return append(Entry(name: name, kind: .create, moves: [], created: created.map(\.path), fileIdentities: fileIdentities))
    }

    /// One entry for a whole copy or move job, including what it replaced.
    @discardableResult
    package func recordTransfer(_ name: String, created: [URL], moved: [(from: URL, to: URL)],
                        replaced: [(from: URL, to: URL)], containers: [URL] = [],
                        containerIdentities: [String: String], fileIdentities: [String: String],
                        updating id: UUID? = nil) -> UUID? {
        guard !(created.isEmpty && moved.isEmpty) else { return nil }
        var entry = Entry(name: name, kind: created.isEmpty ? .move : .create, moves: Self.moves(moved),
                          created: created.map(\.path), replacements: Self.moves(replaced), containers: containers.map(\.path),
                          containerIdentities: containerIdentities,
                          fileIdentities: fileIdentities)
        guard let id else { return append(entry) }
        // A retry updates its original operation, never an entry that has been undone or cleared meanwhile.
        guard canUpdateTransfer(id), let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        entry.id = id
        entry.date = entries[index].date
        entry.changed = entries[index].changed
        entries[index] = entry
        save()
        return id
    }

    /// A transfer being undone is already retired, even while its cross-volume moves are still running.
    package func canUpdateTransfer(_ id: UUID) -> Bool {
        !retiredTransfers.contains(id) && entries.contains { $0.id == id && !$0.undone }
    }

    /// One entry for an applied Ask Strata plan: its moves (Trash included) and the folders it made for them.
    @discardableResult
    package func recordPlan(_ name: String, moved: [(from: URL, to: URL)], containers: [URL],
                    containerIdentities: [String: String], fileIdentities: [String: String]) -> UUID? {
        guard !moved.isEmpty else { return nil }
        return append(Entry(name: name, kind: .move, moves: Self.moves(moved), containers: containers.map(\.path),
                            containerIdentities: containerIdentities,
                            fileIdentities: fileIdentities))
    }

    /// Keeps an entry in step with ⌘Z and ⇧⌘Z (undoing marks it undone; redoing marks it done again).
    package func setUndone(_ id: UUID, _ undone: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].undone != undone else { return }
        if undone { retiredTransfers.insert(id) }
        entries[index].undone = undone
        entries[index].changed = Date()
        save()
    }

    /// Redo can recreate containers with new identities. Update only the folders already belonging to this entry,
    /// using the identities captured by the recreation, never whatever happens to occupy their paths later.
    package func updateContainerIdentities(_ id: UUID, _ identities: [String: String]) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let containers = Set(entries[index].containers)
        let updates = identities.filter { containers.contains($0.key) && entries[index].ownership[$0.key] != HistoryIdentity($0.value) }
        guard !updates.isEmpty else { return }
        entries[index].ownership.merge(updates.mapValues { HistoryIdentity($0) }) { _, new in new }
        save()
    }

    private static func moves(_ pairs: [(from: URL, to: URL)]) -> [HistoryMove] {
        pairs.map { HistoryMove(from: $0.from, to: $0.to) }
    }

    /// History's volume UUID/inode key, with device numbers for volumes without UUIDs.
    package nonisolated static func identity(_ path: String) -> String? { FileIdentity.historyKey(at: path) }

    /// For each of `urls`: where it was before Strata last put it where it is, according to `entries` (a History's),
    /// and when that happened. Two kinds of event put an item somewhere: an operation that moved it there (or its
    /// redo), and the undo of one that had moved it away (undoing a Put Back returns the item to the Trash). The latest
    /// wins, and only while the file there is still the one that was moved. Keyed by standardized path; one pass over
    /// the entries, reading the disk, so off the main thread.
    package nonisolated static func movedFrom(_ urls: [URL], in entries: [Entry]) -> [String: (from: URL, date: Date)] {
        let wanted = Set(urls.map { $0.lexicallyStandardized.path })
        var found: [String: (from: URL, date: Date)] = [:]
        for entry in entries {
            let when = entry.changed ?? entry.date
            for pair in entry.moves {
                let here = URL(fileURLWithPath: entry.undone ? pair.from : pair.to).lexicallyStandardized.path
                guard wanted.contains(here), found[here].map({ $0.date <= when }) ?? true else { continue }
                // The identity was recorded where the operation left the file, at `pair.to`.
                let same = entry.expectation(at: pair.to).matches(at: here)
                guard same else { continue }
                found[here] = (URL(fileURLWithPath: entry.undone ? pair.to : pair.from), when)
            }
        }
        return found
    }

    /// `path` still holds the file the operation left there. Missing ownership always refuses Undo.
    nonisolated private static func holdsOriginal(_ entry: Entry, _ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        return entry.expectation(at: path).matches(at: path)
    }

    /// Whether undoing `entry` can still work: the very items the operation left are still where it left them, and
    /// nothing else occupies the places they'd go back to (a case-only rename's old spelling is the item itself).
    /// Its items are read away from the main thread.
    package func canUndo(_ entry: Entry) async -> Bool {
        guard mayUndo(entry) else { return false }
        return await Self.itemsAllowUndo([entry])[entry.id] == true && mayUndo(entry)
    }

    /// What goes back: each moved or replaced item still the one the operation left, to a place that's free (nothing
    /// there, the item itself, or a place another of its moves vacates first). Read away from the main thread.
    @concurrent private static func movesBack(_ entry: Entry) async -> [FileOps.Move] {
        (entry.moves.reversed() + entry.replacements.reversed()).filter { holdsOriginal(entry, $0.to) }.map {
            (from: URL(fileURLWithPath: $0.to), to: URL(fileURLWithPath: $0.from))
        }.filter { move in
            identity(move.to.path) == nil || identity(move.to.path) == identity(move.from.path)
                || entry.moves.contains { $0.to == move.to.path && holdsOriginal(entry, $0.to) }
        }
    }

    /// Those of `moves` that did go back, after a failure partway: read away from the main thread.
    @concurrent private static func wentBack(_ moves: [FileOps.Move]) async -> [FileOps.Move] {
        moves.filter { !TransferEngine.exists($0.from) && TransferEngine.exists($0.to) }
    }

    /// Whether `entry` is neither undone nor being undone: what `canUndo` knows without looking at its items.
    package func mayUndo(_ entry: Entry) -> Bool {
        !entry.undone && !undoing.contains(entry.id)
    }

    /// `canUndo`'s look at the items, for each of `entries`, away from the main thread; a check that's been replaced
    /// stops between entries.
    @concurrent package static func itemsAllowUndo(_ entries: [Entry]) async -> [UUID: Bool] {
        var found: [UUID: Bool] = [:]
        for entry in entries {
            if Task.isCancelled { break }
            found[entry.id] = itemsAllowUndo(entry)
        }
        return found
    }

    nonisolated private static func itemsAllowUndo(_ entry: Entry) -> Bool {
        // A place counts as free when nothing is there, it's the item itself (a case-only rename), or another move in
        // the same entry will vacate it first ("trash X, rename Y to X").
        let destinations = Set(entry.moves.map { $0.to })
        let movesBack = !entry.moves.isEmpty && entry.moves.allSatisfy { pair in
            holdsOriginal(entry, pair.to)
                && (identity(pair.from) == nil || Self.identity(pair.from) == Self.identity(pair.to) || destinations.contains(pair.from))
        }
        switch entry.kind {
        case .move:
            return movesBack
        case .create:
            return entry.created.contains { holdsOriginal(entry, $0) } || movesBack
        }
    }

    /// Reverses `entry`: created items go to the Trash, moves go back, replaced items come back out of the Trash, and
    /// folders made for moved items are removed if empty. The reversal is itself undoable with ⌘Z.
    package func undo(_ entry: Entry, undoManager: UndoManager?) async throws {
        // A retry may have repaired a copy or finished a move since this button was built. Undo the current saved
        // operation, and never revive an entry removed by Clear History.
        // Checked as saved now, and still saved so (unchanged, and not being undone) once its items have been read.
        guard let checked = entries.first(where: { $0.id == entry.id }), await canUndo(checked),
              let current = entries.first(where: { $0.id == entry.id }), current.sameItems(as: checked), mayUndo(current) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "“\(entry.displayName)” can’t be undone: its items have moved or changed since."),
            ])
        }
        let entry = current
        undoing.insert(entry.id)
        retiredTransfers.insert(entry.id)
        defer { undoing.remove(entry.id) }
        let containers = await CreatedFolders.recorded(paths: entry.containers, recorded: entry.identityKeys)
        // Everything happens without registering undo piecemeal; one ⌘Z afterwards puts it all back (below).
        var done: [FileOps.Move] = []
        // Each copy only while it's still the one the copy made, checked as it goes.
        if !entry.created.isEmpty {
            let (moved, _, failure) = await FileOps.trashForUndo(entry.created.map { URL(fileURLWithPath: $0) },
                                                              owns: { Self.holdsOriginal(entry, $0.path) }, copies: copies)
            done += moved
            if let failure {
                registerRedo(entry, done, undoManager, containers: containers)
                throw failure
            }
        }
        // A mixed transfer can still undo its own copies after a moved item is replaced. Check every move too;
        // canUndo accepting part of an entry never gives ownership of the rest.
        let back = await Self.movesBack(entry)
        if !back.isEmpty {
            do {
                try await moveItems(back, "Undo \(entry.name)")
                done += back
            } catch {
                // Part of it may have moved: keep ⌘Z able to put back what did.
                registerRedo(entry, done + (await Self.wentBack(back)), undoManager, containers: containers)
                throw error
            }
        }
        // Only what is (still) empty: never remove something put there since.
        await containers.removeEmpty()
        setUndone(entry.id, true)
        registerRedo(entry, done, undoManager, containers: containers)
    }

    /// ⌘Z right after a History undo redoes the whole operation in one step (recreating any folders it had made)
    /// and marks the entry live again once that has worked.
    private func registerRedo(_ entry: Entry, _ done: [FileOps.Move], _ undoManager: UndoManager?, containers: CreatedFolders) {
        FileOps.registerMoveUndo(done, entry.name, undoManager, entry: entry.id, copies: copies, marksUndone: false,
                                 containers: .make(containers), history: self)
    }

    package func clear() {
        entries.removeAll()
        retiredTransfers.removeAll()
        save()
    }

    private func append(_ entry: Entry) -> UUID {
        entries.append(entry)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
            retiredTransfers.formIntersection(Set(entries.map(\.id)))
        }
        save()
        return entry.id
    }

    private func save() {
        if unsaved.keep(entries) {
            let unsaved = unsaved, storage = storage, file = file
            Self.writes.async {
                guard let entries = unsaved.take() else { return }
                do {
                    try storage.write(try JSONEncoder().encode(entries), to: file)
                } catch {
                    // Nothing to ask anyone: what's undoable now still is; it just won't be after quitting.
                    let failure = error as NSError
                    Self.log.error("History couldn't be saved: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
                }
            }
        }
        NotificationCenter.default.post(name: .operationLogChanged, object: self)
    }
}
