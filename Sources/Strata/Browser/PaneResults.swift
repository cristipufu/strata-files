import AppKit

/// What a pane shows in place of a folder besides its rows: how many matched (a search, Recents) or what's said instead
/// (duplicate sets, a message while they're found), and the list's column widths from before, put back when the
/// folder returns.
final class PaneResults {
    enum Tally: Equatable {
        /// How many matched before the list was capped.
        case matched(Int)
        /// Said in place of a count; empty says nothing.
        case summary(String)
    }

    var tally = Tally.matched(0)
    private var widthsBefore: [(NSUserInterfaceItemIdentifier, CGFloat)] = []

    /// The status bar's words for the `shown` rows.
    func status(shown: Int) -> [String] {
        switch tally {
        case .summary(let summary):
            summary.isEmpty ? [] : [summary]
        case .matched(let total):
            [total > shown ? String(localized: "Top \(shown.formatted()) of \(total) results", comment: "plural")
                           : String(localized: "\(shown) results", comment: "plural")]
        }
    }

    /// Makes room in `list` for "Where" from Date and Kind, not from Name (the only column that gives up width on its
    /// own), remembering their widths.
    func makeRoomForWhere(in list: NSOutlineView) {
        widthsBefore = [.modified, .created, .kind].compactMap { id in list.tableColumn(withIdentifier: id).map { (id, $0.width) } }
        list.tableColumn(withIdentifier: .modified)?.width = 130
        list.tableColumn(withIdentifier: .created)?.width = 130
        list.tableColumn(withIdentifier: .kind)?.width = 120
        list.tableColumn(withIdentifier: .location)?.isHidden = false
    }

    /// Hides "Where" in `list` again and gives Date and Kind back their widths.
    func restoreColumns(in list: NSOutlineView) {
        list.tableColumn(withIdentifier: .location)?.isHidden = true
        for (id, width) in widthsBefore { list.tableColumn(withIdentifier: id)?.width = width }
        widthsBefore = []
    }
}
