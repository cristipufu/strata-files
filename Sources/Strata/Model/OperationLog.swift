import Foundation
import Synchronization

extension Notification.Name {
    static let operationLogChanged = Notification.Name("StrataOperationLogChanged")
}

/// A journal of file operations that survives restarts, so any of them can be undone later from the History window
/// (the Edit menu's Undo only covers the current session).
final class OperationLog {
    nonisolated struct Entry: Codable, Identifiable, Sendable {
        enum Kind: String, Codable, Sendable {
            /// `pairs` moved from → to (moves, renames, trash).
            case move
            /// `created` were made (copies, duplicates, new folders).
            case create
        }

        var id = UUID()
        var date = Date()
        var name: String
        var kind: Kind
        /// Items moved, from → to.
        var pairs: [[String]] = []
        /// Items the operation made (copies, duplicates, new folders): undo moves them to the Trash.
        var created: [String] = []
        /// Items the operation replaced, from their place → the Trash: undo brings them back.
        var replaced: [[String]] = []
        /// Folders made to hold moved items: undo removes them once they're empty again.
        var containers: [String] = []
        /// Which file each recorded path held right after the operation (volume UUID/inode, or device:inode in older
        /// entries): undo only touches those same files, never something else that took their place since.
        var identities: [String: String] = [:]
        var undone = false
        /// When it was last undone or redone (nil: never since it was done, at `date`).
        var changed: Date?

        init(name: String, kind: Kind, pairs: [[String]] = [], created: [String] = [], replaced: [[String]] = [],
             containers: [String] = [], containerIdentities: [String: String] = [:], fileIdentities: [String: String]? = nil) {
            self.name = name
            self.kind = kind
            self.pairs = pairs
            self.created = created
            self.replaced = replaced
            self.containers = containers
            let containerPaths = Set(containers)
            identities = containerIdentities.filter { containerPaths.contains($0.key) }
            for path in pairs.map({ $0[1] }) + created + replaced.map({ $0[1] }) {
                identities[path] = fileIdentities.map { $0[path] ?? "" } ?? OperationLog.identity(path) ?? ""
            }
        }

        // History saved by earlier versions lacks the newer fields.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            date = try c.decode(Date.self, forKey: .date)
            name = try c.decode(String.self, forKey: .name)
            kind = try c.decode(Kind.self, forKey: .kind)
            pairs = try c.decodeIfPresent([[String]].self, forKey: .pairs) ?? []
            created = try c.decodeIfPresent([String].self, forKey: .created) ?? []
            replaced = try c.decodeIfPresent([[String]].self, forKey: .replaced) ?? []
            containers = try c.decodeIfPresent([String].self, forKey: .containers) ?? []
            identities = try c.decodeIfPresent([String: String].self, forKey: .identities) ?? [:]
            undone = try c.decodeIfPresent(Bool.self, forKey: .undone) ?? false
            changed = try c.decodeIfPresent(Date.self, forKey: .changed)
            for (key, paths) in [(CodingKeys.pairs, pairs), (.replaced, replaced)] {
                guard paths.allSatisfy({ $0.count == 2 && !$0[0].isEmpty && !$0[1].isEmpty }) else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: c,
                                                          debugDescription: "History needs a source and destination for each move.")
                }
            }
            for (key, paths) in [(CodingKeys.created, created), (.containers, containers)] {
                guard paths.allSatisfy({ !$0.isEmpty }) else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: c,
                                                          debugDescription: "History paths cannot be empty.")
                }
            }
        }

        /// `name` as History shows it, in the app's language.
        var displayName: String { OperationLog.displayName(name) }
    }

    /// An operation's name as History and the Edit menu show it. Entries keep the English name they were recorded
    /// with (it's saved, and History picks its icon by it); the known ones are translated here, anything else is shown
    /// as recorded.
    nonisolated static func displayName(_ name: String) -> String {
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

    static let shared = OperationLog(copies: .live)

    private(set) var entries: [Entry] = []
    private let file: URL
    private let storage: SecureStorage.Context
    private let limit = 500
    private var undoing: Set<UUID> = []
    private var retiredTransfers: Set<UUID> = []
    typealias Mover = ([FileOps.Move], String) async throws -> Void
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

    nonisolated static func waitForWrites() { writes.sync {} }

    /// The environment's server and container copies: undo and redo refuse to change what's inside them.
    private let copies: CopyProviders

    init(storage: SecureStorage.Context = SecureStorage.current, copies: CopyProviders, moveItems: Mover? = nil) {
        self.storage = storage
        self.copies = copies
        self.moveItems = moveItems ?? { pairs, name in
            try await FileOps.move(pairs, actionName: name, undo: nil, record: false, copies: copies)
        }
        file = storage.url("history.sealed")
        Self.waitForWrites()
        entries = Self.readEntries(from: file, storage: storage)
        // Never import a plain history file: anything running as you could plant one, and undoing its entries would
        // move files with Strata's access. One from an earlier build is simply removed.
        SecureStorage.removeLegacy(storage.url("history.json"))
    }

    // A bad record must not hide valid neighbors. Authentication and the JSON array itself still have to be
    // intact; loading never repairs or overwrites the saved file.
    nonisolated static func readEntries(from file: URL, storage: SecureStorage.Context = SecureStorage.current) -> [Entry] {
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
    func recordMove(_ name: String, _ pairs: [(from: URL, to: URL)], landed: LandedFiles? = nil) -> UUID? {
        guard !pairs.isEmpty else { return nil }
        return append(Entry(name: name, kind: .move, pairs: Self.paths(pairs),
                            fileIdentities: landed?.historyIdentities(for: pairs.map(\.to))))
    }

    @discardableResult
    func recordCreate(_ name: String, _ created: [URL], landed: LandedFiles? = nil) -> UUID? {
        guard !created.isEmpty else { return nil }
        return append(Entry(name: name, kind: .create, created: created.map(\.path),
                            fileIdentities: landed?.historyIdentities(for: created)))
    }

    /// One entry for a whole copy or move job, including what it replaced.
    @discardableResult
    func recordTransfer(_ name: String, created: [URL], moved: [(from: URL, to: URL)],
                        replaced: [(from: URL, to: URL)], containers: [URL] = [],
                        containerIdentities: [String: String]? = nil, landed: LandedFiles? = nil,
                        updating id: UUID? = nil) -> UUID? {
        guard !(created.isEmpty && moved.isEmpty) else { return nil }
        var entry = Entry(name: name, kind: created.isEmpty ? .move : .create, pairs: Self.paths(moved),
                          created: created.map(\.path), replaced: Self.paths(replaced), containers: containers.map(\.path),
                          containerIdentities: containerIdentities ?? CreatedFolders(containers).historyIdentities,
                          fileIdentities: landed?.historyIdentities(for: created + moved.map(\.to) + replaced.map(\.to)))
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
    func canUpdateTransfer(_ id: UUID) -> Bool {
        !retiredTransfers.contains(id) && entries.contains { $0.id == id && !$0.undone }
    }

    /// One entry for an applied Ask Strata plan: its moves (Trash included) and the folders it made for them.
    @discardableResult
    func recordPlan(_ name: String, moved: [(from: URL, to: URL)], containers: [URL],
                    containerIdentities: [String: String]? = nil, landed: LandedFiles? = nil) -> UUID? {
        guard !moved.isEmpty else { return nil }
        return append(Entry(name: name, kind: .move, pairs: Self.paths(moved), containers: containers.map(\.path),
                            containerIdentities: containerIdentities ?? CreatedFolders(containers).historyIdentities,
                            fileIdentities: landed?.historyIdentities(for: moved.map(\.to))))
    }

    /// Keeps an entry in step with ⌘Z and ⇧⌘Z (undoing marks it undone; redoing marks it done again).
    func setUndone(_ id: UUID, _ undone: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].undone != undone else { return }
        if undone { retiredTransfers.insert(id) }
        entries[index].undone = undone
        entries[index].changed = Date()
        save()
    }

    /// Redo can recreate containers with new identities. Update only the folders already belonging to this entry,
    /// using the identities captured by the recreation, never whatever happens to occupy their paths later.
    func updateContainerIdentities(_ id: UUID, _ identities: [String: String]) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let containers = Set(entries[index].containers)
        let updates = identities.filter { containers.contains($0.key) && entries[index].identities[$0.key] != $0.value }
        guard !updates.isEmpty else { return }
        entries[index].identities.merge(updates) { _, new in new }
        save()
    }

    private static func paths(_ pairs: [(from: URL, to: URL)]) -> [[String]] {
        pairs.map { [$0.from.path, $0.to.path] }
    }

    /// History's volume UUID/inode key, with compatibility for volumes without UUIDs.
    nonisolated static func identity(_ path: String) -> String? { FileIdentity.historyKey(at: path) }

    /// For each of `urls`: where it was before Strata last put it where it is, and when that happened. Two kinds of
    /// event put an item somewhere: an operation that moved it there (or its redo), and the undo of one that had moved
    /// it away (undoing a Put Back returns the item to the Trash). The latest wins, and only while the file there is
    /// still the one that was moved. Keyed by standardized path; one pass over History.
    func movedFrom(_ urls: [URL]) -> [String: (from: URL, date: Date)] {
        let wanted = Set(urls.map { $0.standardizedFileURL.path })
        var found: [String: (from: URL, date: Date)] = [:]
        for entry in entries {
            let when = entry.changed ?? entry.date
            for pair in entry.pairs where pair.count == 2 && !pair[0].isEmpty && !pair[1].isEmpty {
                let here = URL(fileURLWithPath: entry.undone ? pair[0] : pair[1]).standardizedFileURL.path
                guard wanted.contains(here), found[here].map({ $0.date <= when }) ?? true else { continue }
                // The identity was recorded where the operation left the file, at `pair[1]`.
                let same = entry.identities[pair[1]].map { FileIdentity.matchesHistory($0, at: here) } ?? TransferEngine.exists(URL(fileURLWithPath: here))
                guard same else { continue }
                found[here] = (URL(fileURLWithPath: entry.undone ? pair[1] : pair[0]), when)
            }
        }
        return found
    }

    /// `path` still holds the file the operation left there (entries from before identities were kept: it exists).
    nonisolated private static func holdsOriginal(_ entry: Entry, _ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        guard let recorded = entry.identities[path] else { return TransferEngine.exists(URL(fileURLWithPath: path)) }
        return FileIdentity.matchesHistory(recorded, at: path)
    }

    /// Whether undoing `entry` can still work: the very items the operation left are still where it left them, and
    /// nothing else occupies the places they'd go back to (a case-only rename's old spelling is the item itself).
    func canUndo(_ entry: Entry) -> Bool {
        mayUndo(entry) && Self.itemsAllowUndo(entry)
    }

    /// Whether `entry` is neither undone nor being undone: what `canUndo` knows without looking at its items.
    func mayUndo(_ entry: Entry) -> Bool {
        !entry.undone && !undoing.contains(entry.id)
    }

    /// `canUndo`'s look at the items, for each of `entries`, away from the main thread; a check that's been replaced
    /// stops between entries.
    @concurrent static func itemsAllowUndo(_ entries: [Entry]) async -> [UUID: Bool] {
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
        let destinations = Set(entry.pairs.map { $0[1] })
        let movesBack = !entry.pairs.isEmpty && entry.pairs.allSatisfy { pair in
            holdsOriginal(entry, pair[1])
                && (identity(pair[0]) == nil || Self.identity(pair[0]) == Self.identity(pair[1]) || destinations.contains(pair[0]))
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
    func undo(_ entry: Entry, undoManager: UndoManager?) async throws {
        // A retry may have repaired a copy or finished a move since this button was built. Undo the current saved
        // operation, and never revive an entry removed by Clear History.
        guard let current = entries.first(where: { $0.id == entry.id }), canUndo(current) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "“\(entry.displayName)” can’t be undone: its items have moved or changed since."),
            ])
        }
        let entry = current
        undoing.insert(entry.id)
        retiredTransfers.insert(entry.id)
        defer { undoing.remove(entry.id) }
        let containers = CreatedFolders(paths: entry.containers, recorded: entry.identities)
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
        let back = (entry.pairs.reversed() + entry.replaced.reversed()).filter { Self.holdsOriginal(entry, $0[1]) }.map {
            (from: URL(fileURLWithPath: $0[1]), to: URL(fileURLWithPath: $0[0]))
        }.filter { move in
            Self.identity(move.to.path) == nil || Self.identity(move.to.path) == Self.identity(move.from.path)
                || entry.pairs.contains { $0[1] == move.to.path && Self.holdsOriginal(entry, $0[1]) }
        }
        if !back.isEmpty {
            do {
                try await moveItems(back, "Undo \(entry.name)")
                done += back
            } catch {
                // Part of it may have moved: keep ⌘Z able to put back what did.
                registerRedo(entry, done + back.filter { !TransferEngine.exists($0.from) && TransferEngine.exists($0.to) },
                             undoManager, containers: containers)
                throw error
            }
        }
        // Only what is (still) empty: never remove something put there since.
        containers.removeEmpty()
        setUndone(entry.id, true)
        registerRedo(entry, done, undoManager, containers: containers)
    }

    /// ⌘Z right after a History undo redoes the whole operation in one step (recreating any folders it had made)
    /// and marks the entry live again once that has worked.
    private func registerRedo(_ entry: Entry, _ done: [FileOps.Move], _ undoManager: UndoManager?, containers: CreatedFolders) {
        FileOps.registerMoveUndo(done, entry.name, undoManager, entry: entry.id, copies: copies, marksUndone: false,
                                 containers: .make(containers), history: self)
    }

    func clear() {
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
                guard let entries = unsaved.take(), let data = try? JSONEncoder().encode(entries) else { return }
                try? storage.write(data, to: file)
            }
        }
        NotificationCenter.default.post(name: .operationLogChanged, object: self)
    }
}
