import Foundation
@testable import StrataFiles

extension OperationLog.Entry {
    /// Fixtures may capture current items; production always supplies the identities captured when they landed.
    init(name: String, kind: Kind, moves: [HistoryMove] = [], created: [String] = [], replacements: [HistoryMove] = [],
         containers: [String] = [], containerIdentities: [String: String] = [:], fileIdentities: [String: String]? = nil) {
        let paths = moves.map(\.to) + created + replacements.map(\.to)
        let now = fileIdentities ?? Dictionary(paths.map { ($0, OperationLog.identity($0) ?? "") }) { first, _ in first }
        self.init(name: name, kind: kind, moves: moves, created: created, replacements: replacements, containers: containers,
                  containerIdentities: containerIdentities, fileIdentities: now)
    }
}

extension LandedFiles {
    /// What History keeps of everything recorded here, converted now.
    var savedKeys: [String: String] { historyKeysNow(for: recorded.keys.map { URL(fileURLWithPath: $0) }) }
}
