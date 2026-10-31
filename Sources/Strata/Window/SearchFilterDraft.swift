import Foundation
import StrataIndex

/// Edits only the chosen filter terms. Other spelling, quoted names and advanced syntax stay with the search.
nonisolated struct SearchFilterDraft: Equatable {
    var kind = "", extensions = "", size = "", modified = "", source = ""
    private let original: String
    private let canonical: String
    private static let keys: [[String]] = [["kind", "type", "is"], ["ext", "extension"], ["size"], ["modified", "mod", "date", "dm"], ["source", "from"]]

    init(_ text: String) {
        original = text
        if let metadata = SpotlightQuery.naturalForm(text) { canonical = metadata }
        else if let natural = NaturalQuery.interpret(text) {
            let query = natural.query
            var terms = query.terms.map { SearchTerms.quote(String(decoding: $0, as: UTF8.self)) }
            if let kind = query.kind { terms.append("kind:" + kind.rawValue) }
            if !query.extensions.isEmpty { terms.append("ext:" + query.extensions.sorted().joined(separator: ",")) }
            if query.minSize != nil || query.maxSize != nil { terms.append("size:\(query.minSize.map(String.init) ?? "")..\(query.maxSize.map(String.init) ?? "")") }
            let formatter = ISO8601DateFormatter()
            func date(_ value: UInt32?) -> String { value.map { formatter.string(from: Date(timeIntervalSince1970: Double($0))) } ?? "" }
            if query.modifiedAfter != nil || query.modifiedBefore != nil { terms.append("modified:\(date(query.modifiedAfter))..\(date(query.modifiedBefore))") }
            canonical = terms.joined(separator: " ")
        } else { canonical = text }
        for term in SearchTerms.split(canonical) {
            guard let key = term.key, let colon = term.value.firstIndex(of: ":") else { continue }
            let value = String(term.value[term.value.index(after: colon)...])
            switch key {
            case "kind", "type", "is": kind = value
            case "ext", "extension": extensions += (extensions.isEmpty ? "" : ",") + value
            case "size": size = value
            case "modified", "mod", "date", "dm": modified = value
            case "source", "from": source = value
            default: break
            }
        }
    }

    private var values: [String] { [kind, extensions, size, modified, source].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }

    func query() -> String? {
        let initial = Self(original), before = initial.values, after = values
        let changed = before.indices.filter { before[$0] != after[$0] }
        guard !changed.isEmpty else { return original }
        guard SearchTerms.split(canonical).allSatisfy(\.isComplete) else { return nil }
        guard after.allSatisfy({ $0.utf8.count <= 8192 && !$0.utf8.contains(0) }) else { return nil }
        if !after[2].isEmpty {
            if after[2].contains("..") {
                let bounds = after[2].components(separatedBy: "..")
                guard bounds.count == 2, bounds.allSatisfy({ $0.isEmpty || IndexQuery.bytes($0.lowercased()) != nil }) else { return nil }
            }
            let parsed = IndexQuery.parse("size:" + SearchTerms.quote(after[2]))
            guard parsed.minSize != nil || parsed.maxSize != nil,
                  (parsed.minSize ?? 0) <= (parsed.maxSize ?? .max) else { return nil }
        }
        if !after[3].isEmpty {
            if after[3].contains("..") {
                let bounds = after[3].components(separatedBy: "..")
                guard bounds.count == 2, bounds.allSatisfy({ $0.isEmpty || IndexQuery.parse("modified:>" + $0).modifiedAfter != nil }) else { return nil }
            }
            let parsed = IndexQuery.parse("modified:" + SearchTerms.quote(after[3]))
            guard parsed.modifiedAfter != nil || parsed.modifiedBefore != nil,
                  (parsed.modifiedAfter ?? 0) < (parsed.modifiedBefore ?? .max) else { return nil }
        }
        var terms = SearchTerms.split(canonical).filter { term in
            !changed.contains { Self.keys[$0].contains(term.key ?? "") }
        }.map(\.raw)
        for index in changed where !after[index].isEmpty {
            terms.append(Self.keys[index][0] + ":" + SearchTerms.quote(after[index]))
        }
        let updated = terms.joined(separator: " ")
        // Spotlight does not implement the index's regex, path matching, exclusions or exact-case mode.
        if !after[4].isEmpty {
            guard SpotlightQuery.acceptsSourceNames(updated) else { return nil }
        }
        return updated
    }
}

/// A delayed filter editor cannot change a different pane or a search that left and returned.
struct SearchFilterContext {
    private weak var owner: BrowserWindowController?
    private weak var pane: Pane?
    private let destination: Destination
    private let revision: Int

    init(_ owner: BrowserWindowController) {
        self.owner = owner; pane = owner.pane
        destination = owner.destination; revision = owner.pane.navigationRevision
    }

    func apply(_ query: String) -> Bool {
        guard let owner, let pane, owner.pane === pane, owner.panes.contains(where: { $0 === pane }),
              !owner.isClosed, owner.window?.attachedSheet == nil, owner.window?.contentViewController != nil, pane.navigationRevision == revision,
              pane.destination == destination, case .search(_, let scope) = destination else { return false }
        if query.isEmpty { owner.leaveSearch() }
        else {
            pane.destination = .search(query, scope: scope)
            owner.updateChrome()
            pane.search.run()
        }
        return true
    }
}
