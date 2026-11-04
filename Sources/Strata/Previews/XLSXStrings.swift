import Foundation

nonisolated enum XLSXStrings {
    static let entryLimit = 50_000
    static let cellByteLimit = 256 << 10

    static func read(_ data: Data) throws -> [String] {
        var strings: [String] = [], stack: [String] = [], value = "", bytes = 0
        try XLSXXML.read(data) { event in
            switch event {
            case .start(let name, _):
                if stack.isEmpty, name != "sst" { throw PreviewError.unsupported }
                stack.append(name)
                if name == "si" { value = "" }
            case .text(let text):
                if stack.last == "t", stack.contains("si"), !stack.contains("rPh") {
                    guard text.utf8.count <= cellByteLimit - value.utf8.count else { throw XLSXXML.limitError }
                    value += text
                }
            case .end(let name):
                if name == "si" {
                    guard strings.count < entryLimit, value.utf8.count <= XLSXXML.byteLimit - bytes else { throw XLSXXML.limitError }
                    bytes += value.utf8.count
                    strings.append(value)
                }
                stack.removeLast()
            }
            return true
        }
        return strings
    }
}
