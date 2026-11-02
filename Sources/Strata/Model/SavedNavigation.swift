import Foundation

/// Session history contains places, never file selections or permission to perform a command.
package nonisolated struct SavedNavigation: Codable, Equatable, Sendable {
    package var current: SavedDestination? = nil
    package var back: [SavedDestination] = []
    package var forward: [SavedDestination] = []

    package init(current: SavedDestination? = nil, back: [SavedDestination] = [], forward: [SavedDestination] = []) {
        self.current = current
        self.back = back
        self.forward = forward
    }
    package static let limit = 100

    private enum CodingKeys: String, CodingKey { case current, back, forward }
}

extension SavedNavigation {
    package nonisolated init(from decoder: Decoder) throws {
        self.init()
        guard let values = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        current = try? values.decode(SavedDestination.self, forKey: .current)
        back = Array(((try? values.decode([SavedDestination].self, forKey: .back)) ?? []).suffix(Self.limit))
        forward = Array(((try? values.decode([SavedDestination].self, forKey: .forward)) ?? []).suffix(Self.limit))
    }
}

/// A server path is relative to its saved server's identity, independent of the location of its local cache.
package nonisolated struct SavedDestination: Codable, Equatable, Sendable {
    package var kind: String
    package var path: String? = nil
    package var server: String? = nil
    package var query: String? = nil

    package init(kind: String, path: String? = nil, server: String? = nil, query: String? = nil) {
        self.kind = kind
        self.path = path
        self.server = server
        self.query = query
    }

    package static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 4096 && !path.utf8.contains(0)
    }

    private enum CodingKeys: String, CodingKey { case kind, path, server, query }
}

extension SavedDestination {
    package nonisolated init(from decoder: Decoder) throws {
        self.init(kind: "")
        guard let values = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        var invalid = false
        func text(_ key: CodingKeys) -> String? {
            guard values.contains(key), (try? values.decodeNil(forKey: key)) != true else { return nil }
            guard let value = try? values.decode(String.self, forKey: key) else { invalid = true; return nil }
            return value
        }
        kind = text(.kind) ?? ""
        path = text(.path)
        server = text(.server)
        query = text(.query)
        if invalid { kind = "" }
    }
}

/// Bounded session decoding preserves independent valid windows and does not rewrite the stored bytes.
package nonisolated enum SessionStorage {
    package static let byteLimit = 4 << 20
    private struct Record: Decodable {
        let window: Workspace?
        nonisolated init(from decoder: Decoder) throws { window = try? Workspace(from: decoder) }
    }

    package static func decode(_ data: Data) -> [Workspace]? {
        guard data.count <= byteLimit, let records = try? JSONDecoder().decode([Record].self, from: data) else { return nil }
        return bounded(records.compactMap(\.window))
    }

    package static func encode(_ windows: [Workspace]) -> Data? {
        let windows = bounded(windows)
        guard let data = try? JSONEncoder().encode(windows) else { return nil }
        if data.count <= byteLimit { return data }
        // Very long paths and histories must not prevent the window layout itself from reopening.
        guard let layout = try? JSONEncoder().encode(windows.map({ window in
            var copy = window; copy.navigation = nil; return copy
        })), layout.count <= byteLimit else { return nil }
        return layout
    }

    private static func bounded(_ windows: [Workspace]) -> [Workspace] {
        var remaining = 80
        var metadataBytes = byteLimit / 2
        func place(_ value: SavedDestination?) -> SavedDestination? {
            guard let value, value.kind.utf8.count <= 32, (value.path?.utf8.count ?? 0) <= 4096,
                  (value.server?.utf8.count ?? 0) <= 128, (value.query?.utf8.count ?? 0) <= 8192 else { return nil }
            let bytes = value.kind.utf8.count + (value.path?.utf8.count ?? 0)
                + (value.server?.utf8.count ?? 0) + (value.query?.utf8.count ?? 0)
            // JSON can escape each input byte into six ASCII bytes; budget before encoding long histories.
            let cost = bytes * 6 + 128
            guard cost <= metadataBytes else { return nil }
            metadataBytes -= cost
            return value
        }
        func history(_ saved: SavedNavigation) -> SavedNavigation {
            SavedNavigation(current: place(saved.current),
                back: Array(saved.back.suffix(SavedNavigation.limit).reversed().compactMap { place($0) }.reversed()),
                forward: Array(saved.forward.suffix(SavedNavigation.limit).reversed().compactMap { place($0) }.reversed()))
        }
        return windows.lazy.filter { window in
            window.tabs.prefix(20).contains { $0.prefix(2).contains(where: SavedDestination.validPath) }
        }.prefix(20).compactMap { window in
            guard remaining > 0 else { return nil }
            var copy = window
            if copy.name.utf8.count > 4096 { copy.name = "" }
            copy.tabs = Array(copy.tabs.prefix(min(20, remaining))).map { tab in
                tab.prefix(2).map { SavedDestination.validPath($0) ? $0 : "" }
            }
            copy.shares = copy.shares.map { shares in
                Dictionary(uniqueKeysWithValues: shares.prefix(64).filter {
                    SavedDestination.validPath($0.key) && $0.value.utf8.count <= 8192
                }.map { ($0.key, $0.value) })
            }
            remaining -= copy.tabs.count
            copy.modes = copy.modes.map { Array($0.prefix(copy.tabs.count)).map { Array($0.prefix(2)) } }
            copy.activePanes = copy.activePanes.map { Array($0.prefix(copy.tabs.count)) }
            copy.navigation = copy.navigation.map { Array($0.prefix(copy.tabs.count)).map { Array($0.prefix(2)).map(history) } }
            return copy
        }
    }
}
