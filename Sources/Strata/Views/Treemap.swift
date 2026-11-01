import Foundation
import UniformTypeIdentifiers

/// One child of the folder shown in the disk-usage map.
nonisolated struct TreemapItem: Sendable, Hashable {
    let url: URL
    let name: String
    /// Nil while a folder is still being measured; such items aren't drawn until their size arrives.
    var bytes: Int64?
    let isFolder: Bool
    let contentType: UTType?

    init(url: URL, name: String, bytes: Int64?, isFolder: Bool, contentType: UTType? = nil) {
        self.url = url
        self.name = name
        self.bytes = bytes
        self.isFolder = isFolder
        self.contentType = contentType
    }

    init(entry: FileEntry, bytes: Int64?) {
        self.init(url: entry.url, name: entry.displayName, bytes: bytes ?? (entry.isDirectory ? nil : entry.size ?? 0),
                  isFolder: entry.isFolder, contentType: entry.contentType)
    }

    var group: FileKindGroup { FileKindGroup.of(isFolder: isFolder, type: contentType) }
}

/// A laid-out tile: one item, or the "Other" tile holding everything too small to draw.
nonisolated struct TreemapTile: Sendable {
    static let otherKey = "\u{0}other"

    let key: String
    let item: TreemapItem?
    let bytes: Int64
    /// Items folded into "Other".
    let otherCount: Int
    var frame: CGRect

    var isOther: Bool { item == nil }
}

nonisolated enum Treemap {
    /// Tiles for `items` in `rect`: largest first, tiny ones grouped into "Other" so no tile is smaller than
    /// `minArea` points² (and there are at most `maxTiles`).
    static func tiles(_ items: [TreemapItem], in rect: CGRect, minArea: CGFloat = 34 * 26, maxTiles: Int = 300) -> [TreemapTile] {
        let measured = items.filter { ($0.bytes ?? 0) > 0 }.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        let total = measured.map { $0.bytes ?? 0 }.saturatingSum
        guard total > 0, rect.width.isFinite, rect.height.isFinite, rect.width > 4, rect.height > 4 else { return [] }
        let area = Double(rect.width * rect.height)
        var kept: [TreemapItem] = []
        var otherBytes: Int64 = 0
        var otherCount = 0
        for item in measured {
            let itemBytes = item.bytes ?? 0
            let share = Double(itemBytes) / Double(total) * area
            if kept.count < maxTiles - 1, share >= Double(minArea) {
                kept.append(item)
            } else {
                otherBytes = [otherBytes, itemBytes].saturatingSum
                otherCount += 1
            }
        }
        // A lone small item isn't worth an "Other" tile of one. Kept items are a prefix of `measured`.
        if otherCount == 1, kept.count < measured.count {
            kept.append(measured[kept.count])
            otherCount = 0
            otherBytes = 0
        }
        var tiles = kept.map { TreemapTile(key: $0.url.fileViewKey, item: $0, bytes: $0.bytes ?? 0, otherCount: 0, frame: .zero) }
        if otherCount > 0 {
            let other = TreemapTile(key: TreemapTile.otherKey, item: nil, bytes: otherBytes, otherCount: otherCount, frame: .zero)
            let index = tiles.firstIndex(where: { $0.bytes < otherBytes }) ?? tiles.count
            tiles.insert(other, at: index)
        }
        let frames = squarify(tiles.map { Double($0.bytes) }, in: rect)
        for i in tiles.indices { tiles[i].frame = frames[i] }
        return tiles
    }

    /// Squarified treemap (Bruls, Huizing, van Wijk): `values` must be positive and sorted descending. Returns one
    /// rect per value, tiling `rect` exactly, in a top-left-origin (flipped) coordinate space.
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        guard !values.isEmpty else { return [] }
        guard let areas = areas(values, filling: rect) else { return values.map { _ in .zero } }
        var result = [CGRect](repeating: .zero, count: values.count)
        var remaining = rect
        var i = 0
        while i < areas.count {
            guard remaining.width > 0, remaining.height > 0 else {
                let edge = CGRect(x: remaining.minX, y: remaining.minY, width: 0, height: 0)
                for k in i..<areas.count { result[k] = edge }
                break
            }
            let (j, sum) = rowEnd(from: i, areas, side: Double(min(remaining.width, remaining.height)))
            remaining = layOutRow(i..<j, sum: sum, areas, isLast: j >= areas.count, in: remaining, into: &result)
            i = j
        }
        return result
    }

    /// Each value's area once they fill `rect`, or nil when they can't (an empty or endless rect, a value that isn't
    /// positive and finite, or a total too large).
    private static func areas(_ values: [Double], filling rect: CGRect) -> [Double]? {
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0,
              values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let total = values.reduce(0, +)
        guard total > 0, total.isFinite else { return nil }
        let scale = Double(rect.width * rect.height) / total
        guard scale.isFinite, scale > 0 else { return nil }
        return values.map { $0 * scale }
    }

    /// Where the row starting at `i` ends, and its area: it takes the next area while that doesn't make its worst
    /// aspect ratio along `side` worse.
    private static func rowEnd(from i: Int, _ areas: [Double], side: Double) -> (end: Int, sum: Double) {
        func worst(_ sum: Double, _ minArea: Double, _ maxArea: Double) -> Double {
            let s2 = sum * sum, w2 = side * side
            return max(w2 * maxArea / s2, s2 / (w2 * minArea))
        }
        var sum = areas[i], lo = areas[i], hi = areas[i]
        var current = worst(sum, lo, hi)
        var j = i + 1
        while j < areas.count {
            let a = areas[j]
            let candidate = worst(sum + a, min(lo, a), max(hi, a))
            if candidate > current { break }
            sum += a
            lo = min(lo, a)
            hi = max(hi, a)
            current = candidate
            j += 1
        }
        return (j, sum)
    }

    /// Lays the row out along the longer side's edge of `remaining` (the last row fills it) and returns what's left.
    private static func layOutRow(_ row: Range<Int>, sum: Double, _ areas: [Double], isLast: Bool, in remaining: CGRect,
                                  into result: inout [CGRect]) -> CGRect {
        if remaining.width >= remaining.height {
            // A column along the left edge.
            let width = isLast ? Double(remaining.width) : min(Double(remaining.width), sum / Double(remaining.height))
            var y = Double(remaining.minY)
            for k in row {
                let height = k == row.upperBound - 1 ? max(0, Double(remaining.maxY) - y) : (width > 0 ? min(max(0, Double(remaining.maxY) - y), areas[k] / width) : 0)
                result[k] = CGRect(x: Double(remaining.minX), y: y, width: width, height: height)
                y += height
            }
            return CGRect(x: remaining.minX + CGFloat(width), y: remaining.minY,
                          width: max(remaining.width - CGFloat(width), 0), height: remaining.height)
        }
        // A row along the top edge.
        let height = isLast ? Double(remaining.height) : min(Double(remaining.height), sum / Double(remaining.width))
        var x = Double(remaining.minX)
        for k in row {
            let width = k == row.upperBound - 1 ? max(0, Double(remaining.maxX) - x) : (height > 0 ? min(max(0, Double(remaining.maxX) - x), areas[k] / height) : 0)
            result[k] = CGRect(x: x, y: Double(remaining.minY), width: width, height: height)
            x += width
        }
        return CGRect(x: remaining.minX, y: remaining.minY + CGFloat(height),
                      width: remaining.width, height: max(remaining.height - CGFloat(height), 0))
    }
}
