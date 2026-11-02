import Testing
@testable import Strata
@testable import StrataAI

/// The line under a search's results: how many, where, how many by content, and the search as it was understood.
@MainActor
struct SearchSummaryTests {
    @Test func countsWhereTheyAreFound() {
        #expect(PaneSearch.resultsSummary(total: 0, in: nil, byContent: 0, interpretation: nil, patternGaveUp: false)
            == "No results everywhere")
        #expect(PaneSearch.resultsSummary(total: 3, in: nil, byContent: 0, interpretation: nil, patternGaveUp: false)
            == "3 results everywhere")
        #expect(PaneSearch.resultsSummary(total: 0, in: "Documents", byContent: 0, interpretation: nil, patternGaveUp: false)
            == "No results in “Documents”")
        #expect(PaneSearch.resultsSummary(total: 12, in: "Documents", byContent: 0, interpretation: nil, patternGaveUp: false)
            == "12 results in “Documents”")
    }

    @Test func addsContentMatchesTheUnderstoodSearchAndAPatternThatGaveUp() {
        var filter = SearchFilter()
        filter.minSize = 10_000_000
        let parts = PaneSearch.resultsSummary(total: 5, in: "Desktop", byContent: 2, interpretation: filter, patternGaveUp: true)
            .components(separatedBy: " · ")
        #expect(parts == ["5 results in “Desktop”", "2 by content", filter.summary,
                          "the pattern took too long on some names, so they’re left out"])
    }
}
