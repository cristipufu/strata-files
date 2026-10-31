import AppKit
import CoreServices

/// Starting, stopping… containers, and shells in them, the same way from every place that offers it (the context menu,
/// the Inspector, the Compose card, the command palette).
enum ContainerControl {
    /// Does `action` to `containers` (those it applies to). Stopping, restarting or pausing several asks first; what
    /// fails is shown, with the engine's reason.
    static func run(_ action: ContainerAction, on containers: [ContainerInfo], in window: NSWindow?,
                    store: ContainerStore) {
        let targets = containers.filter { action.applies(to: $0.state) && store.busy[$0.id] == nil }
        guard !targets.isEmpty else { return Sounds.beep() }
        let go = {
            Task {
                let failures = await store.perform(action, on: targets)
                guard !failures.isEmpty else { return }
                let alert = NSAlert()
                alert.messageText = failures.count == 1
                    ? String(localized: "“\(failures[0].name)” couldn’t be changed.", comment: "A container action (start, stop…) failed")
                    : String(localized: "\(failures.count) containers couldn’t be changed.", comment: "plural")
                alert.informativeText = failures.map { failures.count == 1 ? $0.message : "\($0.name): \($0.message)" }.joined(separator: "\n")
                BrowserViewController.present(alert, in: window) { _ in }
            }
        }
        guard targets.count > 1, action == .stop || action == .restart || action == .pause else { return _ = go() }
        let alert = NSAlert()
        alert.messageText = switch action {
        case .stop: String(localized: "Stop \(targets.count) containers?", comment: "plural")
        case .restart: String(localized: "Restart \(targets.count) containers?", comment: "plural")
        default: String(localized: "Pause \(targets.count) containers?", comment: "plural")
        }
        alert.informativeText = ListFormatter.localizedString(byJoining: targets.prefix(8).map(\.name))
            + (targets.count > 8 ? "…" : "")
        alert.addButton(withTitle: title(action))
        alert.addButton(withTitle: String(localized: "Cancel"))
        BrowserViewController.present(alert, in: window) { response in
            if response == .alertFirstButtonReturn { _ = go() }
        }
    }

    static func title(_ action: ContainerAction) -> String {
        switch action {
        case .start: String(localized: "Start", comment: "Container action")
        case .stop: String(localized: "Stop", comment: "Container action")
        case .restart: String(localized: "Restart", comment: "Container action")
        case .pause: String(localized: "Pause", comment: "Container action")
        case .unpause: String(localized: "Resume", comment: "Container action: unpause")
        }
    }

    static func symbol(_ action: ContainerAction) -> String {
        switch action {
        case .start: "play.fill"
        case .stop: "stop.fill"
        case .restart: "arrow.clockwise"
        case .pause: "pause.fill"
        case .unpause: "playpause.fill"
        }
    }

    /// What the container is doing while `action` runs ("Stopping…").
    static func progress(_ action: ContainerAction) -> String {
        switch action {
        case .start: String(localized: "Starting…", comment: "A container being started")
        case .unpause: String(localized: "Resuming…", comment: "A paused container being resumed")
        case .stop: String(localized: "Stopping…", comment: "A container being stopped")
        case .restart: String(localized: "Restarting…", comment: "A container being restarted")
        case .pause: String(localized: "Pausing…", comment: "A container being paused")
        }
    }

    /// The actions that make sense for `containers` together (any of them), in menu order.
    static func actions(for containers: [ContainerInfo]) -> [ContainerAction] {
        ContainerAction.allCases.filter { action in containers.contains { action.applies(to: $0.state) } }
    }

    /// Opens a shell in a running container, in its folder `path`, in your terminal (as `docker exec -it` would).
    @discardableResult
    static func openTerminal(in container: ContainerInfo, at path: String, engine: ContainerEngine) -> Bool {
        guard container.isRunning, ContainerAPI.isContainerID(container.id) else { return false }
        return ProjectActions.openCommandFile(named: "\(container.name) — Terminal", body: terminalScript(id: container.id, path: path, socket: engine.socket))
    }

    /// The `.command` file's script, run by `/bin/sh`: it deletes itself, takes the PATH your login shell sets up (so
    /// `docker` from Homebrew, OrbStack or Docker Desktop is found; the shell only runs a fixed `printenv`, whatever
    /// shell it is), then runs bash, else sh, in the container with `docker` (pointed at the engine Strata shows) or
    /// else `podman`. Every value is quoted for `/bin/sh` on its own; the container ID is hex.
    static func terminalScript(id: String, path: String, socket: String) -> String {
        let shell = "command -v bash >/dev/null 2>&1 && exec bash || exec sh"
        let folder = ShellQuote.quote(path.isEmpty ? "/" : path)
        let host = ShellQuote.quote("unix://" + socket)
        let missing = ShellQuote.quote(String(localized: "Strata needs the docker command for this.", comment: "Shown in Terminal when docker isn't installed"))
        return """
        #!/bin/sh
        # Written by Strata to open a shell in a container. Deletes itself; safe to remove.
        rm -f -- "$0"
        login=$("${SHELL:-/bin/zsh}" -l -i -c '/usr/bin/printenv PATH | /usr/bin/sed "s/^/STRATA_PATH=/"' </dev/null 2>/dev/null | /usr/bin/sed -n 's/^STRATA_PATH=//p' | /usr/bin/tail -n 1)
        PATH="${login:+$login:}$HOME/.orbstack/bin:$HOME/.rd/bin:/opt/homebrew/bin:/usr/local/bin:/opt/podman/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin"
        export PATH
        if command -v docker >/dev/null 2>&1; then
          DOCKER_HOST=\(host) exec docker exec -it -w \(folder) \(id) /bin/sh -c \(ShellQuote.quote(shell))
        elif command -v podman >/dev/null 2>&1; then
          exec podman --url \(host) exec -it -w \(folder) \(id) /bin/sh -c \(ShellQuote.quote(shell))
        fi
        echo \(missing)
        exec "${SHELL:-/bin/zsh}" -l

        """
    }
}

