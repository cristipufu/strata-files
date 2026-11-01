import Foundation
import UniformTypeIdentifiers

/// A structured file search: what `QueryInterpreter` makes of "pdfs from last week bigger than 10mb about invoices".
/// Metadata fields are for the filename index; `contentQuery` is for `SemanticIndex`.
package nonisolated struct SearchFilter: Sendable, Hashable, Codable {
    package enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case folder, document, pdf, text, image, movie, audio, archive, code, spreadsheet, presentation, application, diskImage, book, comic

        package var title: String { names.title }

        /// The title in English: the name of a folder a plan groups this kind into when the translation can't be one.
        package var englishTitle: String { names.englishTitle }

        /// The kind inside a sentence ("Move into “Archive” — only images named “Screenshot”").
        package var noun: String { names.noun }

        package var symbol: String { names.symbol }

        private struct Names: Sendable {
            let title: String
            let englishTitle: String
            let noun: String
            let symbol: String
        }

        /// Read once: the app's language is chosen at launch.
        private static let allNames = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.makeNames()) })

        private var names: Names { Self.allNames[self, default: makeNames()] }

        private func makeNames() -> Names {
            switch self {
            case .book:
                Names(title: String(localized: "Books"),
                      englishTitle: "Books",
                      noun: String(localized: "books"),
                      symbol: "book.closed")
            case .comic:
                Names(title: String(localized: "Comics"),
                      englishTitle: "Comics",
                      noun: String(localized: "comics"),
                      symbol: "book.pages")
            case .folder:
                Names(title: String(localized: "Folders", comment: "Kind of items; also the name of a folder a plan groups them into"),
                      englishTitle: "Folders",
                      noun: String(localized: "folders", comment: "Kind of items, inside a sentence: “only folders named “2024””"),
                      symbol: "folder")
            case .document:
                Names(title: String(localized: "Documents", comment: "Kind of items; also the name of a folder a plan groups them into"),
                      englishTitle: "Documents",
                      noun: String(localized: "documents", comment: "Kind of items, inside a sentence: “only documents named “Invoice””"),
                      symbol: "doc.text")
            case .pdf:
                Names(title: String(localized: "PDFs", comment: "Kind of items; also the name of a folder a plan groups them into"),
                      englishTitle: "PDFs",
                      noun: String(localized: "PDFs", comment: "Kind of items; also the name of a folder a plan groups them into"),
                      symbol: "doc.richtext")
            case .text:
                Names(title: String(localized: "Text files", comment: "Kind of items; also the name of a folder a plan groups them into"),
                      englishTitle: "Text files",
                      noun: String(localized: "text files", comment: "Kind of items, inside a sentence: “only text files named “notes””"),
                      symbol: "doc.plaintext")
            case .image:
                Names(title: String(localized: "Images", comment: "Kind of items; also the name of a folder a plan groups them into"),
                      englishTitle: "Images",
                      noun: String(localized: "images", comment: "Kind of items, inside a sentence: “only images named “Screenshot””"),
                      symbol: "photo")
            case .movie:
                Names(title: String(localized: "Movies", comment: "Kind of items; also the name of a folder a plan groups them into"),
                      englishTitle: "Movies",
                      noun: String(localized: "movies", comment: "Kind of items, inside a sentence: “only movies named “Trip””"),
                      symbol: "film")
            case .audio:
                Names(title: String(localized: "Audio", comment: "Kind of items; also the name of a folder a plan groups them into"),
                      englishTitle: "Audio",
                      noun: String(localized: "audio", comment: "Kind of items, inside a sentence: “only audio named “Memo””"),
                      symbol: "waveform")
            case .archive:
                Names(title: String(localized: "Archives", comment: "Kind of items; also the name of a folder a plan groups them into"),
                      englishTitle: "Archives",
                      noun: String(localized: "archives", comment: "Kind of items, inside a sentence: “only archives named “Backup””"),
                      symbol: "archivebox")
            case .code:
                Names(title: String(localized: "Code", comment: "Kind of items: source code files; also a folder name"),
                      englishTitle: "Code",
                      noun: String(localized: "code", comment: "Kind of items (source code files), inside a sentence: “only code named “main””"),
                      symbol: "chevron.left.forwardslash.chevron.right")
            case .spreadsheet:
                Names(title: String(localized: "Spreadsheets", comment: "Kind of items; also the name of a folder a plan groups them into"),
                      englishTitle: "Spreadsheets",
                      noun: String(localized: "spreadsheets", comment: "Kind of items, inside a sentence: “only spreadsheets named “Budget””"),
                      symbol: "tablecells")
            case .presentation:
                Names(title: String(localized: "Presentations", comment: "Kind of items; also the name of a folder a plan groups them into"),
                      englishTitle: "Presentations",
                      noun: String(localized: "presentations", comment: "Kind of items, inside a sentence: “only presentations named “Q3””"),
                      symbol: "rectangle.on.rectangle.angled")
            case .application:
                Names(title: String(localized: "Apps", comment: "Kind of items; also the name of a folder a plan groups them into"),
                      englishTitle: "Apps",
                      noun: String(localized: "apps", comment: "Kind of items, inside a sentence: “only apps named “Notes””"),
                      symbol: "app.dashed")
            case .diskImage:
                Names(title: String(localized: "Disk images", comment: "Kind of items; also the name of a folder a plan groups them into"),
                      englishTitle: "Disk images",
                      noun: String(localized: "disk images", comment: "Kind of items, inside a sentence: “only disk images named “Installer””"),
                      symbol: "externaldrive")
            }
        }

        package func matches(type: UTType?, isDirectory: Bool, isPackage: Bool, extension ext: String) -> Bool {
            if self == .folder { return isDirectory && !isPackage }
            let type = type ?? UTType(filenameExtension: ext)
            func conforms(_ identifiers: [String]) -> Bool {
                guard let type else { return false }
                return identifiers.contains { UTType($0).map(type.conforms(to:)) ?? false }
            }
            switch self {
            case .book: return !isDirectory && IndexSearch.extensions(for: .book).contains(ext)
            case .comic: return !isDirectory && IndexSearch.extensions(for: .comic).contains(ext)
            case .folder: return false
            case .pdf: return ext == "pdf" || type?.conforms(to: .pdf) == true
            case .image: return type?.conforms(to: .image) == true
            case .movie: return type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true
            case .audio: return type?.conforms(to: .audio) == true
            case .archive: return (type?.conforms(to: .archive) == true && type?.conforms(to: .diskImage) != true) || (!isDirectory && BookFormat.comics.contains(ext))
            case .code:
                return type?.conforms(to: .sourceCode) == true || type?.conforms(to: .script) == true
                    || ["swift", "py", "js", "ts", "go", "rs", "rb", "java", "kt", "c", "h", "m", "cpp", "cs", "sh", "json", "yaml", "yml"].contains(ext)
            case .spreadsheet:
                return type?.conforms(to: .spreadsheet) == true || ["csv", "tsv", "xlsx", "xls", "numbers"].contains(ext)
            case .presentation: return type?.conforms(to: .presentation) == true || ["key", "pptx", "ppt"].contains(ext)
            case .text: return type?.conforms(to: .plainText) == true && type?.conforms(to: .sourceCode) != true
            case .application: return type?.conforms(to: .application) == true || ext == "app"
            case .diskImage: return type?.conforms(to: .diskImage) == true || ["dmg", "iso", "img", "pkg"].contains(ext)
            case .document:
                if isDirectory && !isPackage { return false }
                return Kind.pdf.matches(type: type, isDirectory: isDirectory, isPackage: isPackage, extension: ext)
                    || Kind.spreadsheet.matches(type: type, isDirectory: isDirectory, isPackage: isPackage, extension: ext)
                    || Kind.presentation.matches(type: type, isDirectory: isDirectory, isPackage: isPackage, extension: ext)
                    || type?.conforms(to: .rtf) == true || type?.conforms(to: .rtfd) == true || type?.conforms(to: .epub) == true
                    || (type?.conforms(to: .plainText) == true && type?.conforms(to: .sourceCode) != true)
                    || conforms(["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "com.apple.iwork.pages.sffpages",
                                 "com.apple.iwork.pages.pages", "org.oasis-open.opendocument.text"])
                    || ["docx", "doc", "pages", "odt", "md"].contains(ext) || IndexSearch.extensions(for: .book).contains(ext)
            }
        }
    }

    /// An item matches when it is any of `kinds` or has any of `extensions` (both empty: anything).
    package var kinds: Set<Kind> = []
    /// Lowercased, without the dot.
    package var extensions: Set<String> = []
    package var minSize: Int64?
    package var maxSize: Int64?
    /// Inclusive.
    package var modifiedAfter: Date?
    /// Exclusive.
    package var modifiedBefore: Date?
    /// Every fragment must appear in the name (case- and accent-insensitive).
    package var nameContains: [String] = []
    /// What the documents are about, for `SemanticIndex.search`.
    package var contentQuery: String?
    /// Words nothing else claimed (no model to place them). An item matches when its name contains at least one of them
    /// (plural-tolerant); a content-aware search can also run `keywords.joined(" ")` through `SemanticIndex`.
    package var keywords: [String] = []

    package var isEmpty: Bool { self == SearchFilter() }

    /// Matches metadata only (`contentQuery` needs the semantic index).
    package func matches(name: String, contentType: UTType?, isDirectory: Bool, isPackage: Bool = false, size: Int64?, modified: Date?) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if !kinds.isEmpty || !extensions.isEmpty {
            let kindMatch = kinds.contains { $0.matches(type: contentType, isDirectory: isDirectory, isPackage: isPackage, extension: ext) }
            if !kindMatch, !extensions.contains(ext) { return false }
        }
        if let minSize {
            guard let size, size >= minSize else { return false }
        }
        if let maxSize {
            guard let size, size <= maxSize else { return false }
        }
        if let modifiedAfter {
            guard let modified, modified >= modifiedAfter else { return false }
        }
        if let modifiedBefore {
            guard let modified, modified < modifiedBefore else { return false }
        }
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        for fragment in nameContains {
            if !folded.contains(fragment.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) { return false }
        }
        if !keywords.isEmpty, !keywords.contains(where: { keyword in
            folded.contains(Terms.stem(keyword.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)))
        }) { return false }
        return true
    }

    package func matches(_ entry: FileEntry) -> Bool {
        matches(name: entry.name, contentType: entry.contentType, isDirectory: entry.isDirectory, isPackage: entry.isPackage,
                size: entry.size, modified: entry.modified)
    }

    // MARK: - Display

    package struct Chip: Sendable, Hashable {
        package let symbol: String
        package let text: String
    }

    /// One token per constraint, for showing what was understood.
    package var chips: [Chip] {
        var chips: [Chip] = []
        for kind in Kind.allCases where kinds.contains(kind) { chips.append(Chip(symbol: kind.symbol, text: kind.title)) }
        for ext in extensions.sorted() { chips.append(Chip(symbol: "doc", text: "." + ext)) }
        switch (minSize, maxSize) {
        case let (min?, max?): chips.append(Chip(symbol: "scalemass", text: "\(Self.bytes(min))–\(Self.bytes(max))"))
        case let (min?, nil): chips.append(Chip(symbol: "scalemass", text: String(localized: "Over \(Self.bytes(min))", comment: "Search condition: bigger than a size")))
        case let (nil, max?): chips.append(Chip(symbol: "scalemass", text: String(localized: "Under \(Self.bytes(max))", comment: "Search condition: smaller than a size")))
        default: break
        }
        if let dates = dateDescription { chips.append(Chip(symbol: "calendar", text: dates)) }
        for fragment in nameContains { chips.append(Chip(symbol: "textformat", text: String(localized: "Name contains “\(fragment)”"))) }
        for keyword in keywords { chips.append(Chip(symbol: "character.textbox", text: "“\(keyword)”")) }
        if let contentQuery {
            chips.append(Chip(symbol: "text.magnifyingglass", text: String(localized: "About “\(contentQuery)”", comment: "Search condition: what documents are about")))
        }
        return chips
    }

    package var summary: String { chips.map(\.text).joined(separator: " · ") }

    package var dateDescription: String? {
        let day = Date.FormatStyle(date: .abbreviated, time: .omitted)
        switch (modifiedAfter, modifiedBefore) {
        case let (after?, before?):
            let last = before.addingTimeInterval(-1)
            return Calendar.current.isDate(after, inSameDayAs: last)
                ? String(localized: "Modified \(after.formatted(day))", comment: "Search condition: modified on a day")
                : String(localized: "Modified \(after.formatted(day)) – \(last.formatted(day))", comment: "Search condition: modified between two days")
        case let (after?, nil): return String(localized: "Modified since \(after.formatted(day))")
        case let (nil, before?): return String(localized: "Modified before \(before.formatted(day))")
        default: return nil
        }
    }

    private static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

nonisolated extension SearchFilter: CustomStringConvertible {
    package var description: String {
        var parts: [String] = []
        if !kinds.isEmpty { parts.append("kinds=\(kinds.map(\.rawValue).sorted())") }
        if !extensions.isEmpty { parts.append("ext=\(extensions.sorted())") }
        if let minSize { parts.append("minSize=\(Self.bytes(minSize))") }
        if let maxSize { parts.append("maxSize=\(Self.bytes(maxSize))") }
        let iso = Date.ISO8601FormatStyle(timeZone: .current).year().month().day().time(includingFractionalSeconds: false)
        if let modifiedAfter { parts.append("after=\(modifiedAfter.formatted(iso))") }
        if let modifiedBefore { parts.append("before=\(modifiedBefore.formatted(iso))") }
        if !nameContains.isEmpty { parts.append("name∋\(nameContains)") }
        if !keywords.isEmpty { parts.append("keywords=\(keywords)") }
        if let contentQuery { parts.append("content=“\(contentQuery)”") }
        return parts.isEmpty ? "(everything)" : parts.joined(separator: " ")
    }
}
