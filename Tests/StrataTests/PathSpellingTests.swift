import Foundation
import Testing
@testable import Strata
@testable import StrataFiles

/// Comparing and keying paths goes by their letters (`lexicallyStandardized`), spelled as `standardizedFileURL`
/// spells an item that exists, while a typed path is placed where the kernel takes it (`FileEntry.locate`).
struct PathSpellingTests {
    @Test func entrySnapshotsKeepTheirNormalizedLocationAndAllocatedBytesThroughLabelChanges() {
        for (path, expected) in [("/private/tmp/中文 😀/a/../b.txt", "/tmp/中文 😀/b.txt"),
                                 ("/tmp/中文 😀/b.txt", "/tmp/中文 😀/b.txt"), ("/var/a//b/./", "/var/a/b"), ("/", "/")] {
            let url = URL(filePath: path)
            let entry = FileEntry(url: url, name: url.lastPathComponent, isDirectory: false, isPackage: false,
                isHidden: false, isSymlink: false, isVolume: false, size: 9, modified: nil, created: nil, added: nil,
                kind: "Document", contentType: nil, allocatedSize: 4096)
            #expect(entry.locationKey == expected)
            let renamed = entry.with(kind: "Changed", displayName: "Label")
            #expect(renamed.locationKey == entry.locationKey && renamed.url == entry.url)
            #expect(renamed.allocatedSize == 4096 && renamed.size == 9 && renamed.displayName == "Label")
        }
    }

    @Test func aPathIsSpelledByItsLettersAsTheDiskSpellsAnItemThatExists() throws {
        let tree = try TestTree("a/b/c.txt")
        let base = tree.root.appending(path: "a/b", directoryHint: .isDirectory)
        for (url, expected) in [
            (URL(fileURLWithPath: "x/../c.txt", relativeTo: base), "a/b/c.txt"),
            (URL(fileURLWithPath: "../b/c.txt", relativeTo: base), "a/b/c.txt"),
            (URL(fileURLWithPath: tree.root.path + "/a//b/./c.txt"), "a/b/c.txt"),
            (URL(string: tree.root.absoluteString + "/a/x/%2e%2e/b/c.txt")!, "a/b/c.txt"),
        ] {
            #expect(url.lexicallyStandardized.path == tree.url(expected).standardizedFileURL.path, "\(url)")
        }
        // Gone or not yet made, it's spelled the same way.
        let missing = tree.url("a/gone/../never/d.txt")
        #expect(missing.lexicallyStandardized.path == PathSpelling.short(tree.url("a/never/d.txt").path))
        #expect(URL(fileURLWithPath: "/").lexicallyStandardized.path == "/")
        #expect(tree.snapshot() == ["a/", "a/b/", "a/b/c.txt"])
    }

    @Test func aTypedPathsDotDotIsTakenAfterTheLinksOnTheWay() async throws {
        let tree = try TestTree("home/", "away/a/b/", "away/a/notes.txt", "away/a/final.pdf", "home/notes.txt", "home/link -> away/a/b",
                                "home/report.pdf -> away/a/final.pdf")
        let typed = URL(fileURLWithPath: tree.url("home").path + "/link/../notes.txt")
        let (opening, located) = await FileEntry.locate(typed)
        // Through the link, `..` is its target's parent, which is where the check found an item, not the home folder.
        #expect(opening == .item)
        #expect(PathSpelling.short(located) == PathSpelling.short(tree.url("away/a/notes.txt")))
        // The last item stays as named: a link to a file elsewhere is that link, never the file it points to, so a
        // command on what's shown acts on the link.
        let (linkOpening, link) = await FileEntry.locate(URL(fileURLWithPath: tree.url("home").path + "/link/../../../home/report.pdf"))
        #expect(linkOpening == .item)
        #expect(PathSpelling.short(link) == PathSpelling.short(tree.url("home/report.pdf")))
        // Typed relative to a shell's folder, as to the `strata` command: the same places.
        let home = tree.url("home")
        #expect(PathSpelling.short(TypedPath.location(of: "link/../notes.txt", in: home)) == PathSpelling.short(tree.url("away/a/notes.txt")))
        #expect(PathSpelling.short(TypedPath.location(of: "link/../../../home/report.pdf", in: home))
            == PathSpelling.short(tree.url("home/report.pdf")))
        #expect(PathSpelling.short(TypedPath.location(of: tree.url("home/notes.txt").path, in: tree.url("away"))) == PathSpelling.short(tree.url("home/notes.txt")))
        // Typed relative to the shell's folder or in full, a path names the same place, spelled the same way: a folder
        // with its slash, a link as a link.
        for path in ["../away", "link", "link/", "link/..", "notes.txt", "link/../notes.txt", "missing", "."] {
            #expect(TypedPath.location(of: path, in: home) == TypedPath.location(of: home.path + "/" + path, in: tree.root), "\(path)")
        }
        #expect(TypedPath.location(of: "../away", in: home).hasDirectoryPath)
        #expect(tree.snapshot() == ["away/", "away/a/", "away/a/b/", "away/a/final.pdf", "away/a/notes.txt", "home/",
                                    "home/link -> away/a/b", "home/notes.txt", "home/report.pdf -> away/a/final.pdf"])
    }
}
