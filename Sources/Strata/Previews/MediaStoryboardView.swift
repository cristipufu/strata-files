import AppKit
import StrataMediaProtocol
import StrataTheme

package final class MediaStoryboardView: MediaTimelineView {
    private var images: [(NSImage, Double)] = []
    private var tracking: NSTrackingArea?
    package var onInspect: ((Double?) -> Void)?

    package func show(_ frames: MediaFrames?) {
        duration = frames?.duration ?? 0
        if frames == nil { playhead = 0 }
        images = frames?.frames.compactMap { frame in Self.image(frame).map { ($0, frame.actual) } } ?? []
        needsDisplay = true
    }

    package static func image(_ frame: MediaFrame) -> NSImage? {
        guard let provider = CGDataProvider(data: frame.rgba as CFData),
              let cg = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: frame.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: frame.width, height: frame.height))
    }

    package override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }

    package override func draw(_ dirtyRect: NSRect) {
        guard !images.isEmpty, bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return }
        let width = bounds.width / Double(images.count)
        for (index, image) in images.enumerated() {
            guard image.0.size.width > 0, image.0.size.height > 0 else { continue }
            let cell = NSRect(x: CGFloat(index) * width + 1, y: 0, width: max(0, width - 2), height: bounds.height)
            let scale = min(cell.width / image.0.size.width, cell.height / image.0.size.height)
            guard scale.isFinite, scale > 0 else { continue }
            let size = NSSize(width: image.0.size.width * scale, height: image.0.size.height * scale)
            let rect = NSRect(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2, width: size.width, height: size.height)
            image.0.draw(in: rect,
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        ThemeStyle.accent.setFill()
        fillPlayhead(width: 2, includeZero: false)
    }

    package override func mouseMoved(with event: NSEvent) { onInspect?(time(for: event)) }
    package override func mouseExited(with event: NSEvent) { onInspect?(nil) }
    package override func mouseDown(with event: NSEvent) {
        onInspect?(nil)
        super.mouseDown(with: event)
    }
    package override func mouseDragged(with event: NSEvent) {
        onInspect?(nil)
        super.mouseDragged(with: event)
    }
    package override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if !bounds.contains(convert(event.locationInWindow, from: nil)) { onInspect?(nil) }
    }
}
