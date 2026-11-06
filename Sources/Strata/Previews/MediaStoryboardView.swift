import AppKit
import StrataMediaProtocol

package final class MediaStoryboardView: NSView {
    private var images: [(NSImage, Double)] = []
    private var duration: Double = 0
    private var tracking: NSTrackingArea?
    package var onInspect: ((Double?) -> Void)?
    package var onSeek: ((Double) -> Void)?

    package func show(_ frames: MediaFrames?) {
        duration = frames?.duration ?? 0
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
            image.0.draw(in: NSRect(x: CGFloat(index) * width + 1, y: 0, width: max(0, width - 2), height: bounds.height),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private func time(_ event: NSEvent) -> Double? {
        let x = convert(event.locationInWindow, from: nil).x
        guard duration > 0, bounds.width.isFinite, bounds.width > 0, x.isFinite else { return nil }
        return min(duration, max(0, Double(x / bounds.width) * duration))
    }
    package override func mouseMoved(with event: NSEvent) { onInspect?(time(event)) }
    package override func mouseExited(with event: NSEvent) { onInspect?(nil) }
    package override func mouseDown(with event: NSEvent) { if let time = time(event) { onSeek?(time) } }
}
