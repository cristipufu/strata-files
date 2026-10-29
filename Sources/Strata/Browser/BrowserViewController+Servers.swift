import AppKit

/// A server's files (see `RemoteCopies`): Strata's own commands change the server, then the folder is listed again.
/// New Folder, Rename, Delete (there's no Trash on a server, so it asks first), Paste and dropping files copy onto the
/// server; moving within a server renames there. Duplicate, Compress, tags and the like stay off.
extension BrowserViewController {
    /// The folder shown (or the column with focus) is on a saved server, and so is everything selected. (Not Strata's
    /// Servers folder itself, nor what a removed server left behind.)
    var isOnServer: Bool {
        let copies = services.remote.copies
        guard let target = targetDirectory, copies.server(containing: target) != nil else { return false }
        return selectedURLs.allSatisfy { copies.server(containing: $0) != nil }
    }

    /// The kind of server this pane shows, if any (Open in Terminal: a shell over ssh, none for a bucket).
    var serverKind: RemoteServer.Kind? {
        targetDirectory.flatMap { services.remote.copies.server(containing: $0)?.server.kind }
    }

    /// Whether `url` is a server's own top folder (its `/`), which can't be renamed or deleted.
    static func isServerTop(_ url: URL, copies: RemoteCopyStore = RemoteCopies.store) -> Bool {
        guard let (_, top) = copies.server(containing: url) else { return false }
        return top.standardizedFileURL == url.standardizedFileURL
    }

    static func serverDeletionTargets(_ urls: [URL], copies: RemoteCopyStore = RemoteCopies.store) -> [URL] {
        outermost(urls).filter { copies.server(containing: $0) != nil && !isServerTop($0, copies: copies) }
    }

    private var serverName: String {
        targetDirectory.flatMap { services.remote.copies.server(containing: $0)?.server.name } ?? ""
    }

    /// A new "untitled folder" on the server, then renaming it right away, as on this Mac.
    func newFolderOnServer(in folder: URL) {
        let existing = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
        let base = FileOps.nameText(String(localized: "untitled folder", comment: "Name of a new folder, as Finder names it"), english: "untitled folder")
        var name = base
        var number = 2
        while existing.contains(name.lowercased()) {
            name = "\(base) \(number)"
            number += 1
        }
        let files = services.remote.files
        runOnServer(in: folder) { [weak self] in
            let made = try await files.makeFolder(named: name, in: folder)
            self?.renameWhenShown(made, in: folder)
        }
    }

    /// An empty "untitled.txt" on the server, like New File on this Mac.
    func newFileOnServer(in folder: URL) {
        let name = newFileNameOnServer(in: folder)
        let files = services.remote.files
        runOnServer(in: folder) { [weak self] in
            let made = try await files.makeFile(named: name, in: folder)
            self?.renameWhenShown(made, in: folder)
        }
    }

    /// Choose a name from this pane's settings and listing before starting the server write.
    func newFileNameOnServer(in folder: URL) -> String {
        let existing = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
        let ext = preferences.newFileExtension
        let base = FileOps.newFileName(extension: "")
        var name = FileOps.newFileName(extension: ext)
        var number = 2
        while existing.contains(name.lowercased()) {
            name = FileOps.newFileName(extension: ext, stem: "\(base) \(number)")
            number += 1
        }
        return name
    }

    func renameOnServer(_ url: URL, to name: String) {
        let copies = services.remote.copies
        guard !Self.isServerTop(url, copies: copies) else { return Sounds.beep() }
        let folder = url.deletingLastPathComponent()
        let files = services.remote.files
        runOnServer(in: folder) { [weak self] in
            let renamed = try await files.rename(url, to: name)
            guard let self else { return }
            if Self.key(folder) == self.targetDirectory.map(Self.key) { self.pendingSelection = [renamed] }
            self.refresh()
        }
    }

