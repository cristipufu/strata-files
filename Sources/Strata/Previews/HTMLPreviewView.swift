import AppKit
import StrataTheme
import StrataModel

/// Static HTML with the existing source reader one click away. Document colors stay with the document.
package final class HTMLPreviewView: WebPreviewView {
    package let modeControl = NSSegmentedControl(labels: [String(localized: "Preview"), String(localized: "Source")], trackingMode: .selectOne, target: nil, action: nil)
    private let browserButton = NSButton(title: String(localized: "Open in Browser"), target: nil, action: nil)
    private let host = NSView()
    private let url: URL
    private let selected: ChosenFile?
    private let openFile: (URL) -> Void
    private var source: CodePreviewView?
    private var document: HTMLPreviewDocument?

    /// `timeLimit` ends when WebKit has had long enough to start showing the page: its source is shown instead.
    package init(url: URL, openFile: ((URL) -> Void)? = nil,
                 openLink: @escaping (URL) -> Void = PreviewWebPage.usualOpenLink,
                 timeLimit: @escaping PreviewWebPage.TimeLimit = PreviewWebPage.usualTimeLimit) {
        self.url = url
        selected = try? ChosenFile(url)
        self.openFile = openFile ?? Self.openInBrowser
        super.init(page: PreviewWebPage(timeLimit: timeLimit, openLink: openLink))
        ThemeStyle.bind(host, to: .preview)
        let bar = NSStackView(views: [modeControl, NSView(), browserButton])
        bar.orientation = .horizontal
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        bar.spacing = 8
        ThemeStyle.bind(bar, to: .preview)
        modeControl.controlSize = .small
        modeControl.selectedSegment = 0
        modeControl.target = self; modeControl.action = #selector(modeChanged(_:))
        browserButton.controlSize = .small
        browserButton.bezelStyle = .rounded
        browserButton.target = self; browserButton.action = #selector(openBrowser(_:))
        let separator = NSBox(); separator.boxType = .separator
        for view in [bar, separator, host] { view.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(view) }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bar.topAnchor.constraint(equalTo: contentView.topAnchor),
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separator.topAnchor.constraint(equalTo: bar.bottomAnchor),
            host.topAnchor.constraint(equalTo: separator.bottomAnchor), host.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), host.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        attach(page)
        footer.show(["HTML"], note: String(localized: "Scripts and online content are blocked."))
        open()
    }

    private func attach(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor), view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor), view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    package override var isOpen: Bool { document != nil }

    /// Reads the document while Preview is chosen, for every WebKit lifetime after until one can't show it; one that
    /// can't be read shows its source.
    package override func open() {
        guard modeControl.selectedSegment == 0 else { return }
        let url = url, selected = selected
        load({ () -> HTMLPreviewDocument? in
            guard let selected else { return nil }
            return try? await HTMLPreviewDocument.open(url, chosen: selected)
        }, apply: { [weak self] document in
            guard let self else { return }
            self.document = document
            if document == nil { showSourceInstead() } else { showPage() }
        })
    }

    package override func showPage() {
        guard !stopped, modeControl.selectedSegment == 0, page.webView == nil, page.task == nil,
              let document else { return }
        page.show({
            try await document.verify()
            return PreviewWebPage.Document(url: document.url, read: { try await document.read($0) })
        }, failed: { [weak self] _ in self?.previewFailed() })
    }

    /// A document that couldn't be shown, perhaps changed since it was read, is read again: its source now, and its page
    /// when Preview is chosen next rather than again and again while it keeps failing. A page kept for coming back to
    /// Preview that fails meanwhile shows again then, without a word over the source shown.
    private func previewFailed() {
        document = nil
        if modeControl.selectedSegment == 0 { showSourceInstead() }
    }

    /// Read again, since the file may have changed since Source last showed it.
    private func showSourceInstead() {
        source?.removeFromSuperview(); source = nil
        showSource(unavailable: true)
    }

    @objc package func modeChanged(_ sender: NSSegmentedControl) {
        guard !stopped else { return }
        guard sender.selectedSegment == 0 else {
            showSource(unavailable: false)
            return
        }
        source?.isHidden = true
        page.isHidden = false
        footer.show(["HTML"], note: String(localized: "Scripts and online content are blocked."))
        if isOpen { showPage() } else if !isLoading { open() }
    }

    /// A page WebKit has started showing stays, hidden, for coming back to Preview; one still starting stops.
    private func showSource(unavailable: Bool) {
        guard !stopped else { return }
        modeControl.selectedSegment = 1
        if !page.isShowing { cancelLoad(); page.clear() }
        page.isHidden = true
        if source == nil {
            let selected = selected
            let view = CodePreviewView(source: {
                guard let selected else { throw POSIXError(.ESTALE) }
                return try await HTMLPreviewDocument.source(selected)
            }, language: Languages.html)
            source = view; attach(view)
        }
        source?.isHidden = false
        footer.show(["HTML"], note: unavailable ? String(localized: "Preview unavailable. Showing source.") : nil)
        if !unavailable { footer.collapse(true) }
    }

    @objc package func openBrowser(_ sender: Any?) {
        guard !stopped, let selected,
              (try? selected.withParent { _, _, info in info.st_mode & S_IFMT == S_IFREG }) == true else { return }
        openFile(url)
    }

    private static func openInBrowser(_ url: URL) {
        guard let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.invalid")!) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
    }
}
