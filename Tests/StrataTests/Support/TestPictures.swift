import Foundation

enum TestPictures {
    /// A PNG of `side` by `side` blank pixels in a few KB, its rows compressed as ImageIO expects them to be.
    static func blank(_ side: Int) throws -> Data {
        func bigEndian(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) } }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let typed = Array(type.utf8) + body
            var crc: UInt32 = .max
            for byte in typed {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) }
            }
            return bigEndian(UInt32(body.count)) + typed + bigEndian(~crc)
        }
        let rows = Data(count: side * (1 + side / 8))
        let deflated = try (rows as NSData).compressed(using: .zlib) as Data
        let stream = [0x78, 0x9C] + Array(deflated) + bigEndian(UInt32(rows.count % 65521) << 16 | 1)
        let header = bigEndian(UInt32(side)) + bigEndian(UInt32(side)) + [1, 0, 0, 0, 0]
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", header) + chunk("IDAT", stream)
                    + chunk("IEND", []))
    }
}
