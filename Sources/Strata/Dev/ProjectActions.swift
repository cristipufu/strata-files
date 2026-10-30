import AppKit

// MARK: - Loading

extension ProjectInfo {
    /// Sizes measured in the last minute, so flipping the selection back to a project doesn't re-walk node_modules.
    private static var sizeCache: [String: (bytes: Int64, files: Int, date: Date)] = [:]
    private static let sizeCacheLifetime: TimeInterval = 60
    private static let sharedSizer = FolderSizer()

    /// Everything the project inspector needs for `folder`, or nil when it's neither a project nor a repository root.
    ///
    /// Detection runs off the main thread; git status comes from `store` (usually already cached by the browser);
    /// artifacts git tracks are dropped (a committed `bin/` is not a build artifact). `onUpdate` receives the result
    /// before sizes are known, so the inspector can show it immediately; the return value has sizes. Cancel the
    /// calling task when the selection changes: the size walks stop and nil is returned.
    static func load(for folder: URL, store: GitStatusStore = .shared,
                     onUpdate: ((ProjectInfo) -> Void)? = nil) async -> ProjectInfo? {
        let folder = folder.standardizedFileURL
        var info = await ProjectDetector.detect(folder)
        let repository = await store.repositoryFound(containing: folder)
        let isRoot = repository?.rootPath == folder.path
        guard info.isProject || isRoot, !Task.isCancelled else { return nil }

        if let repository, let snapshot = await store.status(of: repository) {
            info.git = ProjectGitSummary(snapshot, folder: folder)
            info.artifacts = await untrackedArtifacts(info.artifacts, snapshot: snapshot, timeout: store.timeout)
        }
        guard !Task.isCancelled else { return nil }

        // Sizes already known: measured here recently, or by the list's size column.
        let now = Date()
        for index in info.artifacts.indices {
            let paths = info.artifacts[index].urls.map(\.path)
            if paths.allSatisfy({ sizeCache[$0].map { now.timeIntervalSince($0.date) < sizeCacheLifetime } ?? false }) {
                info.artifacts[index].bytes = paths.compactMap { sizeCache[$0]?.bytes }.saturatingSum
                info.artifacts[index].files = paths.reduce(0) { $0 + (sizeCache[$1]?.files ?? 0) }
            } else if info.artifacts[index].urls.count == 1, let size = sharedSizer.cached(info.artifacts[index].urls[0]) {
                info.artifacts[index].bytes = size.bytes
                info.artifacts[index].files = size.files
            }
        }
        guard info.isMeasuring else { return info }
        onUpdate?(info)

        info.artifacts = await ProjectDetector.measure(info.artifacts)
        guard !Task.isCancelled else { return nil }
        for artifact in info.artifacts where artifact.urls.count == 1 {
            if let bytes = artifact.bytes, let files = artifact.files {
                sizeCache[artifact.urls[0].path] = (bytes, files, Date())
            }
        }
        return info
    }

    /// The same info with the git summary taken from the store's current snapshot. No I/O: use it when
    /// `.gitStatusDidChange` fires instead of reloading (which could re-measure artifacts).
    func withCurrentGit(store: GitStatusStore = .shared) -> ProjectInfo {
        guard let repository = store.repository(containing: folder), let snapshot = store.snapshot(for: repository.root) else {
            return self
        }
        var copy = self
        copy.git = ProjectGitSummary(snapshot, folder: folder)
        return copy
    }

    /// Forgets measured sizes under `folder` (after cleaning, or a reload).
    static func invalidateSizes(under folder: URL) {
        let prefix = folder.standardizedFileURL.path + "/"
        sizeCache = sizeCache.filter { !$0.key.hasPrefix(prefix) }
    }

    /// Keeps only folders git doesn't track. Ignored or untracked per the snapshot is enough; anything else is checked
    /// with one `git ls-files`, and dropped if that check fails (never offer to delete what we couldn't verify).
    private static func untrackedArtifacts(_ artifacts: [ProjectArtifact], snapshot: GitStatusSnapshot,
                                           timeout: TimeInterval) async -> [ProjectArtifact] {
        var unknown: [String] = []
        for artifact in artifacts {
            for url in artifact.urls {
                guard let path = snapshot.relativePath(url), !path.isEmpty else { continue }
                if !snapshot.isUntrackedOrIgnored(relativePath: path) { unknown.append(path) }
            }
        }
        let tracked: Set<String>
        if unknown.isEmpty {
            tracked = []
        } else {
            tracked = await GitStatusLoader.trackedPaths(unknown, in: snapshot.repository, timeout: timeout) ?? Set(unknown)
        }
        return artifacts.compactMap { artifact in
            let urls = artifact.urls.filter { url in
                guard let path = snapshot.relativePath(url) else { return true }
                return !tracked.contains(path)
            }
            guard !urls.isEmpty else { return nil }
            return ProjectArtifact(name: artifact.name, urls: urls, kind: artifact.kind, role: artifact.role,
                                   bytes: urls.count == artifact.urls.count ? artifact.bytes : nil, files: nil)
        }
    }
}

// MARK: - Actions