    /// Asks (a server has no Trash), then deletes for good.
    func deleteOnServer(_ urls: [URL]) {
        let copies = services.remote.copies
        let urls = Self.serverDeletionTargets(urls, copies: copies)
        guard !urls.isEmpty, let window = view.window else { return Sounds.beep() }
        let expected = Dictionary(urls.compactMap { copies.server(containing: $0).map { ($0.server.id, $0.server) } },
                                  uniquingKeysWith: { first, _ in first })
        let serverName = copies.server(containing: urls[0])?.server.name ?? serverName
        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? String(localized: "Delete “\(urls[0].lastPathComponent)” from “\(serverName)”?", comment: "An item, then a server's name")
            : String(localized: "Delete \(urls.count) items from “\(serverName)”?", comment: "plural; then a server's name")
        alert.informativeText = String(localized: "There’s no Trash on a server: this can’t be undone.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Delete", comment: "Alert button: delete for good"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let currentCopies = self.services.remote.copies
                guard urls.allSatisfy({ url in
                    guard let (server, _) = currentCopies.server(containing: url) else { return false }
                    return expected[server.id] == server
                }) else { return }
                let files = self.services.remote.files
                self.runOnServer(in: urls[0].deletingLastPathComponent()) { [weak self] in
                    try await files.delete(urls, expected: expected)
                    self?.refresh()
                }
            }
        }
    }

    /// Copies `urls` onto the server's `folder`; `move` from the same server renames them there instead (nothing is
    /// downloaded). Anything else is copied: from this Mac, a container or another server (read in full first), and
    /// what's elsewhere stays. Names already on the server (asked of the server, not the copy) are asked about once:
    /// replace them, or skip them.
    func copyToServer(_ urls: [URL], into folder: URL, move: Bool) {
        guard !urls.isEmpty else { return }
        let copies = services.remote.copies
        let files = services.remote.files
        let expected = copies.server(containing: folder)?.server
        let server = expected?.id
        if move, let server, urls.allSatisfy({ copies.server(containing: $0)?.server.id == server }) {
            return runOnServer(in: folder) { [weak self] in
                let moved = try await files.move(urls, into: folder, expected: expected)
                guard let self else { return }
                if folder.standardizedFileURL == self.targetDirectory?.standardizedFileURL, !moved.isEmpty { self.pendingSelection = moved }
                self.refresh()
            }
        }
        runOnServer(in: folder) { [weak self] in
            let existing = try await files.names(in: folder, expected: expected)
            self?.askAndUpload(urls, into: folder, expected: expected, clashing: urls.map(\.lastPathComponent).filter(existing.contains))
        }
    }

    enum UploadChoice: Equatable {
        case upload(skipping: Set<String>)
        case ask
    }

    /// Whether to ask before copying into a server folder where `clashing` names are already taken. Replacing there
    /// can't be undone: with no window to ask in (it closed while the names were read), what's there stays and only
    /// the rest is copied.
    static func uploadChoice(clashing: [String], canAsk: Bool) -> UploadChoice {
        guard !clashing.isEmpty else { return .upload(skipping: []) }
        return canAsk ? .ask : .upload(skipping: Set(clashing))
    }

    private func askAndUpload(_ urls: [URL], into folder: URL, expected: RemoteServer?, clashing: [String]) {
        if let expected, services.remote.copies.server(containing: folder)?.server != expected { return }
        let upload = { [weak self, services] (skipping: Set<String>) in
            if let expected, services.remote.copies.server(containing: folder)?.server != expected { return }
            let job = RemoteUploadJob(urls, into: folder, skipping: skipping, expected: expected,
                                      files: services.remote.files, copies: services.copies)
            job.onFinish = { job in
                guard let self else { return }
                if folder.standardizedFileURL == self.targetDirectory?.standardizedFileURL, !job.createdItems.isEmpty {
                    self.pendingSelection = job.createdItems
                }
                self.refresh()
            }
            services.transfers.add(job)
        }
        let window = view.window
        if case .upload(let skipping) = Self.uploadChoice(clashing: clashing, canAsk: window != nil) { return upload(skipping) }
        guard let window else { return }
        let serverName = services.remote.copies.server(containing: folder)?.server.name ?? serverName
        let alert = NSAlert()
        alert.messageText = clashing.count == 1
            ? String(localized: "“\(clashing[0])” is already on “\(serverName)”", comment: "An item, then a server's name")
            : String(localized: "\(clashing.count) of these items are already on “\(serverName)”", comment: "plural; then a server's name")
        alert.informativeText = String(localized: "Replacing them can’t be undone; a folder is merged with the one that’s there.")
        alert.addButton(withTitle: String(localized: "Replace", comment: "Alert button: copy over what's on the server"))
        alert.addButton(withTitle: String(localized: "Skip", comment: "Alert button: leave what's on the server, copy the rest"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: upload([])
            case .alertSecondButtonReturn: upload(Set(clashing))
            default: break
            }
        }
    }

    /// Open in Terminal on an SFTP server: an ssh session (your terminal app) that starts in the folder shown or the one
    /// selected. Off for a bucket. True when the folder is a server's (opened, or refused with a beep).
    func openTerminalOnServer() -> Bool {
        let selected = selectedEntries
        let folder = selected.count == 1 && selected[0].isFolder ? selected[0].url : targetDirectory
        let copies = services.remote.copies
        guard let folder, let (server, top) = copies.server(containing: folder) else { return false }
        guard server.kind == .sftp, let path = RemoteCopies.remotePath(of: folder.resolvingSymlinksInPath(), top: top),
              ProjectActions.openCommandFile(named: "\(server.name) — Terminal", body: server.terminalScript(path: path)) else {
            Sounds.beep()
            return true
        }
        return true
    }

    /// Runs a change on the server; what went wrong is said in a sheet, and the folder is shown as the server has it.
    private func runOnServer(in folder: URL? = nil, _ body: @escaping () async throws -> Void) {
        let target = folder ?? targetDirectory
        let expected = target.flatMap { services.remote.copies.server(containing: $0)?.server }
        let serverName = expected?.name ?? ""
        commandWork = Task { [weak self] in
            do {
                if let target, let expected, self?.services.remote.copies.server(containing: target)?.server != expected {
                    return
                }
                try await body()
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                if let window = self.viewIfLoaded?.window, window.isVisible, window.attachedSheet == nil {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "“\(serverName)” couldn’t make that change", comment: "A server's name")
                    alert.informativeText = RemoteFiles.message(for: error)
                    alert.beginSheetModal(for: window, completionHandler: nil)
                }
                self.refresh()
            }
        }
    }
}