/// The folder on this Mac a Compose project was launched from.
enum StackProjects {
    static func workingDirectory(of url: URL, copies: ContainerCopyStore,
                                 store: ContainerStore) -> URL? {
        guard copies.isStack(url) else { return nil }
        let name = url.lastPathComponent
        guard let path = store.containers.lazy.compactMap({ container -> String? in
            guard let compose = container.compose,
                  compose.project.compare(name, options: [.caseInsensitive]) == .orderedSame,
                  compose.workingDirectory?.hasPrefix("/") == true else { return nil }
            return compose.workingDirectory
        }).first else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// Those of `folders` that are folders on this Mac. The paths come from the containers' labels, which an image can
    /// set, so each is checked to be a plain folder before Terminal or an editor is asked to open it: Terminal *runs*
    /// a script it's given, and an app would launch.
    @concurrent static func existing(_ folders: [URL]) async -> [URL] {
        folders.filter(FileEntry.isNavigableFolder)
    }

    /// Hands `open` those of `directories` that are folders on this Mac when asked, or beeps when none is.
    @discardableResult
    static func open(_ directories: [URL], with open: @escaping ([URL]) -> Void) -> Task<Void, Never> {
        Task {
            let folders = await existing(directories)
            guard !folders.isEmpty else { return Sounds.beep() }
            open(folders)
        }
    }
}

/// Code editors installed on this Mac: the well-known ones, and any other developer tool that opens source code.
enum ProjectEditors {
    /// Opens `folder` in `app`.
    static func open(_ folder: URL, with app: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: configuration)
    }

    /// Editors to offer, by name, with their icons: as last read, read again away from the main thread once that's
    /// over 30 seconds old (asking LaunchServices about every editor takes a moment). Only an ask before the first
    /// read has finished waits for it.
    static func installed() async -> [OpenWithApp] {
        if let cached {
            if Date() >= cached.until { warm() }
            return cached.apps
        }
        warm()
        await reading?.value
        return cached?.apps ?? []
    }

    private static var reading: Task<Void, Never>?

    /// Reads them away from the main thread, so the next ask finds them.
    static func warm() {
        guard reading == nil else { return }
        reading = Task {
            let apps = await findOffMain()
            cached = (apps, Date().addingTimeInterval(30))
            reading = nil
        }
    }

    @concurrent private static func findOffMain() async -> [OpenWithApp] {
        find().map(OpenWithApp.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated private static func find() -> [URL] {
        var ids = Set(knownIDs)
        if let handlers = LSCopyAllRoleHandlersForContentType("public.swift-source" as CFString, .editor)?.takeRetainedValue() as? [String] {
            ids.formUnion(handlers)
        }
        var seen = Set<String>()
        var apps: [URL] = []
        for id in ids {
            for app in NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id) {
                let url = app.standardizedFileURL
                guard seen.insert(url.path).inserted else { continue }
                let bundle = Bundle(url: url)
                let category = bundle?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
                guard includes(bundleID: bundle?.bundleIdentifier ?? id, category: category) else { continue }
                apps.append(url)
            }
        }
        return apps
    }

    /// Whether an app that claims to edit source is one to offer. Office apps and chat apps also claim source files.
    nonisolated static func includes(bundleID: String, category: String?) -> Bool {
        if skipped.contains(bundleID) { return false }
        if knownIDs.contains(bundleID) || prefixes.contains(where: { bundleID.hasPrefix($0) }) { return true }
        return category == "public.app-category.developer-tools"
    }

    private static var cached: (apps: [OpenWithApp], until: Date)?

    nonisolated private static let skipped: Set<String> = [
        "com.anthropic.claudefordesktop", "com.apple.dt.Instruments", "com.apple.ScriptEditor2",
    ]

    /// Prefixes, so a new version (`com.sublimetext.4`, `com.jetbrains.pycharm.ce`) is picked up without being listed.
    nonisolated private static let prefixes = [
        "com.microsoft.VSCode", "com.visualstudio.code", "com.vscodium", "com.todesktop.", "com.exafunction.",
        "com.codeium.", "dev.zed.", "com.sublimetext.", "com.jetbrains.", "com.google.android.studio",
        "com.google.antigravity", "com.apple.dt.Xcode", "com.panic.Nova", "com.barebones.bbedit", "com.macromates.",
        "com.coteditor.", "com.trae.", "dev.kiro.", "com.kiro.", "com.neovide.", "com.github.atom",
    ]

    nonisolated private static let knownIDs = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.visualstudio.code.oss",
        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed", "com.apple.dt.Xcode",
        "com.sublimetext.4", "com.sublimetext.3", "com.panic.Nova", "com.barebones.bbedit", "com.macromates.TextMate",
        "com.coteditor.CotEditor", "com.google.android.studio", "com.google.antigravity-ide",
        "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce",
        "com.jetbrains.WebStorm", "com.jetbrains.PhpStorm", "com.jetbrains.goland", "com.jetbrains.CLion",
        "com.jetbrains.rider", "com.jetbrains.rustrover", "com.jetbrains.datagrip", "com.jetbrains.rubymine",
    ]
}
