import AppKit
import StrataTheme

/// A preview that pages through a file one offline WebKit document at a time, under a header for its contents.
package class PagedPreviewView: WebPreviewView {
    package let header: PreviewContentsHeader

    package init(name: String, timeLimit: @escaping PreviewWebPage.TimeLimit) {
        header = PreviewContentsHeader(name: name)
        super.init(page: PreviewWebPage(timeLimit: timeLimit))
        let separator = NSBox(); separator.boxType = .separator
        for item in [header, separator, page] {
            item.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(item)
            NSLayoutConstraint.activate([item.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                                         item.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)])
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            page.topAnchor.constraint(equalTo: separator.bottomAnchor),
            page.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        header.onSelect = { [weak self] _ in self?.showPage() }
    }

    /// Nil while the file isn't read.
    package func document(_ index: Int) -> (@Sendable () async throws -> PreviewWebPage.Document)? { nil }
    /// `error` is nil when WebKit couldn't show the document, in time or at all.
    package func failure(_ error: Error?) -> String { String(localized: "No Preview Available") }

    @objc package func back() {
        guard !stopped, header.selected > 0 else { return }
        header.select(header.selected - 1); showPage()
    }
    @objc package func forward() {
        guard !stopped, header.selected + 1 < header.contents.numberOfItems else { return }
        header.select(header.selected + 1); showPage()
    }
    package override func showPage() {
        guard !stopped, let prepare = document(header.selected) else {
            page.clear()
            return
        }
        page.show(prepare, failed: { [weak self] error in
            guard let self else { return }
            page.showProblem(failure(error))
        })
    }
}
