import Foundation

nonisolated enum XLSXStrings {
    static let entryLimit = 50_000
    static let cellByteLimit = SpreadsheetLimits.cellBytes

    static func read(_ data: Data) throws -> [String] {
        var strings: [String] = [], stack: [String] = [], value = "", bytes = 0
        try WorkbookXML.read(data) { event in
            switch event {
            case .start(let element, _):
                let name = element.local
                if stack.isEmpty, name != "sst" { throw PreviewError.unsupported }
                stack.append(name)
                if name == "si" { value = "" }
            case .text(let text):
                if stack.last == "t", stack.contains("si"), !stack.contains("rPh") {
                    guard text.utf8.count <= cellByteLimit - value.utf8.count else { throw WorkbookXML.limitError }
                    value += text
                }
            case .end(let element):
                let name = element.local
                if name == "si" {
                    guard strings.count < entryLimit, value.utf8.count <= WorkbookXML.byteLimit - bytes else { throw WorkbookXML.limitError }
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
