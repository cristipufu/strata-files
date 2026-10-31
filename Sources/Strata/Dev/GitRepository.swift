import Foundation

/// A git work tree found by walking up from a folder.
package nonisolated struct GitRepository: Sendable, Hashable {
    /// Top of the work tree (the folder holding `.git`).
    package let root: URL
    /// Where HEAD, the index and in-progress operation markers live: `.git`, or the folder a `.git` file points to.
    package let gitDirectory: URL
    /// `.git` is a file: a linked worktree (`git worktree add`) or a submodule.
    package let isLinked: Bool
    /// A linked worktree rather than a submodule (its git directory has a `commondir`).
    package let isWorktree: Bool
    /// `root.path`, kept as a string for the per-row lookups (URL.path isn't free).
    package let rootPath: String

    package init(root: URL, gitDirectory: URL, isLinked: Bool, isWorktree: Bool) {
        self.root = root
        self.gitDirectory = gitDirectory
        self.isLinked = isLinked
        self.isWorktree = isWorktree
        rootPath = root.path
    }

    package var isSubmodule: Bool { isLinked && !isWorktree }

    /// Folders never treated as a work tree root even when they hold `.git`. A dotfiles repo in the home folder
    /// would otherwise make every folder you browse "untracked" and run status over your whole home.
    package static let excludedRoots: Set<String> = ["/", FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path]

    /// The repository containing `url` (a folder, or a file whose folder is used), or nil. A few `lstat`s per level,
    /// no git process.
    package static func locate(from url: URL) -> GitRepository? {
        let fm = FileManager.default
        var path = url.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            path = (path as NSString).deletingLastPathComponent
        }
        let excluded = excludedRoots
        while true {
            defer { path = (path as NSString).deletingLastPathComponent }
            // Inside a .git folder itself there's no work tree to report on.
            if (path as NSString).lastPathComponent == ".git" { return nil }
            let candidate = (path as NSString).appendingPathComponent(".git")
            var info = stat()
            if lstat(candidate, &info) == 0 {
                if excluded.contains(path) { return nil }
                let root = URL(fileURLWithPath: path, isDirectory: true)
                // A .git folder without HEAD isn't a repository (leftover or half-copied); keep looking above it.
                if (info.st_mode & S_IFMT) == S_IFDIR, fm.fileExists(atPath: (candidate as NSString).appendingPathComponent("HEAD")) {
                    return GitRepository(root: root, gitDirectory: URL(fileURLWithPath: candidate, isDirectory: true),
                                         isLinked: false, isWorktree: false)
                }
                if (info.st_mode & S_IFMT) == S_IFREG, let gitDir = resolveGitFile(candidate, relativeTo: path) {
                    let isWorktree = fm.fileExists(atPath: gitDir.appending(path: "commondir").path)
                    return GitRepository(root: root, gitDirectory: gitDir, isLinked: true, isWorktree: isWorktree)
                }
            }
            if path == "/" || path.isEmpty { return nil }
        }
    }

    /// `.git` files contain `gitdir: <path>`, relative to the folder holding the file.
    private static func resolveGitFile(_ file: String, relativeTo folder: String) -> URL? {
        guard let (data, _) = try? TextFile.readPrefix(URL(fileURLWithPath: file), limit: 64 * 1024),
              let text = String(data: data, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        let absolute = target.hasPrefix("/") ? target : (folder as NSString).appendingPathComponent(target)
        let url = URL(fileURLWithPath: absolute, isDirectory: true).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.appending(path: "HEAD").path) ? url : nil
    }

    /// The branch HEAD names, read straight from the file: instant, so the branch pill can appear before status
    /// finishes. Nil when HEAD is detached or unreadable.
    package func currentBranchName() -> String? {
        guard let (data, _) = try? TextFile.readPrefix(gitDirectory.appending(path: "HEAD"), limit: 64 * 1024),
              let head = String(data: data, encoding: .utf8) else { return nil }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("ref: refs/heads/") else { return nil }
        return String(line.dropFirst("ref: refs/heads/".count))
    }

    /// A merge, rebase, cherry-pick… in progress, from the marker files git leaves in the git directory.
    package func operationInProgress() -> GitOperation? {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: gitDirectory.appending(path: name).path) }
        func number(_ name: String) -> Int? {
            guard let (data, _) = try? TextFile.readPrefix(gitDirectory.appending(path: name), limit: 1024),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if exists("rebase-merge") { return .rebasing(step: number("rebase-merge/msgnum"), total: number("rebase-merge/end")) }
        if exists("rebase-apply") {
            if exists("rebase-apply/applying") { return .applyingMailbox }
            return .rebasing(step: number("rebase-apply/next"), total: number("rebase-apply/last"))
        }
        if exists("MERGE_HEAD") { return .merging }
        if exists("CHERRY_PICK_HEAD") { return .cherryPicking }
        if exists("REVERT_HEAD") { return .reverting }
        if exists("BISECT_LOG") { return .bisecting }
        return nil
    }

    /// During a rebase HEAD is detached; the branch being rebased is recorded separately.
    package func rebasingBranchName() -> String? {
        for file in ["rebase-merge/head-name", "rebase-apply/head-name"] {
            if let (data, _) = try? TextFile.readPrefix(gitDirectory.appending(path: file), limit: 64 * 1024),
               let text = String(data: data, encoding: .utf8) {
                let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name
            }
        }
        return nil
    }
}

