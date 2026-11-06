import AppKit

package final class PDFPreviewView: WebPreviewView {
    private let url: URL
    private var document: PDFPreviewDocument?
    private let retryButton = NSButton(title: String(localized: "Try Again"), target: nil, action: nil)

    package init(url: URL, timeLimit: @escaping PreviewWebPage.TimeLimit = PreviewWebPage.usualTimeLimit) {
        self.url = url
        super.init(page: PreviewWebPage(timeLimit: timeLimit))
        page.translatesAutoresizingMaskIntoConstraints = false
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retry(_:))
        retryButton.isHidden = true
        contentView.addSubview(page)
        contentView.addSubview(retryButton)
        NSLayoutConstraint.activate(page.fillingConstraints(in: contentView) + [
            retryButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            retryButton.topAnchor.constraint(equalTo: contentView.centerYAnchor, constant: 32),
        ])
        open()
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { return nil }

    package override var isOpen: Bool { document != nil }

    package override func open() {
        guard !stopped else { return }
        page.clear()
        document = nil
        retryButton.isHidden = true
        let url = url
        load({ () async throws -> PDFPreviewDocument? in
            do { return try await PDFPreviewDocument.open(url) }
            catch PreviewError.unsupported { return nil }
        }, failed: { [weak self] message in
            self?.showFailure(message)
        }, apply: { [weak self] document in
            guard let self, !stopped else { return }
            guard let document else {
                if let fallback { fallback() } else { showFailure(String(localized: "No Preview Available")) }
                return
            }
            self.document = document
            showPage()
        })
    }

    package override func showPage() {
        guard !stopped, let document else { return }
        retryButton.isHidden = true
        page.show({ document.page() }, failed: { [weak self] _ in
            self?.showFailure(String(localized: "No Preview Available"))
        })
    }

    @objc private func retry(_ sender: Any?) { open() }

    private func showFailure(_ message: String) {
        guard !stopped else { return }
        page.showProblem(message)
        retryButton.isHidden = false
    }
}
