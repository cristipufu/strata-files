import Foundation
import Combine

/// Strata's presentation of tags. File assignments and Finder's private settings have separate owners.
package final class TagCatalog: ObservableObject {
    package enum Origin { case file, finder, chosen }
    nonisolated package static let maximumEntries = 4096
    nonisolated package static let maximumFavorites = 7
    nonisolated private static let maximumSavedBytes = 8 << 20
    package nonisolated struct Entry: Codable, Equatable, Identifiable, Sendable {
        package let id: UUID
        package var tag: FinderTag
        package var inSidebar: Bool
        package var favorite: Bool
        var definitionIsLocal = false
    }

    private nonisolated struct Saved: Codable {
        var version = 1
        var entries: [Entry]
        var hiddenNames: Set<String>
        var tintFolders: Bool
    }

    package enum Failure: LocalizedError {
        case invalidName, duplicate, favoriteLimit
        package var errorDescription: String? {
            switch self {
            case .invalidName: String(localized: "Enter a tag name between 1 and 255 characters.")
            case .duplicate: String(localized: "A tag with that name already exists.")
            case .favoriteLimit: String(localized: "Choose up to seven favorite tags.")
            }
        }
    }

    @Published package private(set) var entries: [Entry]
    @Published package private(set) var tintFolders: Bool
    private var hiddenNames: Set<String>
    private let preferences: Prefs
    private let discover: @Sendable () async -> [FinderTag]
    private var discovery: Task<Void, Never>?
    private var loaded = false
    private static let key = "tagCatalog.v1"

    package init(preferences: Prefs, standard: [FinderTag], discover: @escaping @Sendable () async -> [FinderTag] = { [] }) {
        self.preferences = preferences
        self.discover = discover
        let saved = preferences.defaults.data(forKey: Self.key).flatMap {
            $0.count <= Self.maximumSavedBytes ? try? JSONDecoder().decode(Saved.self, from: $0) : nil
        }
        if let saved, saved.version == 1, Self.valid(saved.entries) {
            entries = saved.entries
            hiddenNames = saved.hiddenNames
            tintFolders = saved.tintFolders
        } else {
            var seen = Set<String>()
            entries = standard.filter { Self.valid($0) && seen.insert($0.name.lowercased()).inserted }
                .prefix(Self.maximumFavorites).map { Entry(id: UUID(), tag: $0, inSidebar: true, favorite: true) }
            hiddenNames = []
            tintFolders = true
            for name in (preferences.defaults.stringArray(forKey: "recentTags") ?? []).prefix(30) {
                let name = TagStore.clean(name)
                if Self.valid(FinderTag(name: name, color: 0)), !entries.contains(where: { Self.same($0.tag.name, name) }) {
                    entries.append(Entry(id: UUID(), tag: FinderTag(name: name, color: 0), inSidebar: true, favorite: false))
                }
            }
        }
    }

    deinit { discovery?.cancel() }

    package var sidebarTags: [FinderTag] { entries.filter(\.inSidebar).map(\.tag) }
    package var favorites: [FinderTag] { entries.filter(\.favorite).map(\.tag) }
    package func resolve(_ name: String) -> FinderTag {
        let name = TagStore.clean(name)
        return entries.first { Self.same($0.tag.name, name) }?.tag ?? FinderTag(name: name, color: 0)
    }

    /// Discovery only adds unknown names. Explicit local changes, including deletion, win over later imports.
    package func load() async {
        guard !loaded else { return }
        await refresh()
    }

    package func refresh() async {
        if let discovery { await discovery.value; return }
        let read = discover
        let task = Task { [weak self] in
            let tags = await read()
            guard !Task.isCancelled else { return }
            self?.include(tags, origin: .finder)
        }
        discovery = task
        await task.value
        loaded = true
        discovery = nil
    }

    package func include(_ tags: [FinderTag], origin: Origin = .file) {
        var updated = entries
        if origin == .finder {
            let positions = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.tag.name.lowercased(), $0.offset) })
            var seen = Set<String>()
            for tag in tags where Self.valid(tag) && seen.insert(tag.name.lowercased()).inserted {
                if let index = positions[tag.name.lowercased()], !updated[index].definitionIsLocal { updated[index].tag = tag }
            }
        }
        var names = Set(entries.map { $0.tag.name.lowercased() })
        var additions: [Entry] = []
        for tag in tags where entries.count + additions.count < Self.maximumEntries {
            guard Self.valid(tag), origin == .chosen || !hiddenNames.contains(tag.name.lowercased()),
                  names.insert(tag.name.lowercased()).inserted else { continue }
            if origin == .chosen { hiddenNames.remove(tag.name.lowercased()) }
            additions.append(Entry(id: UUID(), tag: tag, inSidebar: origin == .chosen, favorite: false, definitionIsLocal: origin == .chosen))
        }
        guard !additions.isEmpty || updated != entries else { return }
        entries = updated + additions
        save()
    }

    package func validate(_ tag: FinderTag, replacing id: UUID? = nil) throws {
        guard Self.valid(tag) else { throw Failure.invalidName }
        guard !entries.contains(where: { $0.id != id && Self.same($0.tag.name, tag.name) }) else { throw Failure.duplicate }
    }

    @discardableResult package func add(_ tag: FinderTag) throws -> UUID {
        try validate(tag)
        guard entries.count < Self.maximumEntries else { throw POSIXError(.ENOSPC) }
        let entry = Entry(id: UUID(), tag: tag, inSidebar: true, favorite: false, definitionIsLocal: true)
        hiddenNames.remove(tag.name.lowercased())
        entries.append(entry)
        save()
        return entry.id
    }

    /// Called only after the file operation has finished. Keeping an entry's ID preserves its display choices.
    package func replace(_ id: UUID, with tag: FinderTag?, undo: UndoManager? = nil) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if let tag { try validate(tag, replacing: id) }
        let before = entries[index]
        hiddenNames.insert(entries[index].tag.name.lowercased())
        if let tag {
            hiddenNames.remove(tag.name.lowercased())
            entries[index].tag = tag
            entries[index].definitionIsLocal = true
        } else { entries.remove(at: index) }
        save()
        let after = entries.first { $0.id == id }
        registerRestore(before, expected: after, index: index, undo: undo)
    }

    private func registerRestore(_ entry: Entry?, expected: Entry?, index: Int, undo: UndoManager?) {
        guard let undo, let id = entry?.id ?? expected?.id else { return }
        // The callback retains the catalog; UndoManager keeps an unretained target pointer.
        undo.registerUndo(withTarget: undo) { [catalog = self] undo in
            MainActor.assumeIsolated {
                guard catalog.entries.first(where: { $0.id == id }) == expected else { return }
                if let entry, (try? catalog.validate(entry.tag, replacing: id)) == nil { return }
                catalog.entries.removeAll { $0.id == id }
                if let expected { catalog.hiddenNames.insert(expected.tag.name.lowercased()) }
                if let entry {
                    catalog.hiddenNames.remove(entry.tag.name.lowercased())
                    catalog.entries.insert(entry, at: min(index, catalog.entries.count))
                }
                catalog.save()
                catalog.registerRestore(expected, expected: entry, index: index, undo: undo)
            }
        }
    }

    package func show(_ id: UUID, inSidebar: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].inSidebar = inSidebar
        save()
    }

    package func favorite(_ id: UUID, enabled: Bool) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        guard !enabled || entries[index].favorite || favorites.count < Self.maximumFavorites else { throw Failure.favoriteLimit }
        entries[index].favorite = enabled
        save()
    }

    package func move(_ id: UUID, by offset: Int) {
        guard (-1...1).contains(offset), let index = entries.firstIndex(where: { $0.id == id }), entries.indices.contains(index + offset) else { return }
        entries.swapAt(index, index + offset)
        save()
    }

    package func setTintFolders(_ enabled: Bool) { tintFolders = enabled; save() }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(entries: entries, hiddenNames: hiddenNames, tintFolders: tintFolders)) else { return }
        preferences.defaults.set(data, forKey: Self.key)
        NotificationCenter.default.post(name: .tagCatalogChanged, object: self)
    }

    nonisolated private static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
    nonisolated private static func valid(_ tag: FinderTag) -> Bool {
        !tag.name.isEmpty && tag.name.count <= FinderTag.maximumNameLength && TagStore.clean(tag.name) == tag.name && !tag.name.contains("\0") && (0...7).contains(tag.color)
    }
    nonisolated private static func valid(_ entries: [Entry]) -> Bool {
        entries.count <= Self.maximumEntries && entries.allSatisfy { valid($0.tag) }
            && Set(entries.map(\.id)).count == entries.count
            && Set(entries.map { $0.tag.name.lowercased() }).count == entries.count
            && entries.filter(\.favorite).count <= Self.maximumFavorites
    }
}

package extension Notification.Name {
    static let tagCatalogChanged = Notification.Name("StrataTagCatalogChanged")
}
