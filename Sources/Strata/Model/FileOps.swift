import AppKit

extension Notification.Name {
    static let clipboardChanged = Notification.Name("StrataClipboardChanged")
}

/// File system changes with undo. Moves and copies run off the main thread; undo and redo are registered as the
/// inverse operation, which registers its own inverse in turn.
enum FileOps {
    typealias Move = (from: URL, to: URL)

    /// An archive opened as a folder is a temporary copy: nothing inside it is changed from Strata.
    static let insideArchiveError = CocoaError(.fileWriteNoPermission, userInfo: [
        NSLocalizedDescriptionKey: String(localized: "Items in a read-only copy (an archive opened as a folder, or a container’s files) can’t be changed. Copy them out first."),
    ])

    static func rename(_ url: URL, to name: String, undo: UndoManager?, copies: CopyProviders,
                       history: OperationLog) async throws -> URL {
        guard !ReadOnlyCopies.contains(url, copies: copies) else { throw insideArchiveError }
        // A name, never a path: whatever is typed, the item stays in its folder.
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: name])
        }
        guard !name.contains(":"), name.utf8.count <= 255,
              !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: name])
        }
        let destination = url.deletingLastPathComponent().appending(path: name)
        if TransferEngine.exists(destination), destination.path.lowercased() != url.path.lowercased() {
            throw CocoaError(.fileWriteFileExists, userInfo: [
                NSFilePathErrorKey: destination.path,
                NSLocalizedDescriptionKey: String(localized: "The name “\(name)” is already taken. Please choose a different name."),
            ])
        }
        try await move([(from: url, to: destination)], actionName: "Rename", undo: undo, history: history, copies: copies)
        return destination
    }

    static func move(_ pairs: [Move], actionName: String, undo: UndoManager?, history: OperationLog,
                     copies: CopyProviders) async throws {
        try refuseReadOnly(pairs, copies: copies)
        let landed = LandedFiles()
        for pair in pairs { landed.expect(pair.from, at: pair.to) }
        let (done, error) = await moveAll(pairs)
        let arrivedPaths = Set(done.map(\.to.path))
        for pair in pairs where !arrivedPaths.contains(pair.to.path) { landed.set(nil, at: pair.to) }
        for pair in done where landed.identity(at: pair.to) == nil { landed.record([pair.to]) }
        done.forEach { landed.arrived($0.to); TransferEngine.hooks.afterLanding?($0.to) }
        let entry = history.recordMove(actionName, done, landed: landed)
        registerMoveUndo(done, actionName, undo, entry: entry, copies: copies, landed: landed, history: history)
        if let error { throw error }
    }

    /// Moves that are a step of another operation (an undo or redo, a plan's rename through a temporary name): History
    /// keeps one entry per operation and marks it undone instead of growing a row per ⌘Z, so nothing is recorded or
    /// registered.
    static func moveAsPart(_ pairs: [Move], copies: CopyProviders) async throws {
        try refuseReadOnly(pairs, copies: copies)
        let (done, error) = await moveAll(pairs)
        done.forEach { TransferEngine.hooks.afterLanding?($0.to) }
        if let error { throw error }
    }

    /// Nothing inside an archive opened as a folder moves, in or out: it's a temporary copy.
    private static func refuseReadOnly(_ pairs: [Move], copies: CopyProviders) throws {
        guard !pairs.contains(where: { ReadOnlyCopies.contains($0.from, copies: copies) || ReadOnlyCopies.contains($0.to, copies: copies) }) else {
            throw insideArchiveError
        }
    }

    /// Moves each pair in order, stopping at the first error, and returns what moved and the error that stopped it.
    /// Swaps and chains ("a → b" with "b → a", or "1 → 2, 2 → 3") are ordered so each item moves only once the one
    /// whose place it takes has left; a cycle parks one item under a hidden name that keeps its own. They succeed or
    /// fail as a whole: on an error everything moved goes back, and nothing is left under a hidden name.
    static func moveAll(_ pairs: [Move]) async -> (done: [Move], error: Error?) {
        guard isChain(pairs) else {
            var done: [Move] = []
            for pair in pairs {
                do { try await moveItem(pair.from, pair.to) } catch { return (done, error) }
                done.append(pair)
            }
            return (done, nil)
        }
        var executed: [(step: ChainStep, completes: Int?)] = []
        for step in chainSteps(pairs) {
            do {
                try await moveItem(step.from, step.to)
                executed.append((step, step.completes))
            } catch {
                let pair = pairs[step.pair]
                let named = NSError(domain: NSCocoaErrorDomain, code: (error as NSError).code, userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "“\(pair.from.lastPathComponent)” couldn’t be renamed to “\(pair.to.lastPathComponent)”: \(error.localizedDescription)"),
                    NSUnderlyingErrorKey: error,
                ])
                // Back the way it came; whatever can't go back stays where it is, but never hidden.
                var kept: [Move] = []
                for item in executed.reversed() {
                    if (try? await moveItem(item.step.to, item.step.from)) != nil { continue }
                    if item.step.isParking {
                        let fallback = available(item.step.from, copyStyle: false)
                        if (try? await moveItem(item.step.to, fallback)) != nil {
                            kept.insert((from: item.step.from, to: fallback), at: 0)
                        }
                    } else if let completed = item.completes {
                        kept.insert(pairs[completed], at: 0)
                    }
                }
                return (kept, named)
            }
        }
        return (executed.compactMap { $0.completes.map { pairs[$0] } }, nil)
    }

    /// One rename of a chain: `completes` is the pair it finishes (nil while an item is parked).
    struct ChainStep {
        let from: URL
        let to: URL
        /// The pair this step belongs to.
        let pair: Int
        let completes: Int?
        var isParking: Bool { completes == nil }
    }

    /// The order to run `pairs` in: each moves after the one whose place it takes (`blocker`); a cycle is broken by
    /// parking its first item and finishing it last.
    nonisolated static func chainSteps(_ pairs: [Move]) -> [ChainStep] {
        func key(_ url: URL) -> String { url.standardizedFileURL.path.lowercased() }
        let bySource = Dictionary(pairs.enumerated().map { (key($0.element.from), $0.offset) }, uniquingKeysWith: { first, _ in first })
        var blocked = [Bool](repeating: false, count: pairs.count)
        // waiting[j]: the pair that goes where pair j is now.
        var waiting = [Int?](repeating: nil, count: pairs.count)
        for (index, pair) in pairs.enumerated() {
            let target = key(pair.to)
            if target != key(pair.from), let other = bySource[target], other != index {
                blocked[index] = true
                waiting[other] = index
            }
        }
        var steps: [ChainStep] = []
        var scheduled = [Bool](repeating: false, count: pairs.count)
        // Chains: start from the item whose new name is free, then the one that takes its old name, and so on.
        for start in pairs.indices where !blocked[start] {
            var next: Int? = start
            while let current = next, !scheduled[current] {
                scheduled[current] = true
                steps.append(ChainStep(from: pairs[current].from, to: pairs[current].to, pair: current, completes: current))
                next = waiting[current]
            }
        }
        // What's left are cycles.
        for start in pairs.indices where !scheduled[start] {
            let parked = parkingName(for: pairs[start].from)
            steps.append(ChainStep(from: pairs[start].from, to: parked, pair: start, completes: nil))
            scheduled[start] = true
            var next = waiting[start]
            while let current = next, !scheduled[current] {
                scheduled[current] = true
                steps.append(ChainStep(from: pairs[current].from, to: pairs[current].to, pair: current, completes: current))
                next = waiting[current]
            }
            steps.append(ChainStep(from: parked, to: pairs[start].to, pair: start, completes: start))
        }
        return steps
    }

    /// A hidden name beside `url` that still says what the item was called (".strata-1a2b3c4d-Photo.jpg"), so an
    /// interrupted swap leaves nothing anonymous.
    nonisolated static func parkingName(for url: URL) -> URL {
        let prefix = ".strata-" + UUID().uuidString.prefix(8).lowercased() + "-"
        var name = url.lastPathComponent
        while !name.isEmpty, (prefix + name).utf8.count > 255 { name.removeLast() }
        return url.deletingLastPathComponent().appending(path: prefix + name)
    }

    /// Whether an item goes where another one is now (a swap or a chain of renames).
    nonisolated static func isChain(_ pairs: [Move]) -> Bool {
        func key(_ url: URL) -> String { url.standardizedFileURL.path.lowercased() }
        let sources = Set(pairs.map { key($0.from) })
        return pairs.contains { key($0.to) != key($0.from) && sources.contains(key($0.to)) }
    }

    /// A translated piece of a file name ("untitled folder", " copy"), or the English one when the translation can't be
    /// part of a name: translations come from language files anyone can contribute, and a "/" or ".." in one must never
    /// place an item somewhere else (nor a leading "." hide it).
    nonisolated static func nameText(_ translated: String, english: String) -> String {
        let trimmed = translated.trimmingCharacters(in: .whitespaces)
        let unsafe = translated.contains("/") || translated.contains(":")
            || translated.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0 == "\u{0}" }
        // Nor "~…", which a plan would read as a path in your home folder.
        guard !unsafe, !trimmed.isEmpty, !trimmed.hasPrefix("."), !trimmed.hasPrefix("~"), translated.utf8.count <= 100 else { return english }
        return translated
    }

    static func newFolder(in directory: URL, undo: UndoManager?, copies: CopyProviders,
                          history: OperationLog) throws -> URL {
        guard !ReadOnlyCopies.contains(directory, copies: copies) else { throw insideArchiveError }
        let name = nameText(String(localized: "untitled folder", comment: "Name of a new folder, as Finder names it"),
                            english: "untitled folder")
        let url = available(directory.appending(path: name), copyStyle: false)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let landed = LandedFiles([url])
        let entry = history.recordCreate("New Folder", [url], landed: landed)
        registerTrashUndo([url], "New Folder", undo, entry: entry, landed: landed, copies: copies, history: history)
        return url
    }

    /// File ▸ New File: an empty "untitled.txt" (`ext` is Settings' extension, "" for none), "untitled 2.txt" when that's
    /// taken. Never over anything: the name is claimed only while nothing is there, not even a link.
    static func newFile(in directory: URL, extension ext: String, undo: UndoManager?, copies: CopyProviders,
                        history: OperationLog) throws -> URL {
        guard !ReadOnlyCopies.contains(directory, copies: copies) else { throw insideArchiveError }
        let name = newFileName(extension: ext)
        var url = available(directory.appending(path: name), copyStyle: false)
        for attempt in 0... {
            do {
                try Data().write(to: url, options: .withoutOverwriting)
                break
            } catch CocoaError.fileWriteFileExists where attempt < 20 {
                // Something took the name meanwhile: the next free one.
                url = available(directory.appending(path: name), copyStyle: false)
            }
        }
        let landed = LandedFiles([url])
        let entry = history.recordCreate("New File", [url], landed: landed)
        registerTrashUndo([url], "New File", undo, entry: entry, landed: landed, copies: copies, history: history)
        return url
    }

    /// What New File calls a file: "untitled.txt", "untitled" with no extension. `stem` replaces "untitled" ("untitled 2").
    nonisolated static func newFileName(extension ext: String, stem: String? = nil) -> String {
        let base = stem ?? nameText(String(localized: "untitled", comment: "Name of a new empty file, before its extension: “untitled.txt”"),
                                    english: "untitled")
        return ext.isEmpty ? base : base + "." + ext
    }

    /// An extension for new files as typed in Settings ("txt", ".md", " TXT "), without its dot; nil when it can't be one.
    /// Letters, digits, "-", "_" and "+" only: no dots, slashes or spaces, so a new file is always one plain name.
    nonisolated static func newFileExtension(_ typed: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix(".") { text.removeFirst() }
        guard text.utf8.count <= 32,
              text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_+".unicodeScalars.contains($0) }) else { return nil }
        return text
    }

    /// With `record: false` the trashing is part of another operation (undoing a copy, say): its undo then marks
    /// History entry `entry` as `marksUndone` once it has worked. Returns where the items went.
    @discardableResult
    static func trash(_ urls: [URL], undo: UndoManager?, record: Bool = true, entry: UUID? = nil,
                      marksUndone: Bool = true, copies: CopyProviders, history: OperationLog) throws -> [Move] {
        var moved: [Move] = []
        let landed = LandedFiles()
        defer {
            let logged = record ? history.recordMove("Move to Trash", moved, landed: landed) : entry
            registerMoveUndo(moved, "Move to Trash", undo, entry: logged, copies: copies, marksUndone: record ? true : marksUndone, landed: landed, history: history)
            if !moved.isEmpty { Sounds.movedToTrash() }
        }
        for url in Self.outermost(urls) where Self.canTrash(url, copies: copies) {
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            if let result {
                moved.append((from: url, to: result as URL))
                landed.record([result as URL])
            }
        }
        return moved
    }

    /// Removes owned, empty folders innermost first. Read and remove Finder's records relative to the opened folder,
    /// never through a link or a reused path. Failed reads leave the folder alone; removal is always nonrecursive.
    nonisolated static func removeEmptyFolders(_ folders: [URL], identities: [String: FileIdentity]) {
        for folder in folders.sorted(by: { $0.path.count > $1.path.count }) {
            guard let expected = identities[folder.path] else { continue }
            let parent = open(folder.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard parent >= 0 else { continue }
            defer { close(parent) }
            let fd = openat(parent, folder.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, FileIdentity.from(info) == expected else { continue }
            let copy = dup(fd)
            guard copy >= 0 else { continue }
            guard let listing = fdopendir(copy) else { close(copy); continue }
            defer { closedir(listing) }
            var records = false, empty = true
            while true {
                errno = 0
                guard let entry = readdir(listing) else {
                    if errno != 0 { empty = false }
                    break
                }
                guard let name = DirectoryEntryName.read(entry) else { empty = false; break }
                if name == ".DS_Store" { records = true }
                else if name != "." && name != ".." { empty = false; break }
            }
            guard empty, fstatat(parent, folder.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  FileIdentity.from(info) == expected else { continue }
            if records { unlinkat(fd, ".DS_Store", 0) }
            guard fstatat(parent, folder.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  FileIdentity.from(info) == expected else { continue }
            unlinkat(parent, folder.lastPathComponent, AT_REMOVEDIR)
        }
    }

    /// Items that couldn't go to the Trash because their disk has none (network shares, some external disks).
    struct NoTrash: LocalizedError {
        let urls: [URL]

        nonisolated var errorDescription: String? {
            String(localized: "The disk has no Trash.", comment: "Error when a disk cannot move files to the Trash")
        }
    }

    /// Moves `urls` to the Trash off the main thread (a big selection or a slow disk would freeze the window), then
    /// records and registers undo like `trash`. Items on disks without a Trash come back in `NoTrash`.
    static func trashInBackground(_ urls: [URL], undo: UndoManager?, copies: CopyProviders, history: OperationLog) async throws {
        let (moved, identities, noTrash, failure) = await trashItems(urls, copies: copies)
        let landed = LandedFiles()
        for (move, identity) in zip(moved, identities) { landed.set(identity, at: move.to) }
        let entry = history.recordMove("Move to Trash", moved, landed: landed)
        registerMoveUndo(moved, "Move to Trash", undo, entry: entry, copies: copies, landed: landed, history: history)
        if !moved.isEmpty { Sounds.movedToTrash() }
        if let failure { throw failure }
        if !noTrash.isEmpty { throw NoTrash(urls: noTrash) }
    }

    /// `trash` for part of an undo under way: each item goes to the Trash away from the main thread only if `owns` says
    /// it's still the one the operation left there, asked just before it goes. It stops at the first failure, a disk
    /// without a Trash included, and returns what went, what each is in the Trash (read as it lands) and that failure;
    /// nothing is recorded or registered.
    static func trashForUndo(_ urls: [URL], owns: @escaping @Sendable (URL) -> Bool, copies: CopyProviders) async
        -> (moved: [Move], identities: [FileIdentity?], failure: Error?) {
        let result = await trashOwned(urls, owns: owns, copies: copies)
        if !result.moved.isEmpty { Sounds.movedToTrash() }
        return result
    }

    @concurrent
    private static func trashOwned(_ urls: [URL], owns: @Sendable (URL) -> Bool, copies: CopyProviders) async
        -> (moved: [Move], identities: [FileIdentity?], failure: Error?) {
        var moved: [Move] = []
        var identities: [FileIdentity?] = []
        // Owned first: a copy inside a folder put in another's place is still the operation's own.
        for url in outermost(urls.filter(owns)) where canTrash(url, copies: copies) && owns(url) {
            var result: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                if let result {
                    moved.append((from: url, to: result as URL))
                    identities.append(FileIdentity.read(result.path ?? ""))
                }
            } catch let error as CocoaError where error.code == .featureUnsupported {
                return (moved, identities, NoTrash(urls: [url]))
            } catch {
                return (moved, identities, error)
            }
        }
        return (moved, identities, nil)
    }

    /// Whether Move to Trash may take `url`. Never a Trash itself, nor what's already in one (trashing it again would
    /// lose where it came from), however either's path is spelled; nor anything inside an archive opened as a folder
    /// (a temporary copy). A link to a Trash is only a link.
    nonisolated static func canTrash(_ url: URL) -> Bool {
        canTrash(url, copies: .live)
    }

    nonisolated static func canTrash(_ url: URL, copies: CopyProviders) -> Bool {
        !Trash.isTrash(anySpelling: url) && !Trash.isInTrash(url) && !Trash.isInTrash(url.resolvingSymlinksInPath())
            && !ReadOnlyCopies.contains(url, copies: copies)
    }

    /// `urls` in order without duplicates or items inside another of them, keeping each item's original URL spelling.
    nonisolated static func outermost(_ urls: [URL]) -> [URL] {
        let pairs = urls.map { (url: $0, path: $0.standardizedFileURL.path) }
        var seen: Set<String> = []
        return pairs.filter { item in
            guard seen.insert(item.path).inserted else { return false }
            return !pairs.contains { other in
                other.path != item.path && item.path.hasPrefix(other.path == "/" ? "/" : other.path + "/")
            }
        }.map(\.url)
    }

    @concurrent
    private static func trashItems(_ urls: [URL], copies: CopyProviders) async -> (moved: [Move], identities: [FileIdentity?], noTrash: [URL], failure: Error?) {
        var moved: [Move] = []
        var identities: [FileIdentity?] = []
        var noTrash: [URL] = []
        let urls = Self.outermost(urls)
        for url in urls where canTrash(url, copies: copies) {
            var result: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                if let result {
                    moved.append((from: url, to: result as URL))
                    identities.append(FileIdentity.read(result.path ?? ""))
                }
            } catch let error as CocoaError where error.code == .featureUnsupported {
                noTrash.append(url)
            } catch {
                return (moved, identities, noTrash, error)
            }
        }
        return (moved, identities, noTrash, nil)
    }

    /// `name 2.txt`, `name 3.txt`… or Finder's `name copy.txt`, `name copy 2.txt`… for copies next to the original.
    nonisolated static func available(_ url: URL, copyStyle: Bool) -> URL {
        let fm = FileManager.default
        // lstat-based: a dangling symlink still takes the name.
        guard TransferEngine.exists(url) else { return url }
        let directory = url.deletingLastPathComponent()
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDir)
        let isPlainFolder = isDir.boolValue && !NSWorkspace.shared.isFilePackage(atPath: url.path)
        var n = 1
        while true {
            let suffix = !copyStyle ? " \(n + 1)"
                : n == 1 ? nameText(String(localized: " copy", comment: "Added to a duplicate’s name like Finder: “Report copy.pdf”. Keep the leading space."),
                                    english: " copy")
                // The number stays plain digits ("copy 2"), whatever the region: it's part of a name on disk.
                : nameText(String(localized: " copy \(String(n))", comment: "Added to a later duplicate’s name like Finder: “Report copy 2.pdf”. Keep the leading space."),
                           english: " copy \(n)")
            let candidate = directory.appending(path: name(url.lastPathComponent, adding: suffix,
                                                           keepingExtension: !isPlainFolder))
            if !TransferEngine.exists(candidate) { return candidate }
            n += 1
        }
    }

    /// `name` with `suffix` before its extension, as Finder names a copy ("Report 2.pdf", "Report copy.pdf"). A plain
    /// folder's name has no extension to keep, an extension over 64 bytes isn't one, and the part before the suffix gives
    /// way, whole characters at a time, so the name fits its 255 bytes.
    nonisolated static func name(_ name: String, adding suffix: String, keepingExtension: Bool) -> String {
        let found = keepingExtension ? (name as NSString).pathExtension : ""
        let ext = found.utf8.count <= 64 ? found : ""
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let tail = suffix + (ext.isEmpty ? "" : "." + ext)
        return TransferEngine.fitting(base, maxBytes: max(1, 255 - tail.utf8.count)) + tail
    }

    /// Undo for something just made: it goes to the Trash; redoing brings it back. History follows both.
    private static func registerTrashUndo(_ created: [URL], _ actionName: String, _ undo: UndoManager?, entry: UUID?,
                                          landed: LandedFiles, copies: CopyProviders, history: OperationLog) {
        guard !created.isEmpty else { return }
        register(actionName, undo) { undo in
            do {
                let made = created.filter(landed.holds)
                guard !made.isEmpty else { return }
                try trash(made, undo: undo, record: false, entry: entry, marksUndone: false, copies: copies, history: history)
                if let entry { history.setUndone(entry, true) }
            } catch {
                reportUndoFailure(actionName, error)
            }
        }
    }

    /// ⌘Z couldn't put things back (something now sits where an item would return, say): say so rather than fail
    /// silently.
    static func reportUndoFailure(_ actionName: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn’t undo “\(OperationLog.displayName(actionName))”")
        alert.informativeText = error.localizedDescription
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// Registers, in the current undo group, flipping History entry `id` to `undone` (and back on redo), so the
    /// History window agrees with ⌘Z and ⇧⌘Z.
    static func registerLogMark(_ id: UUID, undone: Bool, _ undo: UndoManager, history: OperationLog) {
        undo.registerUndo(withTarget: undo) { undo in
            MainActor.assumeIsolated {
                history.setUndone(id, undone)
                registerLogMark(id, undone: !undone, undo, history: history)
            }
        }
    }

    private static func register(_ actionName: String, _ undo: UndoManager?, _ handler: @escaping (UndoManager) -> Void) {
        guard let undo else { return }
        undo.registerUndo(withTarget: undo) { target in
            MainActor.assumeIsolated { handler(target) }
        }
        undo.setActionName(OperationLog.displayName(actionName))
    }

    /// ⌘Z and ⇧⌘Z work that moves items, done one step at a time in the order pressed, however quickly: each step
    /// finds the items where the one before left them (`undoWork` is the latest; tests wait for it).
    static var undoWork: Task<Void, Never>?

    /// Runs `work` after every undo and redo step before it.
    @discardableResult
    static func afterUndoWork(_ work: @escaping () async -> Void) -> Task<Void, Never> {
        let previous = undoWork
        let task = Task {
            await previous?.value
            await work()
        }
        undoWork = task
        return task
    }

    /// Undo for completed moves: move the items back, those still where they went. The inverse is registered right
    /// away, inside the undo handler, so it lands on the redo stack (registering it later from a task would put it
    /// back on the undo stack); the moves run after the steps before (`undoWork`) and take only what's still where
    /// they left it (`landed`, recorded as each lands). History entry `entry` is marked `marksUndone` only once the
    /// moves have worked (the inverse flips it back). Containers made for the operation are recreated before Redo
    /// and removed after Undo only while their recorded identities still match and they are empty.
    static func registerMoveUndo(_ moves: [Move], _ actionName: String, _ undo: UndoManager?, entry: UUID? = nil,
                                 copies: CopyProviders, marksUndone: Bool = true, containers: CreatedFolders.Change = .none,
                                 landed: LandedFiles? = nil, history: OperationLog) {
        guard !moves.isEmpty else { return }
        let landed = landed ?? LandedFiles(moves.map(\.to))
        register(actionName, undo) { undo in
            let returned = LandedFiles()
            afterUndoWork {
                let back = moves.filter { landed.holds($0.to) }.reversed().map { (from: $0.to, to: $0.from) }
                guard !back.isEmpty else { return }
                for pair in back { returned.expect(pair.from, at: pair.to) }
                do {
                    guard !back.contains(where: { ReadOnlyCopies.contains($0.from, copies: copies) || ReadOnlyCopies.contains($0.to, copies: copies) }) else {
                        throw insideArchiveError
                    }
                    try containers.prepare()
                    if let entry { history.updateContainerIdentities(entry, containers.historyIdentities) }
                    let (done, error) = await moveAll(back)
                    done.forEach { returned.arrived($0.to) }
                    containers.finish()
                    if let error { throw error }
                    if let entry { history.setUndone(entry, marksUndone) }
                } catch {
                    reportUndoFailure(actionName, error)
                }
            }
            registerMoveUndo(moves.reversed().map { (from: $0.to, to: $0.from) }, actionName, undo, entry: entry, copies: copies,
                             marksUndone: !marksUndone, containers: containers.inverse, landed: returned, history: history)
        }
    }

    @concurrent
    private static func moveItem(_ from: URL, _ to: URL) async throws {
        try FileManager.default.moveItem(at: from, to: to)
    }
}

/// Finder-compatible file clipboard, plus cut: ⌘X marks the items and the next paste moves them.
final class Clipboard {
    static let shared = Clipboard()

    /// The general pasteboard; tests use one of their own.
    static var pasteboard: NSPasteboard {
        get { shared.pasteboard }
        set { shared.pasteboard = newValue }
    }

    var pasteboard: NSPasteboard
    let notifications: NotificationCenter
    private var cut: (urls: Set<URL>, changeCount: Int)?

    init(pasteboard: NSPasteboard = .general, notifications: NotificationCenter = .default) {
        self.pasteboard = pasteboard
        self.notifications = notifications
    }

    func write(_ urls: [URL], cut isCut: Bool) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        cut = isCut ? (Set(urls), pasteboard.changeCount) : nil
        notifications.post(name: .clipboardChanged, object: nil)
    }

    func read() -> (urls: [URL], isCut: Bool) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return (urls, cut?.changeCount == pasteboard.changeCount)
    }

    func isCut(_ url: URL) -> Bool {
        guard let cut, cut.changeCount == pasteboard.changeCount else { return false }
        return cut.urls.contains(url)
    }

    func clearCut() {
        cut = nil
        notifications.post(name: .clipboardChanged, object: nil)
    }

    var hasFiles: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    static func write(_ urls: [URL], cut isCut: Bool) { shared.write(urls, cut: isCut) }
    static func read() -> (urls: [URL], isCut: Bool) { shared.read() }
    static func isCut(_ url: URL) -> Bool { shared.isCut(url) }
    static func clearCut() { shared.clearCut() }
    static var hasFiles: Bool { shared.hasFiles }
}
