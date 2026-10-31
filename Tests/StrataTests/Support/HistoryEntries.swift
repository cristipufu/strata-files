import Foundation
@testable import StrataFiles

extension OperationLog.Entry {
    /// An entry whose items are what's at their paths now: History itself is always handed what they were as they
    /// landed.
    init(name: String, kind: Kind, pairs: [[String]] = [], created: [String] = [], replaced: [[String]] = [],
         containers: [String] = [], containerIdentities: [String: String] = [:]) {
        let paths = pairs.map { $0[1] } + created + replaced.map { $0[1] }
        let now = Dictionary(paths.map { ($0, OperationLog.identity($0) ?? "") }) { first, _ in first }
        self.init(name: name, kind: kind, pairs: pairs, created: created, replaced: replaced, containers: containers,
                  containerIdentities: containerIdentities, fileIdentities: now)
    }
}
