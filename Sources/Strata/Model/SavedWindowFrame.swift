import Foundation

package nonisolated struct SavedWindowFrame: Codable, Equatable, Sendable {
    package static let byteLimit = 1024
    package let rectangle: CGRect

    package init?(_ rectangle: CGRect) {
        guard rectangle.origin.x.isFinite, rectangle.origin.y.isFinite,
              rectangle.width.isFinite, rectangle.height.isFinite,
              rectangle.size.width > 0, rectangle.size.height > 0 else { return nil }
        self.rectangle = rectangle
    }

    package init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        guard let frame = Self(try value.decode(CGRect.self)) else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid window frame")
        }
        self = frame
    }

    package func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rectangle)
    }

    package static func decode(_ data: Data) -> Self? {
        guard data.count <= byteLimit else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    package func fitting(in available: CGRect) -> CGRect {
        let width = min(rectangle.width, available.width)
        let height = min(rectangle.height, available.height)
        return CGRect(x: max(available.minX, min(rectangle.origin.x, available.maxX - width)),
                      y: max(available.minY, min(rectangle.origin.y, available.maxY - height)),
                      width: width, height: height)
    }
}
