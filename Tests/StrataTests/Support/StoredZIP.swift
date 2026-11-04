import Foundation

nonisolated enum StoredZIP {
    static func make(_ entries: [(String, Data)]) -> Data {
        var output = Data(), central = Data()
        func word(_ value: Int, _ bytes: Int) -> Data { Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        for (name, data) in entries {
            let path = Data(name.utf8), offset = output.count
            var crc: UInt32 = .max
            for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) } }
            crc = ~crc
            output += word(0x04034b50, 4) + word(20, 2) + word(0x800, 2) + Data(repeating: 0, count: 6)
            output += word(Int(crc), 4) + word(data.count, 4) + word(data.count, 4) + word(path.count, 2) + word(0, 2) + path + data
            central += word(0x02014b50, 4) + word(20, 2) + word(20, 2) + word(0x800, 2) + Data(repeating: 0, count: 6)
            central += word(Int(crc), 4) + word(data.count, 4) + word(data.count, 4) + word(path.count, 2)
            central += Data(repeating: 0, count: 12) + word(offset, 4) + path
        }
        let offset = output.count
        output += central
        output += word(0x06054b50, 4) + Data(repeating: 0, count: 4) + word(entries.count, 2) + word(entries.count, 2)
        output += word(central.count, 4) + word(offset, 4) + word(0, 2)
        return output
    }
}
