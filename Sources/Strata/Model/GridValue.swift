/// One cell of a data grid.
nonisolated package enum GridValue: Sendable, Equatable {
    case text(String)
    case null
    case blob(bytes: Int)
}
