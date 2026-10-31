import AppKit
import UniformTypeIdentifiers

package extension Notification.Name {
    /// Posted (object: the `IconCache`, userInfo `paths`: a `Set<String>`) when items' own icons have been read, ones
    /// other than their kind's, for the rows showing them to draw them.
    static let iconsLoaded = Notification.Name("StrataIconsLoaded")
}

/// Finder icons, cached per file type for documents and per path for folders and packages (which can have their own).
package final class IconCache {
    package static let shared = IconCache()

    private var byType: [String: NSImage] = [:]
    private let byPath = NSCache<NSString, NSImage>()
    private var drawn: [String: NSImage] = [:]

    private init() {
        byPath.countLimit = 4000
        reads = BatchedReads(read: Self.read) { [weak self] found in self?.keep(found) }
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

    /// The kind each icon being read shows meanwhile.
    private var shownKinds: [String: UTType] = [:]
    /// What each kind's icon looks like, small, to tell an item's own icon from its kind's.
    private var kindPixels: [String: [UInt8]] = [:]
    private var reads: BatchedReads<Found>!

    /// The item's icon as last read. One not read yet shows its kind's icon (a link's, a folder's, or what its name
    /// says) and is read away from the main thread with the others asked about meanwhile: reading one asks the disk,
    /// and LaunchServices, which on a server takes seconds. `.iconsLoaded` says when ones other than their kind's
    /// arrive.
    package func icon(forPath path: String, folder: Bool, link: Bool = false) -> NSImage {
        if let cached = byPath.object(forKey: path as NSString) { return cached }
        let kind = link ? .symbolicLink : Self.kind(ofPath: path, folder: folder)
        shownKinds[path] = kind
        reads.request(path)
        return icon(forType: kind)
    }

    package func loaded() async {
        await reads.settled()
    }

    /// What the name says, for an item whose own icon isn't known yet: a folder unless it's a package, such as an app.
    private static func kind(ofPath path: String, folder: Bool) -> UTType {
        let named = UTType(filenameExtension: (path as NSString).pathExtension)
        if folder { return named.flatMap { $0.conforms(to: .package) ? $0 : nil } ?? .folder }
        return named ?? .data
    }

    private func keep(_ found: [String: Found]) {
        var changed: Set<String> = []
        for (path, icon) in found {
            guard let kind = shownKinds.removeValue(forKey: path) else { continue }
            let shown = self.icon(forType: kind)
            let image = switch icon {
            case .known(let known): documentIcon(known)
            case .made(let made): made.pixels != nil && made.pixels == pixels(of: kind) ? shown : made.image
            }
            byPath.setObject(image, forKey: path as NSString)
            if image !== shown { changed.insert(path) }
        }
        // Only a change redraws: every list showing one redraws its rows, and rows drawn ask again.
        if !changed.isEmpty {
            NotificationCenter.default.post(name: .iconsLoaded, object: self, userInfo: ["paths": changed])
        }
    }

    private func pixels(of kind: UTType) -> [UInt8]? {
        if let known = kindPixels[kind.identifier] { return known }
        let made = Self.pixels(icon(forType: kind))
        kindPixels[kind.identifier] = made
        return made
    }

    nonisolated private enum Found: Sendable {
        case known(KnownDocument.Kind)
        case made(MadeElsewhere)
    }

    /// An icon made away from the main thread and handed to it, as Apple's NSImage restrictions allow ("one thread can
    /// create an NSImage object, draw to the image buffer, and pass it off to the main thread for drawing"): it's drawn
    /// once where it's made, then used only on the main thread.
    nonisolated private struct MadeElsewhere: @unchecked Sendable {
        let image: NSImage
        let pixels: [UInt8]?
    }

    nonisolated private static func read(_ paths: [String]) -> [String: Found] {
        var found: [String: Found] = [:]
        for path in paths {
            if let known = knownKind(path) {
                found[path] = .known(known)
            } else {
                let image = NSWorkspace.shared.icon(forFile: path)
                found[path] = .made(MadeElsewhere(image: image, pixels: pixels(image)))
            }
        }
        return found
    }

    /// The icon the item at `path` has now, never one remembered: for a choice about it, such as whether to replace it.
    /// Nil when the task asking is cancelled first: the read is left to finish on its own thread.
    package func currentIcon(forPath path: String) async -> NSImage? {
        await currentIcons(forPaths: [path])?[path]
    }

    /// The icons the items at `paths` have now, read together on one thread of their own; nil when cancelled first.
    package func currentIcons(forPaths paths: [String]) async -> [String: NSImage]? {
        guard let found = await OwnThread.runUnlessCancelled({ Self.current(paths) }) else { return nil }
        return found.mapValues { found in
            switch found {
            case .known(let known): documentIcon(known)
            case .made(let made): made.image
            }
        }
    }

    /// The icon several items have now together, as Finder draws them; nil when cancelled first.
    package func togetherIcon(forPaths paths: [String]) async -> NSImage? {
        await OwnThread.runUnlessCancelled { Self.together(paths) }??.image
    }

    nonisolated private static func current(_ paths: [String]) -> [String: Found] {
        var found: [String: Found] = [:]
        for path in paths {
            found[path] = knownKind(path).map(Found.known) ?? .made(MadeElsewhere(image: NSWorkspace.shared.icon(forFile: path), pixels: nil))
        }
        return found
    }

    nonisolated private static func together(_ paths: [String]) -> MadeElsewhere? {
        NSWorkspace.shared.icon(forFiles: paths).map { MadeElsewhere(image: $0, pixels: nil) }
    }

    /// A kind Strata draws a page for, unless the item has an icon of its own.
    nonisolated private static func knownKind(_ path: String) -> KnownDocument.Kind? {
        let type = { (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentTypeKey]))?.contentType }
        guard let kind = KnownDocument.kind(extension: (path as NSString).pathExtension, type: type()),
              !hasCustomIcon(path) else { return nil }
        return kind
    }

    /// The image at 32 pixels square, for telling icons apart.
    nonisolated private static func pixels(_ image: NSImage) -> [UInt8]? {
        let side = 32
        var rect = NSRect(x: 0, y: 0, width: side, height: side)
        guard let drawn = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data else { return nil }
        context.draw(drawn, in: CGRect(x: 0, y: 0, width: side, height: side))
        return Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: side * side * 4))
    }

    /// An icon pasted onto the item in Finder, which `URLResourceKey.customIconKey` doesn't report: Finder's
    /// kHasCustomIcon flag, in the high byte of the Finder flags at offset 8 of its Finder info.
    nonisolated private static func hasCustomIcon(_ path: String) -> Bool {
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
