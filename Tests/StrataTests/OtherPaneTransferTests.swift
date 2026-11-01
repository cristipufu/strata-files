import Foundation
import Testing
@testable import Strata
@testable import StrataConnections
@testable import StrataFiles
@testable import StrataModel

/// Where Copy and Move to Other Pane send the selection, decided from the other pane's folder alone.
struct OtherPaneTransferTests {
    @Test func aCopyGoesThroughTheServerTheQueueOrNowhereByWhereTheOtherPaneIs() throws {
        let tree = try TestTree("plain/", "Servers/", "Containers/", "Clipboard/")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let servers = RemoteCopyStore(root: tree.url("Servers"), server: { $0 == server.id ? server : nil })
        let containers = ContainerCopyStore(root: tree.url("Containers"))
        let copies = CopyProviders([], remoteCopies: servers, containerCopies: containers, clipboardRoot: tree.url("Clipboard"))
        let engineFolder = try containers.prepare(ContainerEngine(socket: "/tmp/strata-test.sock", name: "Docker", apiVersion: "1.41"))

        #expect(OtherPaneTransfer.route(into: tree.url("plain"), copies: copies, servers: servers) == .queue)
        #expect(OtherPaneTransfer.route(into: servers.top(of: server.id).appending(path: "srv"), copies: copies, servers: servers) == .server)
        // What Strata fills in, and a Trash, take nothing from the other pane.
        #expect(OtherPaneTransfer.route(into: engineFolder, copies: copies, servers: servers) == .refused)
        #expect(OtherPaneTransfer.route(into: tree.url("Clipboard"), copies: copies, servers: servers) == .refused)
        #expect(OtherPaneTransfer.route(into: Trash.home, copies: copies, servers: servers) == .refused)
        withExtendedLifetime(tree) {}
    }
}
