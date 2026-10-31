import Foundation

/// Window sizes are content sizes. Keep the same comfortable shape on another display without going offscreen.
enum PreviewLayout {
    static let defaultSize = NSSize(width: 1000, height: 640)
    static let minimumSize = NSSize(width: 720, height: 420)
    static let browserMinimum: CGFloat = 280
    static let detailMinimum: CGFloat = 320
    static let defaultBrowserFraction: CGFloat = 0.4

    static func validSize(_ size: NSSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    static func contentSize(_ saved: NSSize?, available: NSSize) -> NSSize {
        let requested = saved.flatMap { validSize($0) ? $0 : nil } ?? defaultSize
        let available = validSize(available) ? available : defaultSize
        return NSSize(width: min(max(requested.width, minimumSize.width), available.width),
                      height: min(max(requested.height, minimumSize.height), available.height))
    }

    static func browserWidth(in width: CGFloat, fraction: CGFloat) -> CGFloat {
        min(max(width * fraction, browserMinimum), max(browserMinimum, width - detailMinimum))
    }

    struct Columns {
        let name: CGFloat
        let size: CGFloat
        let kind: CGFloat?
        let date: CGFloat?
    }

    /// Name and Size stay visible; extra metadata appears only when Name can keep a useful width.
    static func columns(width: CGFloat, spacing: CGFloat, size: CGFloat, kind: CGFloat, date: CGFloat) -> Columns {
        let dateVisible = width >= 220 + size + date + spacing * 4
        let kindVisible = dateVisible && width >= 260 + size + date + kind + spacing * 5
        let count = 2 + (dateVisible ? 1 : 0) + (kindVisible ? 1 : 0)
        let metadata = size + (dateVisible ? date : 0) + (kindVisible ? kind : 0)
        return Columns(name: max(120, width - metadata - spacing * CGFloat(count + 1)), size: size,
                       kind: kindVisible ? kind : nil, date: dateVisible ? date : nil)
    }
}

