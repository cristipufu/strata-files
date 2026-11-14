import Foundation
import Testing
@testable import StrataSupport

/// The one rule for what an excluded folder covers, which the index, its events, its scans and Settings all ask.
struct IndexExcludedFoldersTests {
    @Test func aFolderCoversItselfAndWhatIsInsideItByWholeComponentsInAnyLetterCase() {
        let excluded: IndexExcludedFolders = ["/Users/me/vscode/IR", "/Users/me/Мои"]
        for path in ["/Users/me/vscode/IR", "/Users/me/vscode/IR/", "/Users/me/vscode/IR/x", "/Users/me/vscode/ir",
                     "/Users/me/vscode/ir/new.txt", "/USERS/me/VSCode/iR/deep/b", "/Users/me/vscode/IR//x",
                     "/Users/me/мои/файл"] {
            #expect(excluded.covers(path), "\(path)")
        }
        for path in ["/Users/me/vscode/IR2", "/Users/me/vscode/ir2/x.txt", "/Users/me/vscode/IR.txt", "/Users/me/vscode/I",
                     "/Users/me/vscode", "/Users/me/vscode/xIR", "/Users/me/мои2", "relative/IR", "Users/me/vscode/IR", ""] {
            #expect(!excluded.covers(path), "\(path)")
        }
        #expect(excluded.contains("/users/me/VSCODE/ir") && excluded.contains("/Users/me/vscode/IR/"))
        #expect(!excluded.contains("/Users/me/vscode/IR/x") && !excluded.contains("/Users/me/vscode"))
    }

    @Test func noFoldersCoverNothingAndTheRootCoversEveryPath() {
        let none = IndexExcludedFolders()
        #expect(none.isEmpty && !none.covers("/Users/me") && !none.covers("/") && !none.contains("/"))
        let root: IndexExcludedFolders = ["/"]
        #expect(!root.isEmpty && root.covers("/") && root.covers("/Users/me/x"))
        #expect(!root.covers("relative") && !root.covers(""))
        #expect(root.contains("/") && root.contains("//") && !root.contains("/Users"))
    }

    @Test func relativePathsNameNoFolderAndTrailingSlashesChangeNone() {
        var folders: IndexExcludedFolders = ["relative", "", "/a/IR///"]
        #expect(folders.paths == ["/a/IR"])
        folders.insert("b/c")
        folders.insert("/b/")
        #expect(folders.paths == ["/a/IR", "/b"])
        #expect(folders.covers("/b/x") && folders.covers("/a/ir/x") && !folders.covers("b/c"))
        for (path, trimmed) in [("/", "/"), ("///", "/"), ("/a//", "/a"), ("/a", "/a"), ("", ""), ("a/", "a")] {
            #expect(IndexExcludedFolders.withoutTrailingSlashes(path) == trimmed, "\(path)")
        }
    }

    @Test func lettersWhoseCasesDifferInLengthOrInHowTheyAreComposedStillMatch() {
        // "İ" is two bytes and its lowercase three; "é" is one scalar here and two in the paths below.
        let excluded: IndexExcludedFolders = ["/a/İstanbul", "/a/caf\u{E9}"]
        #expect(excluded.covers("/a/i\u{307}stanbul/x") && excluded.covers("/a/İSTANBUL"))
        #expect(excluded.covers("/a/cafe\u{301}/menu") && excluded.covers("/A/CAF\u{C9}"))
        #expect(excluded.contains("/A/İSTANBUL/") && excluded.contains("/a/cafe\u{301}"))
        #expect(!excluded.covers("/a/istanbul") && !excluded.covers("/a/cafe") && !excluded.covers("/a/caf\u{E9}s"))
    }

    @Test func aFolderEndsAtASlashEvenWhereAMarkJoinsTheNextName() {
        // Read as characters, a slash and a combining mark after it are one, and the folder would never end.
        let excluded: IndexExcludedFolders = ["/Users/me/Büro", "/Users/me/plain", "/Users/me/\u{600}"]
        for name in ["\u{301}x", "\u{FE0F}", "\u{200D}y", "\u{3099}", "\u{1F3FB}"] {
            let scalars = name.unicodeScalars.map(\.value)
            #expect(excluded.covers("/Users/me/Büro/" + name), "\(scalars)")
            #expect(excluded.covers("/Users/me/BÜRO/" + name + "/deeper"), "\(scalars)")
            #expect(excluded.covers("/Users/me/plain/" + name), "\(scalars)")
            #expect(!excluded.covers("/Users/me/Büro2/" + name), "\(scalars)")
        }
        // A name that ends in a mark joining what follows still ends where its slash is.
        #expect(excluded.covers("/Users/me/\u{600}/x") && !excluded.covers("/Users/me/\u{600}x"))
        #expect(!excluded.covers("/Users/me/Büro\u{301}") && !excluded.contains("/Users/me/Büro/\u{301}x"))
    }

