import Foundation

nonisolated package enum ShellQuote {
    /// Single-quotes `text` for sh/zsh.
    package static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    package static func quoteIfNeeded(_ text: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:/@%+=,"))
        return !text.isEmpty && text.unicodeScalars.allSatisfy(safe.contains) ? text : quote(text)
    }
}
