import Foundation

// MARK: - Model

nonisolated enum ProjectKind: String, Sendable, CaseIterable {
    case node, rust, swift, dotnet, python, go, ruby, jvm, godot, docker, terraform

    var title: String {
        switch self {
        case .node: return "Node"
        case .rust: return "Rust"
        case .swift: return "Swift"
        case .dotnet: return ".NET"
        case .python: return "Python"
        case .go: return "Go"
        case .ruby: return "Ruby"
        case .jvm: return "JVM"
        case .godot: return "Godot"
        case .docker: return "Docker"
        case .terraform: return "Terraform"
        }
    }

    /// Generic SF Symbols (no brand marks).
    var symbolName: String {
        switch self {
        case .node: return "hexagon"
        case .rust: return "gearshape"
        case .swift: return "swift"
        case .dotnet: return "number"
        case .python: return "lizard"
        case .go: return "hare"
        case .ruby: return "diamond"
        case .jvm: return "cup.and.saucer"
        case .godot: return "gamecontroller"
        case .docker: return "shippingbox"
        case .terraform: return "square.stack.3d.up"
        }
    }
}

nonisolated struct ProjectKindInfo: Sendable, Hashable {
    let kind: ProjectKind
    /// Package manager or build system, e.g. "pnpm", "Gradle", "Xcode".
    var detail: String?
}

nonisolated struct ProjectArtifact: Sendable, Hashable, Identifiable {
    enum Role: Sendable, Hashable {
        /// Build output: target, .build, bin/obj, .next…
        case build
        /// Tool caches: .turbo, .pytest_cache, .gradle…
        case cache
        /// Installed dependencies: node_modules, vendor/bundle, .terraform.
        case dependencies
        /// Virtual environments: regenerable, but slow to rebuild and easy to forget how. Not selected by default.
        case environment
    }

    /// What the row shows: the folder name, or a short relative path ("Billing.Api/bin").
    let name: String
    /// Usually one folder; scattered ones (`__pycache__`) are grouped.
    let urls: [URL]
    let kind: ProjectKind
    let role: Role
    var bytes: Int64?
    var files: Int?

    var id: String { name }
    var isSelectedByDefault: Bool { role != .environment }
    var isMeasured: Bool { bytes != nil }
}

nonisolated struct ProjectScript: Sendable, Hashable, Identifiable {
    enum Runner: String, Sendable, Hashable {
        case npm, yarn, pnpm, bun, make, just, cargo
    }

    let name: String
    /// What it runs: the package.json script body, or the first recipe line. May be empty.
    let command: String
    /// Prose describing it, when the file has some: a Makefile `## help` comment or a justfile doc comment.
    var summary: String? = nil
    let runner: Runner
    /// Where to run it.
    let directory: URL
    /// The file it came from, for grouping: "package.json", "Makefile", "justfile", ".cargo/config.toml".
    let source: String

    var id: String { source + "/" + name }

    /// The shell command that runs it, with the name quoted when it needs to be.
    var invocation: String {
        let quoted = ShellQuote.quoteIfNeeded(name)
        switch runner {
        case .npm, .pnpm, .bun: return "\(runner.rawValue) run \(quoted)"
        case .yarn: return "yarn run \(quoted)"
        case .make: return "make \(quoted)"
        case .just: return "just \(quoted)"
        case .cargo: return "cargo \(quoted)"
        }
    }
}

nonisolated struct ProjectGitSummary: Sendable, Equatable {
    let branch: GitBranchInfo
    let operation: GitOperation?
    /// Changes inside the project folder (the whole repository when it's the root).
    let counts: GitStatusCounts
    let isRepositoryRoot: Bool
    let stashCount: Int
    let outcome: GitStatusSnapshot.Outcome

    init(_ snapshot: GitStatusSnapshot, folder: URL) {
        let relative = snapshot.relativePath(folder) ?? ""
        branch = snapshot.branch
        operation = snapshot.operation
        counts = snapshot.counts(inside: relative)
        isRepositoryRoot = relative.isEmpty
        stashCount = snapshot.stashCount
        outcome = snapshot.outcome
    }
}

/// Everything the project inspector shows for a folder. Built by `ProjectInfo.load(for:)`; the view never scans.
nonisolated struct ProjectInfo: Sendable {
    let folder: URL
    var kinds: [ProjectKindInfo]
    var artifacts: [ProjectArtifact]
    var scripts: [ProjectScript]
    var git: ProjectGitSummary?

    /// Some artifact sizes are still being measured.
    var isMeasuring: Bool { artifacts.contains { !$0.isMeasured } }
    var isProject: Bool { !kinds.isEmpty || !scripts.isEmpty }
}

