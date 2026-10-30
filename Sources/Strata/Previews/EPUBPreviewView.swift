import AppKit
import StrataTheme

/// Owns one book; its chapters page through the header and WebKit page its base owns.
package final class EPUBPreviewView: PagedPreviewView {
    package typealias Loader = @Sendable (PreviewArchiveSource) async throws -> EPUBBook
    package private(set) var book: EPUBBook?
    private let source: PreviewArchiveSource?
    private let loader: Loader

    package init(url: URL, loader: @escaping Loader = { try await EPUBBook.open($0) },
                 timeLimit: @escaping PreviewWebPage.TimeLimit = PreviewWebPage.usualTimeLimit) {
        source = try? PreviewArchiveSource(url)
        self.loader = loader
        super.init(name: url.deletingPathExtension().lastPathComponent, timeLimit: timeLimit)
        open()
    }

    package override var isOpen: Bool { book != nil }

    package override func open() {
        let source = source, loader = loader
        load({
            guard let source else { throw PreviewError.unsupported }
            return try await loader(source)
        }, apply: { [weak self] book in
            guard let self, !stopped else { return }
            self.book = book
            header.show(book)
            footer.show(["EPUB"], note: String(localized: "Scripts and online content are blocked."))
            entryChanged()
        })
    }

    package override func document(_ index: Int) -> (@Sendable () async throws -> PreviewWebPage.Document)? {
        guard let book else { return nil }
        return {
            let document = try EPUBChapterDocument(book: book, chapter: index)
            _ = try await document.read(document.url)
            return PreviewWebPage.Document(url: document.url, read: { try await document.read($0) })
        }
    }
}

extension PreviewContentsHeader {
    package func show(_ book: EPUBBook) {
        let details = [book.title, book.authors, book.publisher, book.language].filter { !$0.isEmpty }
        show(title: book.title, subtitle: book.authors, details: details.joined(separator: "\n"),
             entries: book.chapters.map { Entry(title: $0.title) })
    }
}
