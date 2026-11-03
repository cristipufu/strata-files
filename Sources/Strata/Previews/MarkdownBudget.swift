import Foundation

nonisolated enum MarkdownLimits {
    static let nodes = 4096
    static let tables = 128
    static let tableCells = 4096
    static let tableColumns = 20
    static let tableRows = 200
    static let formattingRuns = 16_384
    static let formattingInputUnits = 32_768
    static let renderedUnits = 1 << 20
    static let decoratedLines = 8192
}

nonisolated struct MarkdownLimitExceeded: Error {}

nonisolated struct MarkdownBudget {
    private var nodes = MarkdownLimits.nodes
    private var tables = MarkdownLimits.tables
    private var cells = MarkdownLimits.tableCells
    private var runs = MarkdownLimits.formattingRuns
    private var units = MarkdownLimits.renderedUnits
    private var lines = MarkdownLimits.decoratedLines

    mutating func reserveNode() throws { try Self.consume(1, from: &nodes) }
    mutating func reserveTable() throws { try Self.consume(1, from: &tables) }
    mutating func reserveCells(_ count: Int) throws { try Self.consume(count, from: &cells) }
    mutating func reserveRuns(_ count: Int) throws { try Self.consume(count, from: &runs) }
    mutating func reserveText(_ text: String) throws {
        let count = text.utf16.count
        try Self.consume(count, from: &units)
        let breaks = text.utf16.count { $0 == 10 || $0 == 0x2028 || $0 == 0x2029 }
        try Self.consume(breaks + 1, from: &lines)
    }

    private static func consume(_ count: Int, from remaining: inout Int) throws {
        guard count >= 0, count <= remaining else { throw MarkdownLimitExceeded() }
        remaining -= count
    }
}
