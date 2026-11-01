import Foundation
import Testing
@testable import Strata
@testable import StrataConnections
@testable import StrataFiles

/// Going up a folder, and what the parent shows selected, decided from paths alone.
struct ParentFolderTests {
    @Test func upGoesToTheFolderAboveExceptAtATopWithNothingAbove() throws {
        let tree = try TestTree("a/b/", "Servers/", "Containers/")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let servers = RemoteCopyStore(root: tree.url("Servers"), server: { $0 == server.id ? server : nil })
        let containers = ContainerCopyStore(root: tree.url("Containers"))
        let engineFolder = try containers.prepare(ContainerEngine(socket: "/tmp/strata-test.sock", name: "Docker", apiVersion: "1.41"))
        let up = { (url: URL) in ParentFolder.up(from: url, containers: containers, servers: servers) }

        #expect(up(tree.url("a/b")) == .to(tree.url("a/b").deletingLastPathComponent(), selecting: tree.url("a/b")))
        #expect(up(URL(fileURLWithPath: "/")) == .none)
        #expect(up(engineFolder) == .refused)
        let top = servers.top(of: server.id)
        #expect(up(top) == .refused)
        #expect(up(top.appending(path: "srv", directoryHint: .isDirectory)) == .to(top.appending(path: "srv", directoryHint: .isDirectory).deletingLastPathComponent(),
                                                                                      selecting: top.appending(path: "srv", directoryHint: .isDirectory)))
        withExtendedLifetime(tree) {}
    }

    @Test func theParentSelectsTheItemOnTheWayDownAWholeNameAtATime() {
        let url = { (path: String) in URL(fileURLWithPath: path) }
        #expect(ParentFolder.child(of: url("/a"), toward: url("/a/b/c"))?.path == "/a/b")
        #expect(ParentFolder.child(of: url("/"), toward: url("/a/b"))?.path == "/a")
        // A look-alike name beside it, the folder itself, or somewhere else: nothing to select.
        #expect(ParentFolder.child(of: url("/a"), toward: url("/ab/c")) == nil)
        #expect(ParentFolder.child(of: url("/a"), toward: url("/a")) == nil)
        #expect(ParentFolder.child(of: url("/a/b"), toward: url("/a")) == nil)
    }
}