    @Test func aNameEqualToAPlainOneInAnotherSpellingIsThatFolder() {
        // The Greek question mark is the semicolon, spelled in more bytes.
        let excluded: IndexExcludedFolders = ["/a/\u{37E}", "/a/caf\u{E9}"]
        #expect(excluded.contains("/a/;") && excluded.covers("/a/;") && excluded.covers("/a/;/x"))
        #expect(excluded.contains("/a/\u{37E}") && excluded.covers("/a/\u{37E}/x") && !excluded.covers("/a/;x"))
        #expect(IndexExcludedFolders(["/a/;"]).covers("/a/\u{37E}/x"))
    }

    @Test func aPathIsComparedNoDeeperThanTheDeepestFolder() {
        let excluded: IndexExcludedFolders = ["/a/é", "/a/b/c", "/ü/b/c"]
        let deep = (0..<4000).map { "d\($0)" }.joined(separator: "/")
        #expect(excluded.covers("/a/é/" + deep) && excluded.covers("/a/b/c/é/" + deep))
        #expect(!excluded.covers("/a/x/é/" + deep) && !excluded.covers("/é/a/b/c/" + deep))
        #expect(!excluded.covers("/a/b/é/c/" + deep) && !excluded.covers("/a/b/c\u{301}/" + deep))
        // The deepest folder is still compared, as a folder above the path and as the whole of it.
        #expect(excluded.covers("/ü/b/c/" + deep) && excluded.covers("/Ü/B/C") && excluded.covers("/ü/b/c/"))
        #expect(!excluded.covers("/ü/b/x/c/" + deep) && !excluded.covers("/ü/b") && !excluded.covers("/ü/b/cc"))
        #expect(excluded.covers("/a/b/c") && excluded.covers("/A/É") && !excluded.covers("/a/b/é"))
    }

    @Test func aListIsInsideAnotherWhenEveryFolderOfItIsOneOfTheOthers() {
        #expect(IndexExcludedFolders(["/a/IR"]).isSubset(of: ["/A/ir", "/b"]))
        #expect(IndexExcludedFolders().isSubset(of: []))
        #expect(!IndexExcludedFolders(["/a/IR", "/c"]).isSubset(of: ["/a/ir"]))
        // A folder inside one of the others is not one of them.
        #expect(!IndexExcludedFolders(["/a/IR/deep"]).isSubset(of: ["/a/IR"]))
    }

    /// The rule said plainly: folded, a path is an excluded folder or goes on from one with a slash. In bytes, since
    /// a slash is one whatever follows it.
    private func plainly(_ path: [UInt8], coveredBy excluded: [[UInt8]]) -> Bool {
        excluded.contains { folder in
            folder == [slash] ? path.first == slash : path == folder || path.starts(with: folder + [slash])
        }
    }

    private func folded(_ path: String) -> [UInt8] {
        Array(path.lowercased().precomposedStringWithCanonicalMapping.utf8)
    }

    private let slash = UInt8(ascii: "/")

    @Test func theAnswerIsThePlainRulesForEveryListAndPathTried() {
        let names = ["IR", "ir", "IR2", "IR.txt", "I", "a", "A", "ab", "é", "É", "e\u{301}", "straße", "STRASSE", "İstanbul",
                     "x y", "\u{301}x", "\u{FE0F}", "\u{600}", ";", "\u{37E}"]
        var folders: [String] = []
        for outer in names {
            folders.append("/" + outer)
            for inner in names { folders.append("/" + outer + "/" + inner) }
        }
        var paths = folders + ["/", "", "relative", "relative/IR", "/IR/", "/IR//x"]
        for folder in folders where folder.utf8.count < 12 {
            for name in ["x", "IR", "é", "\u{301}", "\u{200D}y/z"] { paths.append(folder + "/" + name) }
        }
        let foldedPaths = paths.map(folded)
        var differing: [String] = []
        for start in stride(from: 0, to: folders.count, by: 7) {
            var excluded = [folders[start], folders[(start * 5 + 3) % folders.count], folders[(start * 11 + 1) % folders.count]]
            if start % 49 == 0 { excluded.append("/") }
            let lookup = IndexExcludedFolders(excluded), plain = excluded.map(folded)
            for (path, bytes) in zip(paths, foldedPaths) where lookup.covers(path) != plainly(bytes, coveredBy: plain) {
                differing.append("\(path) in \(excluded)")
            }
        }
        #expect(differing == [])
    }

    @Test func aFullListCoversWhatIsInEachOfItsFoldersAndNothingBesideThem() {
        let full = IndexExcludedFolders((0..<100).map { "/Users/me/projects/client-\($0)/build" })
        #expect(full.paths.count == 100)
        for client in [0, 9, 10, 99] {
            #expect(full.covers("/Users/me/projects/client-\(client)/build/obj/file.o"), "\(client)")
            #expect(!full.covers("/Users/me/projects/client-\(client)/src/main.c"), "\(client)")
        }
        #expect(!full.covers("/Users/me/projects/client-100/build") && !full.covers("/Users/me/projects/client-1/builds"))
        #expect(!full.covers("/Users/me/work/project/node_modules/package/lib/file.js"))
    }
}
