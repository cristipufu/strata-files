import Foundation

/// What a pane showing results (a search, Recents, Duplicates) is called: the path bar shows a search's query, the
/// window's title and the pane's header say it's a search; nil for a folder.
struct ResultsTitle: Equatable {
    let pathBar: String
    let window: String
    let symbol: String

    init?(_ destination: Destination) {
        switch destination {
        case .folder:
            return nil
        case .search(let text, _):
            let isLargeFiles = text == BrowserWindowController.largeFilesQuery
            let largeFiles = String(localized: "Large Files")
            pathBar = isLargeFiles ? largeFiles
                : String(localized: "“\(text)”", comment: "Path bar title while searching: the search text in quotes")
            window = isLargeFiles ? largeFiles : String(localized: "Search: \(text)", comment: "Window title while searching; the search text")
            symbol = "magnifyingglass"
        case .recents:
            pathBar = String(localized: "Recents", comment: "Title of the view listing recently used files")
            window = pathBar
            symbol = "clock"
        case .duplicates:
            pathBar = String(localized: "Duplicates", comment: "Title of the view listing duplicate files")
            window = pathBar
            symbol = "square.on.square"
        }
    }
}
