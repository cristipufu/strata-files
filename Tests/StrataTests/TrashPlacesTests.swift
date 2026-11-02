import Foundation
import Testing
@testable import Strata
@testable import StrataModel

/// A Trash is known by where it is, asking no disk: the home Trash in each spelling its disk treats as the same, and
/// another disk's `.Trashes/<your user id>` at the top of a disk the kernel lists.
struct TrashPlacesTests {
    private let uid = String(getuid())

    @Test func aDisksTrashIsKnownByTheDisksTheKernelLists() {
        let absent = "/Volumes/StrataNone-\(UUID().uuidString)"
        #expect(Trash.isTrash(URL(filePath: "/.Trashes/\(uid)", directoryHint: .isDirectory)))
        // A mounted disk's Trash however its mount point's case is typed, where the startup disk ignores case.
        if let volume = MountPoints.current().first(where: { $0.hasPrefix("/Volumes/") && $0.lowercased() != $0.uppercased() }) {
            let ignoresCase = (try? URL(filePath: "/").resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
                .volumeSupportsCaseSensitiveNames != true
            #expect(Trash.isTrash(URL(filePath: volume.uppercased() + "/.Trashes/\(uid)", directoryHint: .isDirectory)) == ignoresCase)
        }
        #expect(Trash.isInTrash(URL(filePath: "/.Trashes/\(uid)/a/b")))
        #expect(!Trash.isTrash(URL(filePath: absent + "/.Trashes/\(uid)", directoryHint: .isDirectory)))
        #expect(!Trash.isInTrash(URL(filePath: absent + "/.Trashes/\(uid)/a")))
        #expect(!Trash.isTrash(URL(filePath: "/.Trashes/0\(uid)", directoryHint: .isDirectory)))
        #expect(!Trash.isTrash(URL(filePath: "/.Trash/\(uid)", directoryHint: .isDirectory)))
    }

    @Test func theHomeTrashIsKnownInEachSpellingItsDiskTreatsAsTheSame() throws {
        let ignoresCase = try FileManager.default.homeDirectoryForCurrentUser
            .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames != true
        let shouted = URL(filePath: Trash.home.deletingLastPathComponent().path + "/.TRASH", directoryHint: .isDirectory)
        #expect(Trash.isTrash(Trash.home) && Trash.isInTrash(Trash.home.appending(path: "a/b")))
        #expect(Trash.isTrash(shouted) == ignoresCase)
        #expect(Trash.isInTrash(shouted.appending(path: "a")) == ignoresCase)
        #expect(!Trash.isTrash(Trash.home.deletingLastPathComponent()))
    }
}
