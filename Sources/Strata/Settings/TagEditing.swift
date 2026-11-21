import Foundation
import Combine

/// Owns the one inline draft; file changes still go through the management session's review.
final class TagEditing: ObservableObject {
    struct Draft: Identifiable {
        let id: UUID
        let original: TagCatalog.Entry?
        var name: String
        var color: Int
    }

    let management: TagManagement
    var catalog: TagCatalog { management.store.catalog }
    @Published private(set) var selection: UUID?
    @Published private(set) var draft: Draft?
    var canEdit: Bool { !management.busy && management.review == nil }

    init(management: TagManagement) { self.management = management }

    @discardableResult func newTag() -> UUID? {
        guard canEdit else { return nil }
        if draft != nil { finish(); guard draft == nil, canEdit else { return draft?.id } }
        let draft = Draft(id: UUID(), original: nil, name: "", color: 0)
        self.draft = draft
        selection = draft.id
        return draft.id
    }

    @discardableResult func beginRename(_ entry: TagCatalog.Entry) -> UUID? {
        guard canEdit else { return nil }
        if draft?.id == entry.id { return entry.id }
        if let draft, draft.id != entry.id { finish(); guard self.draft == nil, canEdit else { return nil } }
        draft = Draft(id: entry.id, original: entry, name: entry.tag.name, color: entry.tag.color)
        selection = entry.id
        return entry.id
    }

    func select(_ id: UUID?) {
        if let draft, draft.id != id {
            finish()
            guard self.draft == nil, canEdit else { return }
        }
        selection = id
    }

    func name(_ name: String, for id: UUID) {
        guard draft?.id == id else { return }
        draft?.name = name
    }

    func color(_ color: Int, for id: UUID) {
        guard canEdit else { return }
        if draft?.id == id {
            draft?.color = color
            if let name = draft?.name, !TagStore.clean(name).isEmpty { finish() }
            return
        }
        if draft != nil { finish(); guard draft == nil, canEdit else { return } }
        guard let entry = catalog.entries.first(where: { $0.id == id }), entry.tag.color != color else { return }
        selection = id
        management.prepare(entry, replacement: FinderTag(name: entry.tag.name, color: color))
    }

    func finish() {
        guard canEdit, let draft else { return }
        let name = TagStore.clean(draft.name)
        guard !name.isEmpty else { discard(); return }
        let tag = FinderTag(name: name, color: draft.color)
        do {
            let current = draft.original.flatMap { original in catalog.entries.first { $0.id == original.id } }
            if let original = draft.original, current?.tag != original.tag {
                self.draft = nil
                throw POSIXError(.ESTALE)
            }
            try catalog.validate(tag, replacing: draft.original?.id)
            if let current {
                self.draft = nil
                if tag != current.tag { management.prepare(current, replacement: tag) }
            } else {
                let id = try catalog.add(tag)
                self.draft = nil
                selection = id
            }
        } catch { management.error = error.localizedDescription }
    }

    func discard() {
        if draft?.original == nil, selection == draft?.id { selection = nil }
        draft = nil
    }
}
