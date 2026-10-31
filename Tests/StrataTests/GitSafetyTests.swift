import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

/// A repository you only browse brings its own `.git/config`, which can tell git to run commands: a `core.fsmonitor` on
/// every status, a filter driver whenever a changed file is hashed. Strata's git runs none of them.
struct GitSafetyTests {
    private func git(_ arguments: [String], in folder: URL, executable: String) async throws {
        let status: Int32 = try await withCheckedThrowingContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = ["-C", folder.path, "-c", "user.name=t", "-c", "user.email=t@t",
                                         "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
                    process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    process.standardInput = FileHandle.nullDevice
                    try process.run()
                    process.waitUntilExit()
                    done.resume(returning: process.terminationStatus)
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
        try #require(status == 0)
    }

    @Test func aBrowsedRepositorysOwnCommandsNeverRun() async throws {
        let gitPath = try #require(GitRunner.executable)
        let tree = try TestTree("repo/", "repo/file.txt", "repo/.gitattributes")
        let marker = tree.url("ran.txt")
        let hook = tree.url("hook.sh")
        try "#!/bin/sh\ntouch \(ShellQuote.quote(marker.path))\ncat\n".write(to: hook, atomically: true, encoding: .utf8)
        try #require(chmod(hook.path, 0o755) == 0)
        try "* filter=evil\n".write(to: tree.url("repo/.gitattributes"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)],
                                             ofItemAtPath: tree.url("repo/file.txt").path)
        for arguments in [["init", "-q"], ["add", "."], ["commit", "-q", "-m", "first"],
                          ["config", "core.fsmonitor", hook.path], ["config", "filter.evil.clean", hook.path],
                          ["config", "filter.evil.required", "true"]] {
            try await git(arguments, in: tree.url("repo"), executable: gitPath)
        }
        // Same size, different contents and date: status must hash it, which would run its clean filter.
        try "repo/FILE.txt".write(to: tree.url("repo/file.txt"), atomically: true, encoding: .utf8)
        let run = await GitRunner.run(["status", "--porcelain=v2", "-z", "--untracked-files=normal"], in: tree.url("repo"), timeout: 30)
        #expect(run.exitCode == 0, Comment(rawValue: run.errorOutput))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(tree.text("repo/file.txt") == "repo/FILE.txt")
        #expect(tree.snapshot().filter { !$0.hasPrefix("repo/.git/") } == ["hook.sh", "repo/", "repo/.gitattributes", "repo/file.txt"])
    }
    @Test func invalidUTF8FilterNamesFailClosedBeforeGitStatus() async throws {
        let tree = try TestTree("repo/", "repo/file", "repo/.gitattributes")
        let executable = try #require(GitRunner.executable)
        try await git(["init", "-q"], in: tree.url("repo"), executable: executable)
        try await git(["add", "."], in: tree.url("repo"), executable: executable)
        try await git(["commit", "-q", "-m", "fixture"], in: tree.url("repo"), executable: executable)
        let marker = tree.url("ran")
        let command = "touch " + ShellQuote.quote(marker.path)
        let config = tree.url("repo/.git/config")
        var bytes = try Data(contentsOf: config)
        bytes.append(Data(Array("\n[filter \"evil".utf8) + [0x80] + Array("\"]\n clean = ".utf8)))
        bytes.append(Data(command.utf8)); bytes.append(10)
        try bytes.write(to: config)
        try Data(Array("* filter=evil".utf8) + [0x80, 10]).write(to: tree.url("repo/.gitattributes"))
        try Data("changed".utf8).write(to: tree.url("repo/file"))
        let result = await GitRunner.run(["status", "--porcelain=v2", "-z"], in: tree.url("repo"), timeout: 10)
        #expect(!result.succeeded)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(tree.snapshot().filter { !$0.hasPrefix("repo/.git/") } == ["repo/", "repo/.gitattributes", "repo/file"])
    }

    @Test func canonicallyEquivalentFilterNamesStayByteDistinct() throws {
        let composed = "filter.caf\u{00E9}.clean"
        let decomposed = "filter.cafe\u{0301}.clean"
        let fields = Data("local\0\(composed)\0local\0\(decomposed)\0".utf8)
        let arguments = try #require(GitRunner.filterOverrides(fields))
        let bytes = Set(arguments.map { Data($0.utf8) })
        #expect(bytes.contains(Data((composed + "=").utf8)))
        #expect(bytes.contains(Data((decomposed + "=").utf8)))
    }

}
