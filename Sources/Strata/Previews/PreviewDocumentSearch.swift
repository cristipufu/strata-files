import AppKit

package protocol PreviewDocumentSearch: AnyObject {
    func find(_ query: String)
    func findNext(backwards: Bool)
}

final class PreviewTextSearch {
    private let textView: NSTextView
    private(set) var matches: [NSRange] = []
    private var current = -1

    init(textView: NSTextView) { self.textView = textView }

    func find(_ query: String) {
        let whole = NSRange(location: 0, length: textView.string.utf16.count)
        textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
        textView.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        let previous = matches.indices.contains(current) ? matches[current] : nil
        matches = []; current = -1
        guard !query.isEmpty else {
            if let previous, textView.selectedRange() == previous { textView.setSelectedRange(NSRange(location: previous.location, length: 0)) }
            return
        }
        let text = textView.string as NSString
        var remaining = whole
        while remaining.length > 0, matches.count < 10_000 {
            let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: remaining)
            guard range.location != NSNotFound, range.length > 0 else { break }
            matches.append(range)
            textView.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor,
                                                         forCharacterRange: range)
            textView.layoutManager?.addTemporaryAttribute(.foregroundColor, value: NSColor.selectedTextColor, forCharacterRange: range)
            remaining = NSRange(location: NSMaxRange(range), length: whole.length - NSMaxRange(range))
        }
        findNext(backwards: false)
    }

    func findNext(backwards: Bool) {
        guard !matches.isEmpty else { return }
        current = (current + (backwards ? matches.count - 1 : 1)) % matches.count
        textView.setSelectedRange(matches[current])
        textView.scrollRangeToVisible(matches[current])
    }
}
