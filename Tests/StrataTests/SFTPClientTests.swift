import Foundation
import os
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

/// Against macOS's own `sftp-server` (what `ssh -s host sftp` runs on a server), over a pipe: no network, no login.
struct SFTPClientTests {
    let root: URL
    let client: SFTPClient

    init() throws {
        let fm = FileManager.default
        let made = fm.temporaryDirectory.appending(path: "strata-sftp-\(UUID().uuidString)")
        try fm.createDirectory(at: made.appending(path: "docs/deep"), withIntermediateDirectories: true)
        // The server reports real paths (/private/var/…, which Foundation would shorten to /var/…).
        guard let real = realpath(made.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        root = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        free(real)
        try Data("hello".utf8).write(to: root.appending(path: "docs/hello.txt"))
        try Data("ünïcödé".utf8).write(to: root.appending(path: "docs/Résumé – final.txt"))
        var big = Data(count: 5_000_123)
        big.withUnsafeMutableBytes { buffer in
            for i in 0..<buffer.count { buffer[i] = UInt8(truncatingIfNeeded: i &* 2654435761 >> 7) }
        }
        try big.write(to: root.appending(path: "big.bin"))
        try fm.createSymbolicLink(atPath: root.appending(path: "link-to-docs").path, withDestinationPath: "docs")
        client = try SFTPClient(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-d", root.path])
    }

    private func cleanUp() {
        client.close()
        try? FileManager.default.removeItem(at: root)
    }

    @Test func aServerThatStopsAnsweringIsDisconnected() throws {
        defer { cleanUp() }
        let quiet = try SFTPClient(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-d", root.path],
                                   silenceLimit: 0.5)
        // Connected and answering: quick requests never come near the limit.
        #expect(try quiet.realPath(".") == root.path)
        let pid = quiet.processIdentifier
        kill(pid, SIGSTOP)
        defer { kill(pid, SIGKILL) }
        let started = Date()
        #expect(throws: SFTPError.stoppedAnswering) { try quiet.list(root.path) }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(!quiet.isConnected)
    }

    @Test func aSlowLoginIsNeverCutShort() throws {
        defer { cleanUp() }
        // The login (here: a server that takes a while to start) isn't counted; only silence once it's up.
        let slow = try SFTPClient(executable: URL(fileURLWithPath: "/bin/sh"),
                                  arguments: ["-c", "sleep 1.5; exec /usr/libexec/sftp-server -d \"$0\"", root.path],
                                  silenceLimit: 0.5)
        defer { slow.close() }
        #expect(try slow.realPath(".") == root.path)
    }

    @Test func startsInItsFolder() throws {
        defer { cleanUp() }
        #expect(try client.realPath(".") == root.path)
    }

    @Test func listsAFolderWithKindsSizesAndDates() throws {
        defer { cleanUp() }
        let entries = try client.list(root.path)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.attributes) })
        #expect(Set(byName.keys) == ["docs", "big.bin", "link-to-docs"])
        #expect(byName["docs"]?.isDirectory == true)
        #expect(byName["big.bin"]?.isRegularFile == true)
        #expect(byName["big.bin"]?.size == 5_000_123)
        #expect(byName["big.bin"]?.modificationTime != nil)
        #expect(byName["link-to-docs"]?.isSymlink == true)
        #expect(try client.readLink(root.appending(path: "link-to-docs").path) == "docs")
        let docs = try client.list(root.appending(path: "docs").path).map(\.name).sorted()
        #expect(docs == ["Résumé – final.txt", "deep", "hello.txt"].sorted())
    }

    @Test func downloadsExactly() throws {
        defer { cleanUp() }
        let destination = root.appending(path: "downloaded.bin")
        var last: Int64 = 0
        try client.download(root.appending(path: "big.bin").path, to: destination) { last = $0 }
        #expect(try Data(contentsOf: destination) == Data(contentsOf: root.appending(path: "big.bin")))
        #expect(last == 5_000_123)
        let small = root.appending(path: "small.txt")
        try client.download(root.appending(path: "docs/Résumé – final.txt").path, to: small)
        #expect(try String(contentsOf: small, encoding: .utf8) == "ünïcödé")
    }

    @Test func uploadsExactlyAndKeepsTheDate() throws {
        defer { cleanUp() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let target = root.appending(path: "docs/copy.bin").path
        try client.upload(root.appending(path: "big.bin"), to: target, modificationDate: date)
        #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == Data(contentsOf: root.appending(path: "big.bin")))
        #expect(try client.stat(target).modificationTime == 1_700_000_000)
        // Replacing a file truncates it.
        try client.upload(root.appending(path: "docs/hello.txt"), to: target)
        #expect(try client.stat(target).size == 5)
    }

    @Test func foldersRenamesAndRemoval() throws {
        defer { cleanUp() }
        let folder = root.appending(path: "new folder").path
        try client.makeFolder(folder)
        #expect(try client.stat(folder).isDirectory)
        #expect(throws: SFTPError.self) { try client.makeFolder(folder) }
        try client.rename(folder, to: root.appending(path: "renamed").path)
        #expect(throws: SFTPError.self) { try client.stat(folder) }
        // Never over something that's there.
        #expect(throws: SFTPError.self) { try client.rename(root.appending(path: "renamed").path, to: root.appending(path: "docs").path) }
        try client.removeFolder(root.appending(path: "renamed").path)
        try client.removeFile(root.appending(path: "docs/hello.txt").path)
        #expect(try client.list(root.appending(path: "docs").path).map(\.name).sorted() == ["Résumé – final.txt", "deep"].sorted())
    }

    @Test func errorsSayWhatHappened() throws {
        defer { cleanUp() }
        #expect(throws: SFTPError.status(SFTPError.noSuchFile, "No such file")) { try client.stat(root.appending(path: "nope").path) }
        let locked = root.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        do {
            _ = try client.list(locked.path)
            #expect(Bool(false), "listing a folder without permission should fail")
        } catch let SFTPError.status(code, _) {
            #expect(code == SFTPError.permissionDenied)
        }
    }

    @Test func manyRequestsAtOnce() throws {
        defer { cleanUp() }
        // Several threads share one connection.
        let group = DispatchGroup()
        let failures = OSAllocatedUnfairLock(initialState: 0)
        for i in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let destination = root.appending(path: "parallel-\(i).bin")
                    try client.download(root.appending(path: "big.bin").path, to: destination)
                    if try Data(contentsOf: destination).count != 5_000_123 { failures.withLock { $0 += 1 } }
                    _ = try client.list(root.appending(path: "docs").path)
                } catch {
                    failures.withLock { $0 += 1 }
                }
            }
        }
        group.wait()
        #expect(failures.withLock { $0 } == 0)
    }

    @Test func aClosedSessionFailsCleanly() throws {
        defer { cleanUp() }
        client.close()
        #expect(throws: SFTPError.self) { try client.list(root.path) }
    }
}
