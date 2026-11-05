/// Plans a bounded native animation before the outline begins changing rows.
enum BrowserRowMoves {
    struct Move: Equatable {
        let from: Int
        let to: Int
    }

    static let maximumAnimatedMoves = 64

    /// Nil asks for a reload: a large permutation must not enqueue thousands of native row moves.
    static func plan(from previous: [FileNode], to sorted: [FileNode]) -> [Move]? {
        guard previous.count == sorted.count else { return nil }
        let identities = Set(previous.map(ObjectIdentifier.init))
        guard identities.count == previous.count, identities == Set(sorted.map(ObjectIdentifier.init)) else { return nil }
        var working = previous
        var moves: [Move] = []
        for (target, node) in sorted.enumerated() {
            if working[target] === node { continue }
            guard moves.count < maximumAnimatedMoves,
                  let current = working[target...].firstIndex(where: { $0 === node }) else { return nil }
            moves.append(Move(from: current, to: target))
            working.remove(at: current)
            working.insert(node, at: target)
        }
        return moves
    }
}
