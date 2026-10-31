import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

struct RunOwnerTests {
    private func owner(in folder: URL) throws -> RunOwner? {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        return try RunOwner(markerIn: fd)
    }

    @Test func anOwnerIsReadOnlyFromASmallRegularFile() throws {
        let tree = try TestTree("valid/", "missing/", "linked/", "linked/owner -> ../valid/owner", "large/", "garbled/", "fifo/")
        let owner = RunOwner(pid: 1, started: 2)
        try owner.marker.write(to: tree.url("valid/owner"))
        // A marker that would name an owner, but larger than any marker is.
        try Data(("1 2" + String(repeating: " ", count: 62)).utf8).write(to: tree.url("large/owner"))
        try Data("1".utf8).write(to: tree.url("garbled/owner"))
        try #require(mkfifo(tree.url("fifo/owner").path, 0o600) == 0)
        #expect(try self.owner(in: tree.url("valid")) == owner)
        #expect(try self.owner(in: tree.url("missing")) == nil)
        // A link, a pipe that would never end, a large file or a garbled one names no owner, and leaves its folder alone.
        for refused in ["linked", "fifo", "large", "garbled"] {
            #expect(throws: (any Error).self, "\(refused)") { try self.owner(in: tree.url(refused)) }
        }
        #expect(tree.snapshot() == ["fifo/", "fifo/owner", "garbled/", "garbled/owner", "large/", "large/owner", "linked/",
                                    "linked/owner -> ../valid/owner", "missing/", "valid/", "valid/owner"])
    }

    @Test func preferencesFoldersOfEndedRunsGoAndRunningOnesStay() throws {
        // Above the highest number macOS gives a process, so no process ever has it.
        let ended = 999_999
        let current = try #require(RunOwner.current)
        let tree = try TestTree("marked-ended/", "marked-ended/a.plist", "marked-running/", "marked-running/a.plist",
                                "\(current.pid)/", "\(current.pid)/a.plist", "\(ended)/", "\(ended)/a.plist",
                                "unnamed/", "unnamed/a.plist")
        // The same process number, started at another time: a process that ended and whose number was given again.
        try RunOwner(pid: current.pid, started: current.started - 1).marker.write(to: tree.url("marked-ended/owner"))
        try current.marker.write(to: tree.url("marked-running/owner"))
        ThrowawaySuites.removeFoldersOfEndedRuns(in: tree.root)
        // A folder made before runs marked theirs goes by its number alone.
        #expect(tree.snapshot() == ["\(current.pid)/", "\(current.pid)/a.plist", "marked-running/", "marked-running/a.plist",
                                    "marked-running/owner", "unnamed/", "unnamed/a.plist"])
    }
}