// MARK: - Running git

package nonisolated struct GitRunResult: Sendable {
    package let exitCode: Int32
    package let output: Data
    package let errorOutput: String
    package let timedOut: Bool
    package let duration: TimeInterval

    package var succeeded: Bool { !timedOut && exitCode == 0 }
}

package nonisolated enum GitRunner {
    /// The git binary, resolved once. Prefers the active developer directory's git over the `/usr/bin/git` shim: it
    /// skips the xcrun lookup, and on a Mac without developer tools the shim pops an "install command line developer
    /// tools" dialog, while this simply finds nothing and git features stay off.
    package static let executable: String? = {
        var candidates: [String] = []
        if let developer = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            candidates.append((developer as NSString).appendingPathComponent("usr/bin/git"))
        }
        candidates += [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    package static var isAvailable: Bool { executable != nil }

    /// Runs `git --no-optional-locks -C <directory> <arguments>` on a background queue. Never blocks a Swift
    /// concurrency thread: the blocking wait happens on a GCD utility thread. Killed after `timeout` seconds.
    package static func run(_ arguments: [String], in directory: URL, timeout: TimeInterval) async -> GitRunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(arguments, in: directory, timeout: timeout))
            }
        }
    }

    /// A repository you merely browse (say, one that came in a zip) brings its own `.git/config`, and git runs
    /// commands named there during plain reads: `core.fsmonitor` on every `status`, filter drivers' clean or process
    /// commands when it re-hashes a changed file, and, in a partial clone missing an object, a lazy fetch that runs the
    /// remote's `uploadpack` or `sshCommand`. Every call switches those off (lazy fetch through GIT_NO_LAZY_FETCH, and
    /// no transport is allowed at all); `-c` settings also reach any git that call spawns.
    private static let hardening = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                                    "-c", "protocol.allow=never"]

    package static func runBlocking(_ arguments: [String], in directory: URL, timeout: TimeInterval) -> GitRunResult {
        let start = Date()
        // Fail closed: if the repository's filter drivers can't be listed, don't run git there at all.
        guard let overrides = repositoryFilterOverrides(in: directory, timeout: timeout) else {
            return GitRunResult(exitCode: -1, output: Data(), errorOutput: "couldn't read the repository's git config",
                                timedOut: false, duration: Date().timeIntervalSince(start))
        }
        return execute(hardening + overrides + arguments, in: directory, timeout: timeout, start: start)
    }

    /// Browsing never runs filters, including global drivers whose behavior can depend on repository config.
    /// Unrepresentable driver names fail closed rather than leaving a differently spelled command enabled.
    private static func repositoryFilterOverrides(in directory: URL, timeout: TimeInterval) -> [String]? {
        let run = execute(hardening + ["config", "--includes", "--show-scope", "--name-only", "-z", "--get-regexp",
                                       #"^filter\..*\.(clean|smudge|process)$"#],
                          in: directory, timeout: timeout, start: Date())
        // Exit status 1 just means no filter is configured anywhere.
        if run.exitCode == 1 && !run.timedOut { return [] }
        guard run.succeeded else { return nil }
        return filterOverrides(run.output)
    }

    package static func filterOverrides(_ output: Data) -> [String]? {
        let rawFields = output.split(separator: 0, omittingEmptySubsequences: false)
        var fields: [String] = []
        for field in rawFields {
            guard let text = String(bytes: field, encoding: .utf8) else { return nil }
            fields.append(text)
        }
        guard fields.last == "", fields.count % 2 == 1 else { return nil }
        var drivers = Set<Data>()
        var index = 0
        while index + 1 < fields.count {
            let key = fields[index + 1]
            index += 2
            // `-c` splits at the first "=", so a driver name containing one couldn't be overridden.
            guard !key.contains("="), !key.contains("\n"), let dot = key.lastIndex(of: ".") else { return nil }
            drivers.insert(Data(key[..<dot].utf8))
        }
        // Git compares driver names as bytes; Swift String equality folds canonically equivalent spellings.
        return drivers.sorted { $0.lexicographicallyPrecedes($1) }.flatMap { bytes in
            let driver = String(decoding: bytes, as: UTF8.self)
            // Git must also stop requiring the disabled driver, or hashing a changed file fails.
            return ["clean", "smudge", "process"].flatMap { ["-c", "\(driver).\($0)="] } + ["-c", "\(driver).required=false"]
        }
    }

    private static func execute(_ arguments: [String], in directory: URL, timeout: TimeInterval, start: Date) -> GitRunResult {
        guard let executable else {
            return GitRunResult(exitCode: -1, output: Data(), errorOutput: "git not found", timedOut: false, duration: 0)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--no-optional-locks", "-C", directory.path] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        // Never let an inherited GIT_DIR (Strata launched from a hook or a git alias) point us at another repository.
        // Nor inherited config overrides that could undo the hardening above.
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR",
                    "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT"] {
            environment[key] = nil
        }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_NO_LAZY_FETCH"] = "1"
        // An empty allow-list permits no transport and, unlike `protocol.allow`, a repository's own
        // `protocol.<name>.allow` can't override it.
        environment["GIT_ALLOW_PROTOCOL"] = ""
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let stdout = PipeCollector()
        let stderr = PipeCollector()
        process.standardOutput = stdout.pipe
        process.standardError = stderr.pipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return GitRunResult(exitCode: -1, output: Data(), errorOutput: error.localizedDescription, timedOut: false,
                                duration: Date().timeIntervalSince(start))
        }

        let flag = TimeoutFlag()
        let pid = process.processIdentifier
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            guard process.isRunning else { return }
            flag.set()
            process.terminate()
            // SIGTERM is enough for git; escalate if it's stuck in uninterruptible I/O.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        timer.resume()
        process.waitUntilExit()
        timer.cancel()
        // Output is collected as it arrives (so a full pipe never stalls git). After exit, wait briefly for the pipes
        // to reach EOF; a lingering grandchild holding them open can't keep us here.
        stdout.finish(within: 1)
        stderr.finish(within: 0.2)

        let readError = stdout.readError ?? stderr.readError
        return GitRunResult(exitCode: readError == nil ? process.terminationStatus : -1, output: stdout.data,
                            errorOutput: readError ?? String(decoding: stderr.data, as: UTF8.self), timedOut: flag.isSet,
                            duration: Date().timeIntervalSince(start))
    }
}

