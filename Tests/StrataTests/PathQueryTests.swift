import Foundation
import Testing
@testable import Strata

final class PathQueryTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "strata-tests-\(UUID().uuidString)")
        for dir in ["Documents/GitHub/atlas/src", "Documents/GitHub/harbor", "Documents/GitHub/strata", "Downloads/atlas-old"] {
            try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: root.appending(path: "Documents/GitHub/atlas/README.md").path, contents: Data())
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private var github: URL { root.appending(path: "Documents/GitHub") }
    private var roots: [URL] { [github, root.appending(path: "Documents"), root.appending(path: "Downloads")] }

    @Test func walksDownFromAFolderMatchingTheFirstPart() {
        let hits = PathQuery().resolve("github/atlas", roots: roots, visited: [])
        // Listings report the temp folder as /private/var/…; compare with symlinks resolved.
        #expect(hits.first?.url.resolvingSymlinksInPath() == github.appending(path: "atlas").resolvingSymlinksInPath())
    }

    @Test func partsAreFuzzy() {
        let hits = PathQuery().resolve("gh/strt", roots: roots, visited: [])
        #expect(hits.first?.url.lastPathComponent == "strata")
    }

    @Test func visitedFoldersMatchAcrossSkippedLevels() {
        let strata = github.appending(path: "strata")
        let hits = PathQuery().resolve("docs/strata", roots: [], visited: [strata])
        #expect(hits.first?.url == strata)
    }

    @Test func trailingSlashListsEverythingInside() {
        let names = Set(PathQuery().resolve("github/", roots: roots, visited: []).map(\.url.lastPathComponent))
        #expect(names == ["atlas", "harbor", "strata"])
    }

    @Test func firstPartCanNameAFolderInsideARoot() {
        let names = Set(PathQuery().resolve("strata/", roots: [github], visited: []).map(\.url.lastPathComponent))
        #expect(names.isEmpty) // strata is empty, but the lookup must not fail on it
        let hit = PathQuery().resolve("atlas/src", roots: [github], visited: []).first
        #expect(hit?.url.lastPathComponent == "src")
    }

    @Test func lastPartAlsoMatchesFiles() {
        let hit = PathQuery().resolve("atlas/readme", roots: [github.appending(path: "atlas")], visited: []).first
        #expect(hit?.url.lastPathComponent == "README.md")
        #expect(hit?.isFolder == false)
    }

    @Test func plainNamesAndAbsolutePathsAreNotPathQueries() {
        #expect(!PathQuery.isPathQuery("github"))
        #expect(!PathQuery.isPathQuery("~/Documents"))
        #expect(!PathQuery.isPathQuery("/Applications"))
        #expect(PathQuery.isPathQuery("github/atlas"))
    }

    @Test func pathSuggestionsFollowInjectedHiddenFilesPreference() async throws {
        let hiddenDir = github.appending(path: ".secret-repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)

        let prefsHiddenOff = try Prefs.isolated()
        let prefsHiddenOn = try Prefs.isolated()
        prefsHiddenOff.showHidden = false
        prefsHiddenOn.showHidden = true

        let suggestOff = PathSuggestions(prefsHiddenOff)
        let suggestOn = PathSuggestions(prefsHiddenOn)

        let offNames = await suggestOff.suggestions(for: github.path + "/", in: github).map(\.url.lastPathComponent)
        let onNames = await suggestOn.suggestions(for: github.path + "/", in: github).map(\.url.lastPathComponent)
        #expect(offNames == ["atlas", "harbor", "strata"])
        #expect(onNames == [".secret-repo", "atlas", "harbor", "strata"])

        // Typing a leading dot still reveals hidden folders even when showHidden is off.
        let dotNames = await suggestOff.suggestions(for: github.path + "/.s", in: github).map(\.url.lastPathComponent)
        #expect(dotNames == [".secret-repo"])
    }
}

struct FuzzyTests {
    @Test func wordStartsBeatScatteredLetters() throws {
        let good = try #require(Fuzzy.match("spg", "sprite-generator"))
        let scattered = try #require(Fuzzy.match("spg", "suno-api-gcui-bak"))
        #expect(good.score > scattered.score)
    }

    @Test func returnsMatchedCharacterOffsets() throws {
        let match = try #require(Fuzzy.match("tun", "tunnelite"))
        #expect(match.indices == [0, 1, 2])
    }

    @Test func requiresEveryCharacterInOrder() {
        #expect(Fuzzy.match("xz", "strata") == nil)
        #expect(Fuzzy.match("ats", "strata") == nil)
    }
}
