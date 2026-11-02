import Foundation

nonisolated package struct HistoryMove: Codable, Equatable, Sendable {
    package let from: String
    package let to: String

    package init(from: URL, to: URL) {
        self.from = from.path
        self.to = to.path
    }

    private enum CodingKeys: String, CodingKey { case from, to }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        from = try values.decode(String.self, forKey: .from)
        to = try values.decode(String.self, forKey: .to)
        guard !from.isEmpty, !to.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .from, in: values,
                debugDescription: "History needs a source and destination for each move.")
        }
    }
}

nonisolated package enum HistoryIdentity: Codable, Equatable, Sendable {
    case unavailable
    case recorded(String)

    package init(_ key: String?) {
        if let key, !key.isEmpty { self = .recorded(key) }
        else { self = .unavailable }
    }

    package var key: String? {
        if case .recorded(let key) = self, !key.isEmpty { key } else { nil }
    }

    package func matches(at path: String) -> Bool {
        key.map { FileIdentity.matchesHistory($0, at: path) } ?? false
    }
}

extension OperationLog {
    package nonisolated struct Entry: Codable, Identifiable, Sendable {
        package enum Kind: String, Codable, Sendable { case move, create }

        package var id = UUID()
        package var date = Date()
        package var name: String
        package var kind: Kind
        package var moves: [HistoryMove]
        package var created: [String]
        package var replacements: [HistoryMove]
        package var containers: [String]
        package var ownership: [String: HistoryIdentity]
        package var undone = false
        package var changed: Date?

        package init(name: String, kind: Kind, moves: [HistoryMove], created: [String] = [],
                     replacements: [HistoryMove] = [], containers: [String] = [],
                     containerIdentities: [String: String] = [:], fileIdentities: [String: String]) {
            self.name = name
            self.kind = kind
            self.moves = moves
            self.created = created
            self.replacements = replacements
            self.containers = containers
            let containerPaths = Set(containers)
            ownership = containerIdentities.filter { containerPaths.contains($0.key) }.mapValues { HistoryIdentity($0) }
            for path in moves.map(\.to) + created + replacements.map(\.to) {
                ownership[path] = HistoryIdentity(fileIdentities[path])
            }
        }

        package func expectation(at path: String) -> HistoryIdentity { ownership[path] ?? .unavailable }

        package var identityKeys: [String: String] { ownership.compactMapValues(\.key) }

        package func sameItems(as other: Entry) -> Bool {
            moves == other.moves && created == other.created && replacements == other.replacements
                && containers == other.containers && ownership == other.ownership
        }

        private enum CodingKeys: String, CodingKey {
            case id, date, name, kind, moves, created, replacements, containers, ownership, undone, changed
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            date = try c.decode(Date.self, forKey: .date)
            name = try c.decode(String.self, forKey: .name)
            kind = try c.decode(Kind.self, forKey: .kind)
            moves = try c.decode([HistoryMove].self, forKey: .moves)
            created = try c.decode([String].self, forKey: .created)
            replacements = try c.decode([HistoryMove].self, forKey: .replacements)
            containers = try c.decode([String].self, forKey: .containers)
            ownership = try c.decode([String: HistoryIdentity].self, forKey: .ownership)
            undone = try c.decode(Bool.self, forKey: .undone)
            changed = try c.decodeIfPresent(Date.self, forKey: .changed)
            for (key, paths) in [(CodingKeys.created, created), (.containers, containers)] {
                guard paths.allSatisfy({ !$0.isEmpty }) else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: c,
                                                          debugDescription: "History paths cannot be empty.")
                }
            }
        }

        package var displayName: String { OperationLog.displayName(name) }
    }
}
