import Foundation
import Testing
@testable import Strata

struct WorkspaceTests {
    private func plan(_ workspace: Workspace, existing: Set<String>) -> WorkspacePlan {
        WorkspacePlan(workspace) { existing.contains($0) }
    }

    @Test func workspacesSavedBeforeViewsWereKeptStillOpen() throws {
        let json = #"[{"name":"Old","tabs":[["/a"],["/b","/c"]]}]"#
        let decoded = try JSONDecoder().decode([Workspace].self, from: Data(json.utf8))
        #expect(decoded.count == 1)
        #expect(decoded[0].modes == nil && decoded[0].saved == nil && decoded[0].shares == nil)
        #expect(decoded[0].mode(tab: 1, pane: 1) == nil)
        let opened = plan(decoded[0], existing: ["/a", "/b", "/c"])
        #expect(opened.tabs.map { $0.map(\.path) } == [["/a"], ["/b", "/c"]])
        #expect(opened.tabs[1][1].mode == nil)
    }

    @Test func roundTripsEverything() throws {
        let workspace = Workspace(name: "Site", tabs: [["/a", "/b"]], modes: [[1, 2]], saved: Date(timeIntervalSince1970: 1000),
                                  shares: ["/Volumes/NAS": "smb://nas.local/share"])
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        #expect(decoded == workspace)
    }

    @Test func missingFoldersAreLeftOutAndTabsWithNoneGo() {
        let workspace = Workspace(name: "W", tabs: [["/gone"], ["/a", "/gone2"], ["/gone3", "/b"]], modes: [[0], [1, 2], [3, 4]])
        let opened = plan(workspace, existing: ["/a", "/b"])
        #expect(opened.tabs.map { $0.map(\.path) } == [["/a"], ["/b"]])
        // The pane left keeps its own view.
        #expect(opened.tabs.map { $0.map(\.mode) } == [[1], [4]])
        #expect(opened.missing == ["/gone", "/gone2", "/gone3"])
        #expect(opened.shares.isEmpty)
    }

