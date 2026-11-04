import AppKit
import CPreviewText

package enum PreviewSearchScope {
    case document, page
    package var label: String {
        switch self {
        case .document: String(localized: "Find")
        case .page: String(localized: "Find on This Page")
        }
    }
    package var hint: String {
        switch self {
        case .document: String(localized: "Find text in this document.")
        case .page: String(localized: "Find text on the current page only.")
        }
    }
}

package protocol PreviewDocumentSearch: AnyObject {
    var searchScope: PreviewSearchScope { get }
    func find(_ query: String)
    func findNext(backwards: Bool)
}

extension PreviewDocumentSearch {
    package var searchScope: PreviewSearchScope { .document }
}

final class PreviewTextSearch {
    private let textView: STPreviewTextView
    private(set) var matches: [NSRange] = []
    private var current = -1

    init(textView: STPreviewTextView) { self.textView = textView }

    func find(_ query: String) {
        guard textView.renderingError == nil else { return }
        let whole = NSRange(location: 0, length: textView.string.utf16.count)
        let previous = matches.indices.contains(current) ? matches[current] : nil
        matches = []; current = -1
        guard !query.isEmpty else {
            guard textView.highlightRanges([], clearing: whole) else { return }
            if let previous, textView.selectedRange() == previous { textView.setSelectedRange(NSRange(location: previous.location, length: 0)) }
            return
        }
        let text = textView.string as NSString
        var remaining = whole
        while remaining.length > 0, matches.count < 10_000 {
            let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: remaining)
            guard range.location != NSNotFound, range.length > 0 else { break }
            matches.append(range)
            remaining = NSRange(location: NSMaxRange(range), length: whole.length - NSMaxRange(range))
        }
        guard textView.highlightRanges(matches.map(NSValue.init(range:)), clearing: whole) else {
            matches = []
            return
        }
        findNext(backwards: false)
    }

    func findNext(backwards: Bool) {
        guard textView.renderingError == nil, !matches.isEmpty else { return }
        current = (current + (backwards ? matches.count - 1 : 1)) % matches.count
        if !textView.revealRange(matches[current]) { matches = []; current = -1 }
    }
}
