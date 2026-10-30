import AppKit

/// Owns one section; its pages page through the header and WebKit page its base owns.
package final class OneNotePreviewView: PagedPreviewView {
    package typealias Loader = @Sendable (PreviewArchiveSource) async throws -> OneNoteSectionFile
    package private(set) var section: OneNoteSectionFile?
    private let source: PreviewArchiveSource?
    private let loader: Loader

    package init(url: URL, loader: @escaping Loader = { try await OneNoteSectionFile.open($0) },
                 timeLimit: @escaping PreviewWebPage.TimeLimit = PreviewWebPage.usualTimeLimit) {
        source = try? PreviewArchiveSource(url)
        self.loader = loader
        super.init(name: url.deletingPathExtension().lastPathComponent, timeLimit: timeLimit)
        open()
    }

    package override var isOpen: Bool { section != nil }

    package override func open() {
        let source = source, loader = loader
        load({
            guard let source else { throw PreviewError.unsupported }
            return try await loader(source)
        }, apply: { [weak self] section in
            guard let self, !stopped else { return }
            self.section = section
            guard !section.pages.isEmpty else {
                // A section whose every page is damaged isn't an empty one.
                if section.damaged > 0 {
                    showMessage(symbol: "exclamationmark.triangle", String(localized: "This file couldn’t be read."))
                } else {
                    showMessage(symbol: "doc", String(localized: "This section has no pages."))
                }
                return
            }
            let entries = section.pages.map { page in
                // Nothing shows of a title of spaces and invisible marks.
                let blank = page.title.unicodeScalars.allSatisfy {
                    $0.properties.isWhitespace || $0.properties.isDefaultIgnorableCodePoint
                }
                let untitled = String(localized: "Untitled",
                                      comment: "OneNote preview: a page with no title, in its contents.")
                return PreviewContentsHeader.Entry(title: blank ? untitled : page.title, level: page.level)
            }
            header.show(title: "", subtitle: "", details: "", entries: entries)
            // Pages left out as damaged would otherwise be missed without a word.
            let missing = section.damaged > 0 ? [String(localized: "Some pages couldn’t be read.")] : []
            footer.show(["OneNote"] + missing, note: String(localized: "Scripts and online content are blocked."))
            showPage()
        })
    }

    package override func document(_ index: Int) -> (@Sendable () async throws -> PreviewWebPage.Document)? {
        guard let section, section.pages.indices.contains(index) else { return nil }
        let page = section.pages[index]
        return {
            let document = try await OneNotePageDocument(section: section, page: page)
            return PreviewWebPage.Document(url: document.url, read: { try await document.read($0) },
                                           limits: document.limits)
        }
    }

    package override func failure(_ error: Error?) -> String {
        switch error {
        // A page can't be read for every reason a section can't, but too large is the page, not the section.
        case let error as OneStoreError where error == .encrypted || error == .unsupportedVersion:
            if case .message(let text, _) = OneNoteSectionFile.shown(error) { text } else { Self.unshown }
        // The file was replaced, changed or removed: a section read again shows what's there now, if anything.
        case let error as POSIXError where error.code == .ESTALE:
            String(localized: "This section changed since it was opened. Select it again to see it as it is now.")
        default: Self.unshown
        }
    }

    private static var unshown: String { String(localized: "This page couldn’t be shown.") }
}
