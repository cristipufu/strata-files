import AppKit

nonisolated struct GridMatch: Equatable, Sendable {
    let row: Int
    let column: Int
}

nonisolated struct GridMatches: Sendable {
    var cells: [GridMatch] = []
    var truncated = false
}

actor GridFinder {
    private static let queryByteLimit = 4096
    private static let matchLimit = 10_000

    func matches(in data: GridData, order: [Int], query: String) throws -> GridMatches {
        try Task.checkCancellation()
        guard !query.isEmpty, query.utf8.count <= Self.queryByteLimit else { return GridMatches() }
        var result = GridMatches()
        for (shownRow, sourceRow) in order.enumerated() {
            guard data.rows.indices.contains(sourceRow) else { continue }
            let row = data.rows[sourceRow]
            for column in data.columns.indices where row.indices.contains(column) {
                try Task.checkCancellation()
                let text = GridView.display(row[column])
                guard text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { continue }
                if result.cells.count == Self.matchLimit { result.truncated = true; return result }
                result.cells.append(GridMatch(row: shownRow, column: column))
            }
        }
        return result
    }
}

@MainActor final class GridSearch {
    typealias Reader = @Sendable (GridData, [Int], String) async throws -> GridMatches
    private let table: GridTableView
    private let read: Reader
    private let status: (String?) -> Void
    private var query = ""
    private var matches = GridMatches()
    private var current = -1
    private var revision = 0
    private var closed = false
    private(set) var task: Task<Void, Never>?

    init(table: GridTableView, read: @escaping Reader, status: @escaping (String?) -> Void) {
        self.table = table; self.read = read; self.status = status
    }

    convenience init(table: GridTableView, status: @escaping (String?) -> Void) {
        let finder = GridFinder()
        self.init(table: table, read: { try await finder.matches(in: $0, order: $1, query: $2) }, status: status)
    }

    isolated deinit { task?.cancel() }

    func find(_ query: String, in data: GridData, order: [Int]) {
        guard !closed else { return }
        let previous = task
        revision += 1
        let revision = revision
        self.query = query
        matches = GridMatches(); current = -1
        let read = read
        task = query.isEmpty ? nil : Task { [weak self] in
            guard !Task.isCancelled else { return }
            let result = try? await read(data, order, query)
            guard !Task.isCancelled, let self, self.revision == revision else { return }
            task = nil
            matches = result ?? GridMatches()
            findNext(backwards: false)
        }
        previous?.cancel()
        guard self.revision == revision else { return }
        status(nil)
    }

    func reload(_ data: GridData, order: [Int]) { find(query, in: data, order: order) }

    func cancel() {
        revision += 1
        let previous = task
        task = nil
        previous?.cancel()
    }

    func close() { closed = true; cancel() }

    func findNext(backwards: Bool) {
        guard !closed, task == nil, !query.isEmpty else { return }
        guard !matches.cells.isEmpty else { status(String(localized: "No Matches")); return }
        current = current < 0 ? (backwards ? matches.cells.count - 1 : 0)
            : (current + (backwards ? matches.cells.count - 1 : 1)) % matches.cells.count
        let match = matches.cells[current], revision = revision
        guard (0..<table.numberOfRows).contains(match.row), (0..<table.numberOfColumns).contains(match.column) else { return }
        table.select(row: match.row, column: match.column)
        guard self.revision == revision else { return }
        table.scrollRowToVisible(match.row)
        table.scrollColumnToVisible(match.column)
        guard self.revision == revision else { return }
        let total = matches.cells.count.formatted() + (matches.truncated ? "+" : "")
        status(String(localized: "Cell \(current + 1) of \(total)", comment: "Find in a table page: current matching cell and total matching cells; total may end in + when capped"))
    }
}