/// Accumulates one pipe's output on a background queue until EOF.
package nonisolated final class PipeCollector: @unchecked Sendable {
    package static let limit = 64 << 20
    package let pipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var reachedEOF = false
    private var failure: String?
    private let eof = DispatchSemaphore(value: 0)

    package init() {
        // The owned pipe stays open for every callback; don't ask a closed FileHandle for its descriptor.
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        pipe.fileHandleForReading.readabilityHandler = { [weak self] _ in
            self?.receive(descriptor)
        }
    }

    package func receive(_ descriptor: Int32) {
        let chunk: Data
        do {
            chunk = try PipeRead.availableData(from: descriptor)
        } catch {
            lock.withLock { failure = error.localizedDescription }
            finishReading()
            return
        }
        if chunk.isEmpty {
            finishReading()
        } else {
            lock.withLock {
                if buffer.count + chunk.count <= Self.limit {
                    buffer.append(chunk)
                } else {
                    failure = "git output exceeded limit"
                }
            }
        }
    }

    private func finishReading() {
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.withLock {
            guard !reachedEOF else { return }
            reachedEOF = true
            eof.signal()
        }
    }

    package func finish(within seconds: TimeInterval) {
        _ = eof.wait(timeout: .now() + seconds)
        pipe.fileHandleForReading.readabilityHandler = nil
    }

    package var data: Data { lock.withLock { buffer } }
    package var readError: String? { lock.withLock { failure } }
}

