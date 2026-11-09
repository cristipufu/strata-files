import AppKit
import Foundation
import StrataArchives
import StrataModel
import StrataSupport

nonisolated package struct DesignPreviewDocument: Sendable {
    package let image: CGImage
    package let summary: [String]
}

package final class DesignPreviewView: PreviewView {
    private let imageView = NSImageView()

    package init(url: URL) {
        super.init(frame: .zero)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
        load({ try await Self.loadDocument(url) }) { [weak self] doc in
            guard let self else { return }
            imageView.image = NSImage(cgImage: doc.image, size: NSSize(width: doc.image.width, height: doc.image.height))
            footer.show(doc.summary)
        }
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    @concurrent private static func loadDocument(_ url: URL) async throws -> DesignPreviewDocument {
        try Task.checkCancellation()
        let ext = url.pathExtension.lowercased()
        let source = try FileReadSource(url)
        let records = try await ArchiveReader.read(source)
        let data = try await ArchiveMetadata.designPreviewImage(source, records: records, ext: ext)
        let picture = try PreviewPicture(data)
        let cgImage = try picture.thumbnail(pixels: 2048)

        let formatName = switch ext {
        case "sketch": "Sketch"
        case "procreate": "Procreate"
        case "kra": "Krita"
        case "ora": "OpenRaster"
        default: ext.uppercased()
        }

        var summary = [formatName, "\(picture.width) × \(picture.height)"]
        if let meta = await ArchiveMetadata.designStructureMetadata(source, records: records, ext: ext) {
            if let pages = meta.pageCount, pages > 0 {
                summary.append(String(localized: "\(pages) pages", comment: "plural"))
            }
            if let artboards = meta.artboardCount, artboards > 0 {
                summary.append(String(localized: "\(artboards) artboards", comment: "plural"))
            }
        }
        return DesignPreviewDocument(image: cgImage, summary: summary)
    }
}