// MARK: - Detection

/// Detects project kinds, regenerable artifact folders and runnable scripts from marker files. Reads one directory
/// listing plus the few small files that hold scripts; never walks deep trees (except a bounded search for
/// `__pycache__` and .NET project folders).
nonisolated enum ProjectDetector {
    @concurrent
    static func detect(_ folder: URL) async -> ProjectInfo {
        detectSync(folder)
    }

    static func detectSync(_ folder: URL) -> ProjectInfo {
        var detection = Detection(folder: folder)
        detection.node()
        detection.rust()
        detection.swift()
        detection.dotnet()
        detection.python()
        detection.others()
        detection.taskRunners()
        return ProjectInfo(folder: folder, kinds: detection.kinds, artifacts: detection.artifacts,
                           scripts: detection.scripts, git: nil)
    }

    /// One folder's detection: its listing, read once, and what each kind of project found in it.
    private struct Detection {
        let folder: URL
        let names: Set<String>
        var kinds: [ProjectKindInfo] = []
        var artifacts: [ProjectArtifact] = []
        var scripts: [ProjectScript] = []
        private var seen: Set<String> = []

        init(folder: URL) {
            self.folder = folder
            names = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        }

        private func has(_ name: String) -> Bool { names.contains(name) }

        private func withExtension(_ exts: Set<String>) -> [String] {
            names.filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
        }

        private mutating func addArtifact(_ relative: String, _ kind: ProjectKind, _ role: ProjectArtifact.Role) {
            let url = folder.appending(path: relative, directoryHint: .isDirectory)
            // Every folder on the way must be real: a symlinked parent ("vendor" → elsewhere) would put the
            // artifact outside the project.
            var step = folder
            for part in relative.split(separator: "/") {
                step = step.appending(path: String(part), directoryHint: .isDirectory)
                guard isRealDirectory(step.path) else { return }
            }
            guard seen.insert(url.path).inserted else { return }
            artifacts.append(ProjectArtifact(name: relative, urls: [url], kind: kind, role: role))
        }

        mutating func node() {
            guard has("package.json") else { return }
            let package = readJSON(folder.appending(path: "package.json"))
            let manager = nodeManager(folder, names: names, package: package.object)
            kinds.append(ProjectKindInfo(kind: .node, detail: manager.rawValue))
            addArtifact("node_modules", .node, .dependencies)
            for name in [".next", ".nuxt", ".output", ".svelte-kit"] { addArtifact(name, .node, .build) }
            for name in [".turbo", ".parcel-cache", ".angular", ".vite"] { addArtifact(name, .node, .cache) }
            scripts += packageScripts(package, runner: manager, directory: folder)
        }

        mutating func rust() {
            guard has("Cargo.toml") else { return }
            kinds.append(ProjectKindInfo(kind: .rust, detail: "Cargo"))
            addArtifact("target", .rust, .build)
            scripts += cargoAliases(folder)
        }

        mutating func swift() {
            let xcodeProjects = withExtension(["xcodeproj", "xcworkspace"])
            guard has("Package.swift") || !xcodeProjects.isEmpty else { return }
            kinds.append(ProjectKindInfo(kind: .swift, detail: has("Package.swift") ? "SwiftPM" : "Xcode"))
            if has("Package.swift") {
                addArtifact(".build", .swift, .build)
                addArtifact(".swiftpm", .swift, .cache)
            }
            addArtifact("DerivedData", .swift, .build)
        }

        /// bin/obj next to each project file; from a solution, also the projects up to two levels down.
        mutating func dotnet() {
            let projectFiles = withExtension(["csproj", "fsproj", "vbproj"])
            let solutions = withExtension(["sln", "slnx"])
            guard !projectFiles.isEmpty || !solutions.isEmpty else { return }
            kinds.append(ProjectKindInfo(kind: .dotnet, detail: solutions.isEmpty ? nil
                : String(localized: "Solution", comment: "A .NET project that has a Visual Studio solution file (.sln)")))
            if !projectFiles.isEmpty {
                addArtifact("bin", .dotnet, .build)
                addArtifact("obj", .dotnet, .build)
            }
            if !solutions.isEmpty {
                for project in dotnetProjectFolders(folder, depth: 2) {
                    addArtifact(project + "/bin", .dotnet, .build)
                    addArtifact(project + "/obj", .dotnet, .build)
                }
            }
        }

        mutating func python() {
            guard ["pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "Pipfile"].contains(where: has) else { return }
            let detail = has("uv.lock") ? "uv" : has("poetry.lock") ? "Poetry" : has("Pipfile") ? "Pipenv" : nil
            kinds.append(ProjectKindInfo(kind: .python, detail: detail))
            let caches = findFolders(named: "__pycache__", under: folder, depth: 4)
            if !caches.isEmpty {
                artifacts.append(ProjectArtifact(name: "__pycache__", urls: caches, kind: .python, role: .cache))
                caches.forEach { seen.insert($0.path) }
            }
            for name in [".pytest_cache", ".mypy_cache", ".ruff_cache", ".hypothesis"] { addArtifact(name, .python, .cache) }
            for name in names.sorted() where name.hasSuffix(".egg-info") { addArtifact(name, .python, .build) }
            for name in names.sorted()
            where FileManager.default.fileExists(atPath: folder.appending(path: name).appending(path: "pyvenv.cfg").path) {
                addArtifact(name, .python, .environment)
            }
            for name in [".tox", ".nox"] { addArtifact(name, .python, .environment) }
        }

        /// Go, Ruby, the JVM, Godot, containers and Terraform, each known by its marker files.
        mutating func others() {
            if has("go.mod") { kinds.append(ProjectKindInfo(kind: .go, detail: nil)) }

            if has("Gemfile") {
                kinds.append(ProjectKindInfo(kind: .ruby, detail: "Bundler"))
                addArtifact("vendor/bundle", .ruby, .dependencies)
            }

            let gradle = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"].contains(where: has)
            if has("pom.xml") || gradle {
                kinds.append(ProjectKindInfo(kind: .jvm, detail: gradle ? "Gradle" : "Maven"))
                if has("pom.xml") { addArtifact("target", .jvm, .build) }
                if gradle {
                    addArtifact("build", .jvm, .build)
                    addArtifact(".gradle", .jvm, .cache)
                    addArtifact(".kotlin", .jvm, .cache)
                }
            }

            if has("project.godot") {
                kinds.append(ProjectKindInfo(kind: .godot, detail: nil))
                addArtifact(".godot", .godot, .cache)
                addArtifact(".import", .godot, .cache)
            }

            let compose = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"].contains(where: has)
            if has("Dockerfile") || has("Containerfile") || compose {
                kinds.append(ProjectKindInfo(kind: .docker, detail: compose ? "Compose" : nil))
            }

            if !withExtension(["tf"]).isEmpty {
                kinds.append(ProjectKindInfo(kind: .terraform, detail: nil))
                addArtifact(".terraform", .terraform, .dependencies)
            }
        }

        /// Make and just, whatever the language.
        mutating func taskRunners() {
            if let makefile = ["Makefile", "makefile", "GNUmakefile"].first(where: has) {
                scripts += makeTargets(folder.appending(path: makefile), directory: folder, source: makefile)
            }
            if let justfile = ["justfile", "Justfile", ".justfile"].first(where: has) {
                scripts += justRecipes(folder.appending(path: justfile), directory: folder, source: justfile)
            }
        }
    }

    /// A directory, not a symlink to one (deleting a symlinked node_modules wouldn't free anything).
    static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    // MARK: Node

    private static func nodeManager(_ folder: URL, names: Set<String>, package: [String: Any]?) -> ProjectScript.Runner {
        if let field = package?["packageManager"] as? String {
            let name = field.split(separator: "@").first.map(String.init) ?? ""
            if let runner = ProjectScript.Runner(rawValue: name), [.npm, .yarn, .pnpm, .bun].contains(runner) { return runner }
        }
        // Workspace packages keep the lockfile at the workspace root; look a few levels up (not past a repo root).
        var directory = folder
        var listing = names
        for _ in 0..<5 {
            if listing.contains("pnpm-lock.yaml") || listing.contains("pnpm-workspace.yaml") { return .pnpm }
            if listing.contains("bun.lockb") || listing.contains("bun.lock") { return .bun }
            if listing.contains("yarn.lock") { return .yarn }
            if listing.contains("package-lock.json") || listing.contains("npm-shrinkwrap.json") { return .npm }
            if listing.contains(".git") { break }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
            listing = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        }
        return .npm
    }

    private static func readJSON(_ url: URL) -> (object: [String: Any]?, text: String) {
        guard let (data, truncated) = try? TextFile.readPrefix(url, limit: 1 << 20), !truncated else { return (nil, "") }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (object, String(decoding: data, as: UTF8.self))
    }

    private static func readText(_ url: URL) -> String? {
        guard let (data, _) = try? TextFile.readPrefix(url, limit: 1 << 20) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `scripts` in the order they're written (JSONSerialization loses it; authors order them on purpose).
    private static func packageScripts(_ package: (object: [String: Any]?, text: String), runner: ProjectScript.Runner,
                                       directory: URL) -> [ProjectScript] {
        guard let scripts = package.object?["scripts"] as? [String: Any] else { return [] }
        let text = package.text
        let start = text.range(of: "\"scripts\"")?.upperBound ?? text.startIndex
        func offset(_ key: String) -> Int {
            guard let range = text.range(of: "\"\(key)\"", range: start..<text.endIndex) else { return .max }
            return text.distance(from: text.startIndex, to: range.lowerBound)
        }
        return scripts.compactMap { key, value -> (Int, ProjectScript)? in
            guard let command = value as? String else { return nil }
            return (offset(key), ProjectScript(name: key, command: command, runner: runner, directory: directory, source: "package.json"))
        }
        .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.name < $1.1.name }
        .map(\.1)
    }

    // MARK: Task runners

    /// Targets from a Makefile: `name:` rules, skipping special (.PHONY), pattern (%.o) and variable-built targets.
    /// The command shown is the `## help` text if present, else the first recipe line.
    static func makeTargets(_ url: URL, directory: URL, source: String) -> [ProjectScript] {
        guard let text = readText(url) else { return [] }
        var results: [(name: String, command: String, summary: String)] = []
        var pending: [Int] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("\t") {
                let recipe = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@-+"))
                for index in pending where results[index].command.isEmpty { results[index].command = recipe }
                pending = []
                continue
            }
            pending = []
            guard let first = line.first, !first.isWhitespace, first != "#", first != "." else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let head = line[..<colon]
            let after = line[line.index(after: colon)...]
            if after.hasPrefix("=") || head.contains("=") || head.contains("$") || head.contains("%") { continue }
            let help = after.range(of: "##").map { after[$0.upperBound...].trimmingCharacters(in: .whitespaces) } ?? ""
            for name in head.split(separator: " ") where !name.isEmpty {
                guard !results.contains(where: { $0.name == String(name) }) else { continue }
                results.append((String(name), "", help))
                pending.append(results.count - 1)
            }
            if results.count >= 60 { break }
        }
        return results.map {
            ProjectScript(name: $0.name, command: $0.command, summary: $0.summary.isEmpty ? nil : $0.summary, runner: .make,
                          directory: directory, source: source)
        }
    }

    /// Public recipes from a justfile. Skips settings, aliases, assignments, `_private` and `[private]` recipes.
    /// The command shown is the doc comment above the recipe, else its first line.
    static func justRecipes(_ url: URL, directory: URL, source: String) -> [ProjectScript] {
        guard let text = readText(url) else { return [] }
        var results: [(name: String, command: String, summary: String)] = []
        var comment = ""
        var isPrivate = false
        var pending: Int?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let first = line.first, first == " " || first == "\t" {
                if let index = pending, results[index].command.isEmpty {
                    results[index].command = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@-"))
                }
                pending = nil
                continue
            }
            pending = nil
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { comment = ""; isPrivate = false; continue }
            if trimmed.hasPrefix("#") { comment = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces); continue }
            if trimmed.hasPrefix("[") {
                if trimmed.contains("private") { isPrivate = true }
                continue
            }
            let keyword = trimmed.split(separator: " ").first.map(String.init) ?? ""
            if ["set", "alias", "export", "import", "mod"].contains(keyword) { comment = ""; continue }
            guard let colon = recipeColon(trimmed) else { comment = ""; continue }
            var name = String(trimmed[..<colon]).split(separator: " ").first.map(String.init) ?? ""
            if name.hasPrefix("@") { name.removeFirst() }
            defer { comment = ""; isPrivate = false }
            guard !name.isEmpty, !name.hasPrefix("_"), !isPrivate,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { continue }
            results.append((name, "", comment))
            pending = results.count - 1
        }
        return results.map {
            ProjectScript(name: $0.name, command: $0.command, summary: $0.summary.isEmpty ? nil : $0.summary, runner: .just,
                          directory: directory, source: source)
        }
    }

    /// The `:` ending a recipe header: outside quotes and not part of `:=`.
    private static func recipeColon(_ line: String) -> String.Index? {
        var quote: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ":" {
                let next = line.index(after: index)
                return next < line.endIndex && line[next] == "=" ? nil : index
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// `[alias]` entries from `.cargo/config.toml` (or the legacy `.cargo/config`).
    static func cargoAliases(_ folder: URL) -> [ProjectScript] {
        let candidates = [".cargo/config.toml", ".cargo/config"].map { folder.appending(path: $0) }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let text = readText(url) else { return [] }
        var inAlias = false
        var results: [ProjectScript] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inAlias = line == "[alias]"; continue }
            guard inAlias, let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("[") {
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }.joined(separator: " ")
            } else {
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            guard !name.isEmpty else { continue }
            results.append(ProjectScript(name: name, command: "cargo " + value, runner: .cargo, directory: folder,
                                         source: url.path.hasSuffix(".toml") ? ".cargo/config.toml" : ".cargo/config"))
        }
        return results
    }

    // MARK: Bounded searches

    private static let skippedFolders: Set<String> = [
        "node_modules", ".git", ".venv", "venv", "env", ".tox", ".nox", "target", ".build", "bin", "obj", "build", "dist",
    ]

    /// Folders named `name` up to `depth` levels below `root`, skipping dependency, VCS and build trees.
    static func findFolders(named name: String, under root: URL, depth: Int) -> [URL] {
        var results: [URL] = []
        var visited = 0
        func visit(_ folder: URL, _ level: Int) {
            guard visited < 4096, let children = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
            visited += 1
            for child in children.sorted() {
                guard visited < 4096 else { return }
                let url = folder.appending(path: child, directoryHint: .isDirectory)
                guard isRealDirectory(url.path) else { continue }
                if child == name {
                    results.append(url)
                } else if level < depth, !skippedFolders.contains(child), !child.hasPrefix("."),
                          !FileManager.default.fileExists(atPath: url.appending(path: "pyvenv.cfg").path) {
                    visit(url, level + 1)
                }
            }
        }
        visit(root, 1)
        return results
    }

    /// Relative paths of folders holding a .NET project file, up to `depth` levels below a solution.
    private static func dotnetProjectFolders(_ root: URL, depth: Int) -> [String] {
        var results: [String] = []
        var visited = 0
        func visit(_ relative: String, _ level: Int) {
            let folder = relative.isEmpty ? root : root.appending(path: relative)
            guard visited < 4096, let children = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
            visited += 1
            for child in children.sorted() where !child.hasPrefix(".") && !skippedFolders.contains(child) {
                guard visited < 4096 else { return }
                let path = relative.isEmpty ? child : relative + "/" + child
                let url = root.appending(path: path)
                guard isRealDirectory(url.path) else { continue }
                let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                if files.contains(where: { ["csproj", "fsproj", "vbproj"].contains(($0 as NSString).pathExtension) }) {
                    results.append(path)
                } else if level < depth {
                    visit(path, level + 1)
                }
            }
        }
        visit("", 1)
        return results
    }

    // MARK: Sizes

    /// Measures every artifact (summing grouped folders) with the same fts walk as the size column. Runs on GCD
    /// utility threads, not the Swift concurrency pool, since a big node_modules walk blocks for a while. Cancelling
    /// the calling task stops the walks.
    static func measure(_ artifacts: [ProjectArtifact]) async -> [ProjectArtifact] {
        let cancelled = CancelFlag()
        return await withTaskCancellationHandler {
            await withTaskGroup(of: (Int, Int64, Int).self) { group in
                for (index, artifact) in artifacts.enumerated() where !artifact.isMeasured {
                    let paths = artifact.urls.map(\.path)
                    group.addTask {
                        await withCheckedContinuation { continuation in
                            DispatchQueue.global(qos: .utility).async {
                                var bytes: Int64 = 0
                                var files = 0
                                for path in paths {
                                    guard let size = FolderSizer.measure(path, isCancelled: { cancelled.isSet }) else { continue }
                                    bytes = [bytes, size.bytes].saturatingSum
                                    let (nextFiles, overflow) = files.addingReportingOverflow(size.files)
                                    files = overflow ? .max : nextFiles
                                }
                                continuation.resume(returning: (index, bytes, files))
                            }
                        }
                    }
                }
                var measured = artifacts
                for await (index, bytes, files) in group where !cancelled.isSet {
                    measured[index].bytes = bytes
                    measured[index].files = files
                }
                return measured
            }
        } onCancel: {
            cancelled.set()
        }
    }
}

/// A thread-safe "stop" switch for background work.
nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
