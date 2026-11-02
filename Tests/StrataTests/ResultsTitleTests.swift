import Foundation
import Testing
@testable import Strata

/// A results view's titles: the path bar shows a search's query, the window says it's a search, Large Files by name.
struct ResultsTitleTests {
    @Test func aSearchShowsItsQueryAndLargeFilesItsName() throws {
        #expect(ResultsTitle(.folder(URL(fileURLWithPath: "/tmp"))) == nil)
        let search = try #require(ResultsTitle(.search("kind:pdf report", scope: nil)))
        #expect(search.pathBar.contains("kind:pdf report") && search.window.contains("kind:pdf report"))
        #expect(search.pathBar != search.window)
        let large = try #require(ResultsTitle(.search(BrowserWindowController.largeFilesQuery, scope: nil)))
        #expect(large.pathBar == large.window && !large.window.contains("size:"))
        let recents = try #require(ResultsTitle(.recents))
        let duplicates = try #require(ResultsTitle(.duplicates))
        #expect(recents.pathBar == recents.window && duplicates.pathBar == duplicates.window && recents.window != duplicates.window)
        #expect(Set([search.symbol, recents.symbol, duplicates.symbol]).count == 3)
    }
}
