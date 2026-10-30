import AppKit
import UniformTypeIdentifiers

/// Finder icons, cached per file type for documents and per path for folders and packages (which can have their own).
package final class IconCache {
    package static let shared = IconCache()

    private var byType: [String: NSImage] = [:]
    private let byPath = NSCache<NSString, NSImage>()
    private var drawn: [String: NSImage] = [:]

    private init() {
        byPath.countLimit = 4000
    }

    /// The same image each time for a type, which views compare to tell an icon from a thumbnail.
    package func icon(forType type: UTType) -> NSImage {
        if let cached = byType[type.identifier] { return cached }
        let known = type.preferredFilenameExtension.flatMap { KnownDocument.kind(extension: $0, type: type) }
        let image = known.map(documentIcon) ?? NSWorkspace.shared.icon(for: type)
        byType[type.identifier] = image
        return image
    }

    private enum BadgeColor: Hashable {
        case green, orange, grey

        var color: NSColor {
            switch self {
            case .green: .systemGreen
            case .orange: .systemOrange
            case .grey: .systemGray
            }
        }
    }

    private var markedIcons: [String: NSImage] = [:]

    /// A box for a container, a stack of boxes for a Compose project. Filled and green while it runs, outline and grey
    /// while it's stopped, orange while it's paused or only partly running. The symbol is the whole icon: a badge on a
    /// folder shrinks to a dot at list size.
    package func markedIcon(_ symbol: String, _ mark: ContainerIconMark) -> NSImage {
        let badgeColor: BadgeColor = switch mark {
        case .running: .green
        case .changing: .orange
        case .stopped: .grey
        }
        let key = "\(symbol)|\(badgeColor)"
        if let cached = markedIcons[key] { return cached }
        let image = Self.drawing(symbol, weight: .medium, color: badgeColor.color, fraction: 0.82)
        markedIcons[key] = image
        return image
    }

    /// The page drawn for a kind of file macOS has no icon for: marked by what it holds, in no app's colors.
    package func documentIcon(_ kind: KnownDocument.Kind) -> NSImage {
        if let cached = drawn[kind.symbol] { return cached }
        let image = Self.drawing(kind.symbol, weight: .semibold, color: .systemIndigo, fraction: 0.38,
                                 on: icon(forType: .data))
        drawn[kind.symbol] = image
        return image
    }

    /// `symbol` filling `fraction` of the icon. AppKit runs an image's drawing on whichever thread draws it, so it
    /// belongs to no actor, and it draws only Core Graphics images made here, which nothing changes: an NSImage isn't
    /// safe to draw on two threads at once. Over a page, the symbol sits in its lower middle, clear of its folded
    /// corner.
    nonisolated private static func drawing(_ symbol: String, weight: NSFont.Weight, color: NSColor, fraction: CGFloat,
                                            on page: NSImage? = nil) -> NSImage {
        let side = NSSize(width: 256, height: 256)
        let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 180, weight: weight).applying(.init(paletteColors: [color])))
        let glyphSize = glyph?.size ?? .zero
        let largest = min(side.width / max(glyphSize.width, 1), side.height / max(glyphSize.height, 1)) * fraction
        let glyphImage = glyph.flatMap {
            bitmap($0, size: NSSize(width: glyphSize.width * largest, height: glyphSize.height * largest))
        }
        let pageImage = page.flatMap { bitmap($0, size: side) }
        return NSImage(size: side, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.interpolationQuality = .high
            if let pageImage { context.draw(pageImage, in: rect) }
            guard let glyphImage else { return pageImage != nil }
            let scale = min(rect.width / glyphSize.width, rect.height / glyphSize.height) * fraction
            let shown = CGSize(width: glyphSize.width * scale, height: glyphSize.height * scale)
            let bottom = pageImage == nil ? rect.midY - shown.height / 2 : rect.minY + rect.height * 0.2
            context.draw(glyphImage, in: CGRect(x: rect.midX - shown.width / 2, y: bottom, width: shown.width,
                                                height: shown.height))
            return true
        }
    }

    /// At twice its size in points, for Retina screens.
    nonisolated private static func bitmap(_ image: NSImage, size: NSSize) -> CGImage? {
        var rect = NSRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    package func icon(forPath path: String) -> NSImage {
        if let cached = byPath.object(forKey: path as NSString) { return cached }
        let image = currentIcon(forPath: path)
        byPath.setObject(image, forKey: path as NSString)
        return image
    }

    /// The icon the item at `path` has now, never one remembered: for a choice about it, such as whether to replace it.
    package func currentIcon(forPath path: String) -> NSImage {
        let type = { (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentTypeKey]))?.contentType }
        if let kind = KnownDocument.kind(extension: (path as NSString).pathExtension, type: type()),
           !Self.hasCustomIcon(path) {
            return documentIcon(kind)
        }
        return NSWorkspace.shared.icon(forFile: path)
    }

    /// An icon pasted onto the item in Finder, which `URLResourceKey.customIconKey` doesn't report: Finder's
    /// kHasCustomIcon flag, in the high byte of the Finder flags at offset 8 of its Finder info.
    private static func hasCustomIcon(_ path: String) -> Bool {
        var info = [UInt8](repeating: 0, count: 32)
        guard getxattr(path, "com.apple.FinderInfo", &info, info.count, 0, XATTR_NOFOLLOW) == info.count else {
            return false
        }
        return info[8] & 0x04 != 0
    }
}

/// Whether a container or a Compose stack is drawn as running, in between, or stopped.
package enum ContainerIconMark: Equatable {
    case running, changing, stopped

    /// A filled box while it runs or is changing; an outline box while it's stopped.
    package var containerSymbol: String { self == .stopped ? "shippingbox" : "shippingbox.fill" }
    /// A filled stack while any of it runs or is changing; an outline stack while all of it is stopped.
    package var stackSymbol: String { self == .stopped ? "square.stack.3d.up" : "square.stack.3d.up.fill" }
}
