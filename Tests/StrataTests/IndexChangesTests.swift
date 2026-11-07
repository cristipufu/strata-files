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
        changes.insert("/home/Documents", descendants: false, affectsCapacity: false)
        #expect(changes.affects("/") && changes.affects("/home") && changes.affects("/home/Documents"))
        #expect(!changes.affects("/home/Documents/Subfolder") && !changes.affects("/home/Documents/note.txt"))
        #expect(!changes.affectsCapacity)
        var removed = IndexChanges()
        removed.insert("/home/Documents")
        changes.formUnion(removed)
        #expect(changes.affects("/home/Documents/Subfolder") && changes.affectsCapacity)
    }

    @Test func hiddenAndNoiseChangesAreFilteredOutUnlessRequested() {
        var changes = IndexChanges()
        changes.insert("/home/Library/Caches/entry.db", hiddenOrNoise: true)
        changes.insert("/home/Library/Caches", descendants: false, hiddenOrNoise: true)
        #expect(changes.hasChanges && !changes.affectsRecents && !changes.affectsSearch)
        #expect(changes.affects("/home") && changes.affects("/home/Library"))
        #expect(!changes.affects("/home", includeHiddenAndNoise: false))
        #expect(!changes.affects("/home/Library", includeHiddenAndNoise: false))
        var visible = IndexChanges()
        visible.insert("/home/Documents/report.pdf")
        changes.formUnion(visible)
        #expect(changes.affectsRecents && changes.affectsSearch)
        #expect(changes.affects("/home", includeHiddenAndNoise: false))
        #expect(changes.affects("/home/Documents", includeHiddenAndNoise: false))
        #expect(!changes.affects("/home/Library", includeHiddenAndNoise: false))
        var mixed = IndexChanges()
        mixed.insert("/home/Project", descendants: false, hiddenOrNoise: false)
        mixed.insert("/home/Project", descendants: true, hiddenOrNoise: true)
        #expect(mixed.affectsSearch && mixed.affects("/home/Project", includeHiddenAndNoise: false))
        #expect(!mixed.affects("/home/Project/Subfolder", includeHiddenAndNoise: false))
        var combined = IndexChanges()
        combined.formUnion(mixed)
        #expect(combined.affectsSearch && combined.affects("/home/Project", includeHiddenAndNoise: false))
        #expect(!combined.affects("/home/Project/Subfolder", includeHiddenAndNoise: false))
    }

    @Test func systemAndBrowserSpellingsReferToTheSamePath() {
        var changes = IndexChanges()
        changes.insert("/private/var/folders/fixture/note.txt")
        #expect(changes.affects("/var/folders/fixture"))
        var short = IndexChanges()
        short.insert("/tmp/fixture/note.txt")
        #expect(short.affects("/private/tmp/fixture"))
        var combining = IndexChanges()
        combining.insert("/home/Documents/\u{0301}x.txt")
        #expect(combining.affects("/home/Documents"))
        var parentChanged = IndexChanges()
        parentChanged.insert("/home/Documents")
        #expect(parentChanged.affects("/home/Documents/\u{0301}x.txt"))
        var composed = IndexChanges()
        composed.insert("/home/caf\u{00E9}/note.txt")
        #expect(composed.affects("/home/cafe\u{0301}"))
        var decomposedFolder = IndexChanges()
        decomposedFolder.insert("/home/cafe\u{0301}")
        #expect(decomposedFolder.affects("/home/caf\u{00E9}/note.txt"))
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
