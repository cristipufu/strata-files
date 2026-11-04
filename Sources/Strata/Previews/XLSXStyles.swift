import Foundation

nonisolated struct XLSXStyles: Sendable {
    private enum Kind: Sendable { case number, date, time, dateTime }
    private static let formatLimit = 1000
    private static let styleLimit = 4000
    private static let formatByteLimit = 4096
    private let kinds: [Kind]
    private let date1904: Bool
    private let epoch: Date
    private let date = XLSXStyles.formatter("yyyy-MM-dd")
    private let time = XLSXStyles.formatter("HH:mm:ss")
    private let dateTime = XLSXStyles.formatter("yyyy-MM-dd HH:mm:ss")

    init(_ data: Data? = nil, date1904: Bool = false) throws {
        self.date1904 = date1904
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = date1904 ? DateComponents(year: 1904, month: 1, day: 1) : DateComponents(year: 1899, month: 12, day: 30)
        guard let epoch = calendar.date(from: components) else { throw PreviewError.unsupported }
        self.epoch = epoch
        guard let data else { kinds = [.number]; return }
        try XLSXXML.validate(data, limit: 512 << 10)
        let root = try BookXML.parse(data)
        guard root.name == "styleSheet" else { throw PreviewError.unsupported }
        var formats: [Int: String] = [:]
        for item in root.children.first(where: { $0.name == "numFmts" })?.children ?? [] where item.name == "numFmt" {
            guard formats.count < Self.formatLimit, let raw = item.attributes["numFmtId"], let id = Int(raw), id >= 0,
                  let code = item.attributes["formatCode"], code.utf8.count <= Self.formatByteLimit, formats[id] == nil else { throw XLSXXML.limitError }
            formats[id] = code
        }
        let cells = root.children.first { $0.name == "cellXfs" }?.children.filter { $0.name == "xf" } ?? []
        guard cells.count <= Self.styleLimit else { throw XLSXXML.limitError }
        kinds = cells.isEmpty ? [.number] : try cells.map { cell in
            guard let id = Int(cell.attributes["numFmtId"] ?? "0"), id >= 0 else { throw PreviewError.unsupported }
            if let code = formats[id] { return Self.kind(code) }
            if (14...17).contains(id) { return .date }
            if (18...21).contains(id) || (45...47).contains(id) { return .time }
            return id == 22 ? .dateTime : .number
        }
    }

    func formatted(_ raw: String, style: Int) throws -> String {
        guard kinds.indices.contains(style) else { throw PreviewError.unsupported }
        let kind = kinds[style]
        guard kind != .number, let serial = Double(raw), serial.isFinite, (0...2_958_465).contains(serial) else { return raw }
        let adjusted = !date1904 && serial < 60 ? serial + 1 : serial
        let value = epoch.addingTimeInterval(adjusted * 86400)
        if !date1904, serial >= 60, serial < 61 {
            if kind == .date { return "1900-02-29" }
            if kind == .dateTime { return "1900-02-29 " + time.string(from: value) }
        }
        switch kind {
        case .date: return date.string(from: value)
        case .time: return time.string(from: value)
        case .dateTime: return dateTime.string(from: value)
        case .number: return raw
        }
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = format
        return formatter
    }

    private static func kind(_ code: String) -> Kind {
        if code.range(of: #"\[[hHmMsS]+\]"#, options: .regularExpression) != nil { return .number }
        var visible = "", quoted = false, escaped = false, bracket = false
        for character in code.lowercased() {
            if escaped { escaped = false; continue }
            if character == "\\" || character == "_" || character == "*" { escaped = true; continue }
            if character == "\"" { quoted.toggle(); continue }
            if quoted { continue }
            if character == "[" { bracket = true; continue }
            if character == "]" { bracket = false; continue }
            if !bracket { visible.append(character) }
        }
        let date = visible.contains("y") || visible.contains("d")
        let time = visible.contains("h") || visible.contains("s")
        if date { return time ? .dateTime : .date }
        if time { return .time }
        return visible.contains("m") ? .date : .number
    }
}
