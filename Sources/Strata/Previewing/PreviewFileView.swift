import AppKit
import StrataPreviews
import UniformTypeIdentifiers

/// The same native and rich file renderers used by Get Info, owned by this preview window's lifetime.
@MainActor final class PreviewFileView: NSView {
    private let thumbnails: FileThumbnails
    private let copies: CopyProviders
    private let native = QuickLookPreviewView(frame: .zero, style: .normal)
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let sizeSummary = NSTextField(labelWithString: "")
    private let summary = NSStackView()
    private var rich: NSView?
    private(set) var shownURL: URL?
    private var generation = 0
    private var isClosed = false

    init(thumbnails: FileThumbnails, copies: CopyProviders) {
        self.thumbnails = thumbnails
        self.copies = copies
        super.init(frame: .zero)
        ThemeStyle.bind(self, to: .preview)
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        sizeSummary.font = .systemFont(ofSize: 12)
        sizeSummary.textColor = .secondaryLabelColor
        sizeSummary.lineBreakMode = .byTruncatingTail
        sizeSummary.isHidden = true
        summary.orientation = .vertical
        summary.alignment = .centerX
        summary.spacing = 10
        for child in [icon, title, detail, sizeSummary] { summary.addArrangedSubview(child) }
        summary.translatesAutoresizingMaskIntoConstraints = false
        native.translatesAutoresizingMaskIntoConstraints = false
        addSubview(native)
        addSubview(summary)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            summary.centerXAnchor.constraint(equalTo: centerXAnchor),
            summary.centerYAnchor.constraint(equalTo: centerYAnchor),
            summary.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            native.leadingAnchor.constraint(equalTo: leadingAnchor),
            native.trailingAnchor.constraint(equalTo: trailingAnchor),
            native.topAnchor.constraint(equalTo: topAnchor),
            native.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: PreviewItem?, root: FileEntry?, materialized: URL? = nil) {
        guard !isClosed else { return }
        generation += 1
        let generation = generation
        rich?.removeFromSuperview()
        rich = nil
        native.clear()
        native.isHidden = true
        summary.isHidden = false
        shownURL = nil
        setSizeSummary(nil)
        guard let root else { title.stringValue = ""; detail.stringValue = ""; icon.image = nil; return }
        let entry = materialized.flatMap(FileEntry.init(url:)) ?? item?.entry ?? (item == nil ? root : nil)
        title.stringValue = item?.name ?? root.displayName
        detail.stringValue = item?.kind ?? root.kind
        if let entry {
            icon.image = thumbnails.icon(for: entry)
        } else {
            let type: UTType = item?.isDirectory == true ? .folder
                : UTType(filenameExtension: ((item?.name ?? "") as NSString).pathExtension) ?? .data
            icon.image = IconCache.shared.icon(forType: type)
        }
        guard let entry, !entry.isDirectory, !entry.isSymlink, !copies.isPlaceholder(entry.url), Self.isRegularFile(entry.url) else { return }
        // The session already lists a root archive. Its side pane stays a summary until a member is selected.
        guard item != nil || ArchiveKind(fileName: entry.name) == nil else { return }
        let url = entry.url
        shownURL = url
        if let rich = RichPreview.makeView(for: url, contentType: entry.contentType, fallback: { [weak self] in
            guard let self, self.generation == generation, shownURL == url else { return }
            self.rich?.removeFromSuperview()
            self.rich = nil
            showNative(url)
        }) {
            self.rich = rich
            rich.translatesAutoresizingMaskIntoConstraints = false
            addSubview(rich)
            NSLayoutConstraint.activate([
                rich.leadingAnchor.constraint(equalTo: leadingAnchor), rich.trailingAnchor.constraint(equalTo: trailingAnchor),
                rich.topAnchor.constraint(equalTo: topAnchor), rich.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            summary.isHidden = true
        } else {
            showNative(url)
        }
    }

    func setSizeSummary(_ text: String?) {
        guard !isClosed else { return }
        sizeSummary.stringValue = text ?? ""
        sizeSummary.isHidden = text == nil
    }

    func close() {
        isClosed = true
        generation += 1
        shownURL = nil
        rich?.removeFromSuperview()
        rich = nil
        native.close()
    }

    private func showNative(_ url: URL) {
        guard Self.isRegularFile(url), native.show(url) else {
            shownURL = nil
            summary.isHidden = false
            return
        }
        native.isHidden = false
        summary.isHidden = true
    }

    nonisolated static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return url.isFileURL && lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }
}
