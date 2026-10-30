import AppKit
import StrataSupport
import StrataTheme

/// A notebook's table of contents: its sections and section groups in OneNote's order, each section by its color.
package final class OneNoteContentsView: PreviewView {
    package let list = NSStackView()

    package init(url: URL) {
        super.init(frame: .zero)
        ThemeStyle.bind(self, to: .preview)
        let scroll = NSScrollView(), document = TopDown()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 7
        list.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        for (view, parent) in [(scroll, contentView), (list, document)] as [(NSView, NSView)] {
            view.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(view)
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                                         view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                                         view.topAnchor.constraint(equalTo: parent.topAnchor)])
        }
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.bottomAnchor.constraint(equalTo: list.bottomAnchor),
        ])
        load({ try await Self.read(url) }, apply: { [weak self] in self?.show($0) })
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    /// A file named so that isn't a table of contents goes to Quick Look, as one that isn't a regular file does.
    @concurrent private static func read(_ url: URL) async throws -> OneNoteContents {
        guard let source = try? PreviewArchiveSource(url) else { throw PreviewError.unsupported }
        do {
            return try await OneNoteContents.open(source)
        } catch OneStoreError.notOneNote {
            throw PreviewError.unsupported
        }
    }

    private func show(_ contents: OneNoteContents) {
        guard !contents.entries.isEmpty else {
            showMessage(symbol: "book.closed", String(localized: "This notebook lists no sections."))
            return
        }
        for entry in contents.entries { list.addArrangedSubview(row(entry)) }
        let sections = contents.entries.filter(\.isSection).count
        footer.show(["OneNote", String(localized: "\(sections) sections", comment: "plural")])
    }

    private func row(_ entry: OneNoteContents.Entry) -> NSView {
        let shown = entry.isSection ? (entry.name as NSString).deletingPathExtension : entry.name
        let label = NSTextField(labelWithString: DisplayText.oneLine(DisplayText.label(shown)))
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        let mark: NSView
        if entry.isSection {
            mark = Swatch(entry.color.map(Self.color))
        } else {
            let folder = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription:
                String(localized: "Section group", comment: "OneNote: a folder of sections in a notebook")) ?? NSImage())
            folder.contentTintColor = .secondaryLabelColor
            mark = folder
        }
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([mark.widthAnchor.constraint(equalToConstant: 14),
                                     mark.heightAnchor.constraint(equalToConstant: 14)])
        let row = NSStackView(views: [mark, label])
        row.spacing = 8
        return row
    }

    private static func color(_ stored: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(stored & 0xFF) / 255, green: CGFloat(stored >> 8 & 0xFF) / 255,
                blue: CGFloat(stored >> 16 & 0xFF) / 255, alpha: 1)
    }

    /// A section's color, or an outline for one with none.
    package final class Swatch: NSView {
        package let color: NSColor?

        init(_ color: NSColor?) {
            self.color = color
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        package override func draw(_ dirtyRect: NSRect) {
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            if let color {
                color.setFill()
                shape.fill()
            } else {
                ThemeStyle.border.setStroke()
                shape.stroke()
            }
        }
    }

    private final class TopDown: NSView {
        override var isFlipped: Bool { true }
    }
}