enum ProjectActions {
    /// Asks before moving `artifacts` to the Trash (sheet on `window`), then trashes them with undo. Calls
    /// `completion` with the trashed folders (empty when cancelled or failed).
    static func confirmClean(_ artifacts: [ProjectArtifact], window: NSWindow,
                             files: BrowserFileCommands,
                             completion: @escaping ([URL]) -> Void) {
        guard !artifacts.isEmpty else { return completion([]) }
        let total = artifacts.compactMap(\.bytes).saturatingSum
        let alert = NSAlert()
        let count = artifacts.reduce(0) { $0 + $1.urls.count }
        alert.messageText = count == 1
            ? String(localized: "Move “\(artifacts[0].name)” to the Trash?")
            : String(localized: "Move \(count) build folders to the Trash?", comment: "plural")
        let lines = artifacts.map { artifact -> String in
            let size = artifact.bytes.map { " — " + Format.bytes($0) } ?? ""
            let multiple = artifact.urls.count > 1
                ? " (" + String(localized: "\(artifact.urls.count) folders", comment: "plural") + ")" : ""
            return "• \(artifact.name)\(multiple)\(size)"
        }
        let hasEnvironment = artifacts.contains { $0.role == .environment }
        // Sizes still being measured make any total an understatement.
        let measured = artifacts.allSatisfy { $0.bytes != nil }
        var sentences: [String] = []
        if measured {
            sentences.append(String(localized: "Frees \(Format.bytes(total)).", comment: "Placeholder: a size, e.g. 1.2 GB"))
        } else if total > 0 {
            sentences.append(String(localized: "Frees at least \(Format.bytes(total)).", comment: "Placeholder: a size, e.g. 1.2 GB"))
        }
        sentences.append(hasEnvironment
            ? String(localized: "They’re rebuilt by the next install or build; virtual environments need to be recreated.")
            : String(localized: "They’re rebuilt by the next install or build."))
        sentences.append(String(localized: "You can undo this with ⌘Z."))
        alert.informativeText = lines.joined(separator: "\n") + "\n\n" + sentences.joined(separator: " ")
        alert.alertStyle = .warning
        let trash = alert.addButton(withTitle: String(localized: "Move to Trash"))
        trash.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak window] response in
            guard response == .alertFirstButtonReturn, let window else { return completion([]) }
            let undo = window.undoManager
            Task { [weak window] in
                do {
                    let urls = artifacts.flatMap(\.urls)
                    try await files.trash(urls, undo: undo)
                    completion(urls)
                } catch {
                    if let window { NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil) }
                    completion([])
                }
            }
        }
    }

    /// Opens a terminal in the script's folder and runs it, leaving an interactive shell open afterwards.
    ///
    /// Writes a self-deleting `.command` file and opens it with the preferred terminal (Ghostty, iTerm, Warp, then
    /// Terminal) that can open `.command` files. No AppleScript, so no Automation permission prompt. Trade-offs: the
    /// window title shows the temporary file's name; the command runs through `$SHELL -lic` so it sees the same PATH
    /// as your interactive shell (nvm, Homebrew), which costs one rc-file load.
    @discardableResult
    static func runInTerminal(_ script: ProjectScript, projectName: String? = nil) -> Bool {
        let project = projectName ?? script.directory.lastPathComponent
        return openCommandFile(named: "\(project) — \(script.name)", body: commandFile(for: script))
    }

    /// Writes `body` (a `/bin/sh` script that deletes itself first) to a `.command` file and opens it in the preferred
    /// terminal. `name` is the file's name, which the terminal shows as the window's title.
    @discardableResult
    static func openCommandFile(named name: String, body: String) -> Bool {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Strata Scripts", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        removeStaleCommandFiles(in: folder)
        // A folder of its own: two opened at once never overwrite each other.
        let own = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: own, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = own.appending(path: sanitize(name) + ".command")
        do {
            try body.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            return false
        }
        guard let terminal = preferredTerminal(for: file) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: configuration)
        return true
    }

    /// The `.command` file body: cd, echo the command, run it in a login+interactive shell, then stay in a shell.
    static func commandFile(for script: ProjectScript) -> String {
        let directory = ShellQuote.quote(script.directory.path)
        let invocation = script.invocation
        return """
        #!/bin/sh
        # Written by Strata to run a project script. Deletes itself; safe to remove.
        rm -f -- "$0"
        cd \(directory) || exit 1
        printf '\\033[2m%s\\033[0m\\n' \(ShellQuote.quote("$ " + invocation))
        "${SHELL:-/bin/zsh}" -lic \(ShellQuote.quote(invocation))
        exec "${SHELL:-/bin/zsh}" -l

        """
    }

    static let terminalBundleIDs = ["com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.apple.Terminal"]

    /// First installed terminal from `terminalBundleIDs` that declares it can open `file`; Terminal as the fallback.
    static func preferredTerminal(for file: URL) -> URL? {
        let capable = Set(NSWorkspace.shared.urlsForApplications(toOpen: file).map(\.standardizedFileURL))
        for id in terminalBundleIDs {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id), capable.contains(app.standardizedFileURL) {
                return app
            }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
    }

    /// A `.command` file name every terminal can open: plain ASCII letters, digits, spaces, dots, dashes and
    /// underscores. (Ghostty garbles other characters in the path it runs, an em dash included, and then can't find the
    /// file.)
    static func sanitize(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        let kept = folded.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || " ._-".unicodeScalars.contains(scalar)) ? Character(scalar) : "-"
        }
        // Runs of replaced characters become one dash; no leading dot (a hidden file) or dash.
        let text = String(kept).replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        return text.isEmpty ? "Strata" : String(text.prefix(80))
    }

    /// The files delete themselves when they run; this catches any that never ran (each in a folder of its own, left
    /// for an hour). Anything else in `folder` is removed as itself, never through a link.
    static func removeStaleCommandFiles(in folder: URL) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}
