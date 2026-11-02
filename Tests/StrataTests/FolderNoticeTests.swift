import Foundation
import Testing
@testable import Strata
@testable import StrataConnections
@testable import StrataFiles
@testable import StrataModel

/// What the bar under the toolbar says over a folder, and what its button does, decided from paths alone.
struct FolderNoticeTests {
    @Test func aCopysNoticeSaysWhatItIsAndItsButtonActsOnThatCopy() throws {
        let tree = try TestTree("plain/")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let servers = RemoteCopyStore(root: tree.url("Servers"), server: { $0 == server.id ? server : nil })
        let containers = ContainerCopyStore(root: tree.url("containers"))
        let engine = ContainerEngine(socket: "/tmp/strata-test.sock", name: "Docker", apiVersion: "1.41")
        let engineFolder = try containers.prepare(engine)

        #expect(FolderNotice.over(tree.url("plain"), containers: containers, servers: servers) == nil)
        let onServer = try #require(FolderNotice.over(servers.top(of: server.id).appending(path: "srv"), containers: containers, servers: servers))
        #expect(onServer.action == .disconnect(server))
        #expect(onServer.text.contains("Fixture"))
        // Another server's ID in the same root is no server of this window's.
        #expect(FolderNotice.over(servers.top(of: UUID().uuidString), containers: containers, servers: servers) == nil)
        let engineNotice = try #require(FolderNotice.over(engineFolder, containers: containers, servers: servers))
        #expect(engineNotice.action == .reload)
        #expect(engineNotice.text.contains("Docker"))
        withExtendedLifetime(tree) {}
    }

    @Test func overATrashOnlyOtherDisksTrashesThatHoldSomethingAreNamed() {
        let shown = URL(filePath: "/Users/fixture/.Trash", directoryHint: .isDirectory)
        let backup = URL(filePath: "/Volumes/Backup/.Trashes/501", directoryHint: .isDirectory)
        let photos = URL(filePath: "/Volumes/Photos/.Trashes/501", directoryHint: .isDirectory)
        let empty = URL(filePath: "/Volumes/Empty/.Trashes/501", directoryHint: .isDirectory)
        let home = Trash.Contents(folder: shown, disk: "Macintosh HD", count: 4)

        #expect(FolderNotice.otherTrashes([], besides: shown) == nil)
        #expect(FolderNotice.otherTrashes([home, Trash.Contents(folder: empty, disk: "Empty", count: 0)], besides: shown) == nil)
        let one = FolderNotice.otherTrashes([home, Trash.Contents(folder: backup, disk: "Backup", count: 3)], besides: shown)
        #expect(one?.action == .show(backup))
        #expect(one?.text.contains("Backup") == true && one?.text.contains("Macintosh HD") == false)
        let two = FolderNotice.otherTrashes([Trash.Contents(folder: photos, disk: "Photos", count: 2), home,
                                             Trash.Contents(folder: backup, disk: "Backup", count: 3)], besides: shown)
        #expect(two?.action == .show(photos))
        #expect(two?.text.contains("Photos") == true && two?.text.contains("Backup") == true)
    }
}
