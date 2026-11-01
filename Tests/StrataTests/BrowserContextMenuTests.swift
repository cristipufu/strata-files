import AppKit
import Testing
@testable import Strata
@testable import StrataFiles

/// What a pane's context menu offers to change files, decided from where the selection is, with no window or disk.
struct BrowserContextMenuTests {
    private let here = URL(fileURLWithPath: "/strata-menu-fixture/a.txt")
    private let trash = Trash.home

    @Test func anItemOnThisMacIsMovedToTheTrashAndOneInATrashIsPutBackOrDeleted() {
        let local = actions([entry(here)])
        #expect(local.contains(StrataCommand.moveToTrash.action))
        #expect(!local.contains(StrataCommand.putBack.action))
        #expect(!local.contains(StrataCommand.deleteImmediately.action))
        let trashed = actions([entry(trash.appending(path: "a.txt"))])
        #expect(Array(trashed.prefix(2)) == [StrataCommand.putBack.action, StrataCommand.deleteImmediately.action])
        #expect(trashed.contains(#selector(AppDelegate.emptyTrash(_:))))
        #expect(!trashed.contains(StrataCommand.moveToTrash.action))
        // Inside a trashed folder: already in the Trash, and not put back on its own.
        let inside = actions([entry(trash.appending(path: "f/a.txt"))])
        #expect(!inside.contains(StrataCommand.moveToTrash.action))
        #expect(!inside.contains(StrataCommand.putBack.action))
    }

    @Test func aServerOrAnArchiveIsOfferedOnlyWhatItCanDo() {
        // A server has no Trash: Delete… asks and deletes for good; nothing that would change it another way.
        var server = facts([entry(here)])
        server.isOnServer = true
        let onServer = actions(server)
        #expect(onServer.contains(StrataCommand.moveToTrash.action))
        for command in [StrataCommand.cut, .duplicate, .compress, .addToShelf] {
            #expect(!onServer.contains(command.action), "\(command.id)")
        }
        // An archive's or a container's copy is read-only: copying out, nothing that changes it.
        var archive = facts([entry(here)])
        archive.isInsideArchive = true
        let inArchive = actions(archive)
        #expect(inArchive.contains(StrataCommand.copy.action))
        for command in [StrataCommand.moveToTrash, .renameSelection, .cut, .duplicate, .compress] {
            #expect(!inArchive.contains(command.action), "\(command.id)")
        }
    }

    private func actions(_ selection: [FileEntry]) -> [Selector?] {
        actions(facts(selection))
    }

    private func actions(_ facts: BrowserContextMenu.Facts) -> [Selector?] {
        BrowserContextMenu(facts: facts, target: NSObject()) { _ in }.make().items.map(\.action)
    }

    private func entry(_ url: URL) -> FileEntry {
        FileEntry(url: url, name: url.lastPathComponent, isDirectory: false, isPackage: false, isHidden: false, isSymlink: false,
                  isVolume: false, size: nil, modified: nil, created: nil, added: nil, kind: "", contentType: nil)
    }

    private func facts(_ selection: [FileEntry]) -> BrowserContextMenu.Facts {
        BrowserContextMenu.Facts(
            selection: selection, showsHiddenFiles: false, isOnServer: false, serverHasShell: false, isInsideArchive: false,
            isInContainerCopy: false, isShowingTrash: false, clipboardHasFiles: false, canTag: false, renameTitle: "Rename",
            compressTitle: "Compress", extractTitle: "Extract", appUpdatesTitle: "", hasArchives: false, hasApps: false,
            containers: [], canDownload: false, canRemoveDownload: false, opensAsFolder: false, folderIsStack: false,
            folderIsEngine: false, folderIsArchiveCopy: false, selectionIsStacks: false, hasStackProjects: false, appliedTags: [:])
    }
}