nonisolated private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

// MARK: - Loading status

package nonisolated enum GitStatusLoader {
    /// Runs `git status` for `repository` off the main thread and parses it into a snapshot.
    @concurrent
    package static func load(_ repository: GitRepository, mode: GitIgnoredMode, timeout: TimeInterval) async -> GitStatusSnapshot {
        let arguments = [
            "status", "--porcelain=v2", "-z", "--branch", "--show-stash",
            "--untracked-files=normal", "--ignored=\(mode.rawValue)",
            // Checking inside submodules would run git with each submodule's own config, which the overrides above
            // don't cover. A submodule whose commit moved still shows as changed.
            "--ignore-submodules=dirty",
        ]
        let run = await GitRunner.run(arguments, in: repository.root, timeout: timeout)
        let outcome: GitStatusSnapshot.Outcome
        if run.timedOut {
            outcome = .timedOut
        } else if run.exitCode != 0 {
            outcome = .failed(run.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            outcome = .ok
        }
        var parsed = outcome == .ok ? GitStatusParser.parse(run.output) : GitStatusParser.Result()
        if outcome != .ok {
            // Still show which branch we're on.
            parsed.branch.head = repository.currentBranchName()
        }
        let operation = repository.operationInProgress()
        if parsed.branch.head == nil, case .rebasing = operation {
            parsed.branch.head = repository.rebasingBranchName()
        }
        // Data's own hashValue only looks at the first bytes; hash all of it.
        var hasher = Hasher()
        run.output.withUnsafeBytes { hasher.combine(bytes: $0) }
        hasher.combine(operation?.title)
        hasher.combine("\(outcome)")
        return GitStatusSnapshot(
            repository: repository, branch: parsed.branch, operation: operation, stashCount: parsed.stashCount,
            entries: parsed.entries, ignoredFiles: parsed.ignoredFiles, ignoredDirectories: parsed.ignoredDirectories,
            untrackedDirectories: parsed.untrackedDirectories, directoryStates: parsed.directoryStates,
            counts: parsed.counts, outcome: outcome, duration: run.duration, date: Date(),
            fingerprint: hasher.finalize())
    }

    /// Root-relative paths among `paths` that contain at least one tracked file (one `git ls-files` call).
    @concurrent
    package static func trackedPaths(_ paths: [String], in repository: GitRepository, timeout: TimeInterval) async -> Set<String>? {
        guard !paths.isEmpty else { return [] }
        let run = await GitRunner.run(["ls-files", "-z", "--"] + paths.map { ":(literal)" + $0 },
                                      in: repository.root, timeout: timeout)
        guard run.succeeded else { return nil }
        var tracked: Set<String> = []
        for record in run.output.split(separator: 0) {
            let file = String(decoding: record, as: UTF8.self)
            for path in paths where file == path || file.hasPrefix(path + "/") { tracked.insert(path) }
        }
        return tracked
    }
}