    @Test func foldersOnAShareThatIsntConnectedWaitForIt() {
        let workspace = Workspace(name: "W", tabs: [["/Volumes/NAS/Projects/site", "/Users/me"]], modes: [[0, 1]],
                                  shares: ["/Volumes/NAS": "smb://nas.local/share"])
        let opened = plan(workspace, existing: ["/Users/me"])
        #expect(opened.tabs.count == 1)
        #expect(opened.tabs[0][0].waiting == WaitingFolder(path: "/Volumes/NAS/Projects/site", mode: 0, mountPoint: "/Volumes/NAS",
                                                           address: "smb://nas.local/share"))
        #expect(opened.tabs[0][1].waiting == nil)
        #expect(opened.shares == ["/Volumes/NAS": "smb://nas.local/share"])
        #expect(opened.missing.isEmpty)
    }

    @Test func aFolderGoneFromAConnectedShareIsMissing() {
        let workspace = Workspace(name: "W", tabs: [["/Volumes/NAS/old"]], shares: ["/Volumes/NAS": "smb://nas.local/share"])
        let opened = plan(workspace, existing: ["/Volumes/NAS"])
        #expect(opened.tabs.isEmpty)
        #expect(opened.missing == ["/Volumes/NAS/old"])
        #expect(opened.shares.isEmpty)
    }

    @Test func sharesMatchWholePathComponentsOnly() {
        let workspace = Workspace(name: "W", tabs: [["/Volumes/NAS2/x"]], shares: ["/Volumes/NAS": "smb://nas.local/share"])
        #expect(workspace.share(for: "/Volumes/NAS2/x") == nil)
        #expect(workspace.share(for: "/Volumes/NAS")?.mountPoint == "/Volumes/NAS")
        // Not on the share: on a disk that isn't connected.
        #expect(plan(workspace, existing: []).offline == ["/Volumes/NAS2/x"])
    }

    @Test func foldersOnADiskThatIsntConnectedAreKeptNotMissing() {
        let workspace = Workspace(name: "W", tabs: [["/Volumes/Backup/2026", "/a"], ["/Volumes/Backup"]], modes: [[2, 1], [3]])
        let opened = plan(workspace, existing: ["/a"])
        #expect(opened.missing.isEmpty)
        #expect(opened.offline == ["/Volumes/Backup/2026", "/Volumes/Backup"])
        #expect(opened.tabs.count == 2)
        #expect(opened.tabs[0][0].waiting == WaitingFolder(path: "/Volumes/Backup/2026", mode: 2))
        #expect(opened.tabs[1][0].waiting?.mountPoint == nil)
        // The disk is there but the folder isn't: gone.
        let gone = plan(workspace, existing: ["/a", "/Volumes/Backup"])
        #expect(gone.missing == ["/Volumes/Backup/2026"])
        #expect(gone.offline.isEmpty)
    }

    @Test func serverFoldersWaitForTheirServer() {
        let copy = "/Users/me/Library/Caches/dev.strata.app/Servers.noindex/0B5E6C2A-0000-0000-0000-000000000000/srv/app"
        let workspace = Workspace(name: "W", tabs: [[copy, "/a"]], modes: [[2, 1]])
        let opened = WorkspacePlan(workspace, exists: { $0 == "/a" }, server: { $0 == copy ? "0B5E6C2A-0000-0000-0000-000000000000" : nil })
        #expect(opened.tabs.count == 1)
        #expect(opened.tabs[0][0].waiting == WaitingFolder(path: copy, mode: 2, server: "0B5E6C2A-0000-0000-0000-000000000000"))
        #expect(opened.tabs[0][1].waiting == nil)
        #expect(opened.missing.isEmpty && opened.offline.isEmpty && opened.shares.isEmpty)
    }

    @Test func volumeOfAPath() {
        #expect(DiskOfPath.volume(of: "/Volumes/Backup/2026") == "/Volumes/Backup")
        #expect(DiskOfPath.volume(of: "/Volumes/Backup") == "/Volumes/Backup")
        #expect(DiskOfPath.volume(of: "/Volumes") == nil)
        #expect(DiskOfPath.volume(of: "/Users/me") == nil)
    }

    /// Reads are kept apart by disk; a cloud storage account in your home's Library, or iCloud Drive, answers through
    /// its own provider, so it counts as one, and a folder elsewhere that's merely named so doesn't.
    @Test func diskOfAPath() {
        let home = "/Users/me"
        #expect(DiskOfPath.of("/Volumes/Share/a/b", home: home) == "/Volumes/Share")
        #expect(DiskOfPath.of("/Users/me/Library/CloudStorage/OneDrive-Work/Docs/a.docx", home: home)
            == "/Users/me/Library/CloudStorage/OneDrive-Work")
        #expect(DiskOfPath.of("/Users/me/Library/CloudStorage/Dropbox", home: home)
            == "/Users/me/Library/CloudStorage/Dropbox")
        #expect(DiskOfPath.of("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/a", home: home)
            == "/Users/me/Library/Mobile Documents")
        #expect(DiskOfPath.of("/Users/me/Library/Mobile Documents/iCloud~com~app/b", home: home)
            == "/Users/me/Library/Mobile Documents")
        #expect(DiskOfPath.of("/Users/me/src/Library/CloudStorage/x", home: home) == "/")
        #expect(DiskOfPath.of("/Users/me/Documents/a", home: home) == "/")
        #expect(DiskOfPath.of("/Users/me/Library/CloudStorage/Box/a", home: "/Users/me/")
            == "/Users/me/Library/CloudStorage/Box")
        #expect(DiskOfPath.of("/Volumes", home: home) == "/")
    }

    @Test func theInnermostShareWins() {
        let workspace = Workspace(name: "W", tabs: [], shares: ["/Volumes/A": "smb://a/x", "/Volumes/A/B": "smb://b/y"])
        #expect(workspace.share(for: "/Volumes/A/B/c")?.address == "smb://b/y")
        #expect(workspace.share(for: "/Volumes/A/c")?.address == "smb://a/x")
    }

    @Test func aShareMountedElsewhereMovesItsFolders() {
        #expect(WorkspacePlan.path("/Volumes/NAS/Projects", from: "/Volumes/NAS", to: "/Volumes/NAS-1") == "/Volumes/NAS-1/Projects")
        #expect(WorkspacePlan.path("/Volumes/NAS", from: "/Volumes/NAS", to: "/Volumes/NAS-1/") == "/Volumes/NAS-1")
        #expect(WorkspacePlan.path("/Volumes/NASX/a", from: "/Volumes/NAS", to: "/Volumes/NAS-1") == "/Volumes/NASX/a")
    }

    @Test func removingFoldersKeepsViewsAndShares() {
        let workspace = Workspace(name: "W", tabs: [["/a", "/Volumes/NAS/x"], ["/gone"]], modes: [[1, 2], [3]],
                                  saved: Date(timeIntervalSince1970: 5), shares: ["/Volumes/NAS": "smb://nas/s"])
        let pruned = workspace.removing(["/gone"])
        #expect(pruned.tabs == [["/a", "/Volumes/NAS/x"]])
        #expect(pruned.modes == [[1, 2]])
        #expect(pruned.shares == ["/Volumes/NAS": "smb://nas/s"])
        let noShare = workspace.removing(["/Volumes/NAS/x", "/gone"])
        #expect(noShare.tabs == [["/a"]])
        #expect(noShare.modes == [[1]])
        #expect(noShare.shares == nil)
        #expect(noShare.saved == workspace.saved)
    }

    @Test func removingFromAWorkspaceWithoutViewsKeepsItWithout() {
        let workspace = Workspace(name: "W", tabs: [["/a", "/b"]])
        #expect(workspace.removing(["/b"]).modes == nil)
    }

    @Test func onlyTwoPanesATab() {
        let workspace = Workspace(name: "W", tabs: [["/a", "/b", "/c"]])
        #expect(plan(workspace, existing: ["/a", "/b", "/c"]).tabs[0].count == 2)
    }

    @Test func dualPaneAndModes() {
        #expect(Workspace(name: "W", tabs: [["/a"], ["/b", "/c"]]).isDualPane)
        #expect(!Workspace(name: "W", tabs: [["/a"], ["/b"]]).isDualPane)
        let workspace = Workspace(name: "W", tabs: [["/a"]], modes: [[3]])
        #expect(workspace.mode(tab: 0, pane: 0) == 3)
        #expect(workspace.mode(tab: 0, pane: 1) == nil)
        #expect(workspace.mode(tab: 5, pane: 0) == nil)
    }
}
