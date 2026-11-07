import Testing
@testable import StrataIndex

struct IndexChangesTests {
    @Test func pathsIncludeTheirAncestorsAndDescendantsButNeverLookalikes() {
        var changes = IndexChanges()
        changes.insert("/home/Library/cache")
        #expect(changes.affects("/home") && changes.affects("/") && changes.affects("/home/Library/cache/child"))
        #expect(!changes.affects("/home/Documents") && !changes.affects("/home/Library/caches"))
        var later = IndexChanges()
        later.insert("/home/Documents/note.txt")
        changes.formUnion(later)
        #expect(changes.affects("/home/Documents") && changes.affects("/home/Library"))
        #expect(!changes.affects("/home/Documents/other.txt"))
        changes.formUnion(.all)
        #expect(changes.affects("/elsewhere"))
    }

    @Test func shallowFolderChangesAffectTheFolderAndItsAncestorsWithoutMarkingDescendants() {
        var changes = IndexChanges()
        changes.insert("/home/Documents", descendants: false)
        #expect(changes.affects("/") && changes.affects("/home") && changes.affects("/home/Documents"))
        #expect(!changes.affects("/home/Documents/Subfolder") && !changes.affects("/home/Documents/note.txt"))
        var removed = IndexChanges()
        removed.insert("/home/Documents")
        changes.formUnion(removed)
        #expect(changes.affects("/home/Documents/Subfolder"))
    }

    @Test func systemAndBrowserSpellingsReferToTheSamePath() {
        var changes = IndexChanges()
        changes.insert("/private/var/folders/fixture/note.txt")
        #expect(changes.affects("/var/folders/fixture"))
        var short = IndexChanges()
        short.insert("/tmp/fixture/note.txt")
        #expect(short.affects("/private/tmp/fixture"))
    }

    @Test func oversizedBatchesBecomeGlobalWithoutLosingSubsequentChanges() {
        var changes = IndexChanges()
        for index in 0..<IndexChanges.pathLimit { changes.insert("/fixture/\(index)") }
        #expect(!changes.affects("/elsewhere"))
        changes.insert("/fixture/last")
        #expect(changes == .all)
        var later = IndexChanges()
        later.insert("/another/path")
        changes.formUnion(later)
        #expect(changes == .all)
    }
}
