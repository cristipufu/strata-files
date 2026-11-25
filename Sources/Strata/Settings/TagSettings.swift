import SwiftUI

struct TagSettings: View {
    private static let rowHeight: CGFloat = 32
    @ObservedObject var editing: TagEditing
    @ObservedObject private var catalog: TagCatalog
    @ObservedObject private var management: TagManagement
    @FocusState private var focusedName: UUID?

    init(editing: TagEditing) {
        self.editing = editing
        catalog = editing.catalog
        management = editing.management
    }

    private var selected: TagCatalog.Entry? { catalog.entries.first { $0.id == editing.selection } }

    var body: some View {
        VStack(spacing: 0) {
            tagList.padding(.horizontal, 20).padding(.top, 16)
                .disabled(!editing.canEdit).settingAnchor(.tags)
            controls
        }
        .modifier(ThemedFormBackground())
        .task(id: editing.draft?.id) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            focusedName = editing.draft?.id
        }
        .onDisappear { editing.discard(); management.cancel() }
        .onExitCommand { editing.discard(); management.cancel() }
        .task { await catalog.load() }
        .alert(String(localized: "Tags"), isPresented: Binding(get: { management.error != nil }, set: { if !$0 { management.error = nil } })) {
            Button(String(localized: "OK"), role: .cancel) { management.error = nil }
        } message: { Text(verbatim: management.error ?? "") }
    }

    // A List inside a grouped Form becomes form rows and loses its own scrolling viewport.
    private var tagList: some View {
        ScrollViewReader { proxy in
            List(selection: Binding(get: { editing.selection }, set: { editing.select($0) })) {
                ForEach(catalog.entries) { entry in
                    tagRow(id: entry.id, entry: entry).tag(entry.id)
                }
                if let draft = editing.draft, draft.original == nil {
                    tagRow(id: draft.id, entry: nil).id(draft.id).tag(draft.id)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            .onChange(of: editing.selection) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
            .onChange(of: catalog.entries.map(\.id)) { _, _ in if let selection = editing.selection { proxy.scrollTo(selection, anchor: .center) } }
        }.frame(height: 240)
    }

    private func tagRow(id: UUID, entry: TagCatalog.Entry?) -> some View {
        let draft = editing.draft.flatMap { $0.id == id ? $0 : nil }
        let color = draft?.color ?? entry?.tag.color ?? 0
        return HStack(spacing: 8) {
            Toggle(String(localized: "Show in Sidebar"), isOn: Binding(get: { entry?.inSidebar ?? true }, set: {
                if let entry { catalog.show(entry.id, inSidebar: $0) }
            })).labelsHidden().disabled(entry == nil).help(String(localized: "Show in Sidebar"))
            Circle().fill(Color(nsColor: FinderTag(name: "", color: color).displayColor ?? .secondaryLabelColor))
                .frame(width: 10, height: 10)
            if draft != nil {
                TextField(String(localized: "Tag name"), text: Binding(get: { editing.draft?.id == id ? editing.draft?.name ?? "" : "" }, set: {
                    editing.name($0, for: id)
                }))
                .textFieldStyle(.plain).multilineTextAlignment(.leading)
                .focused($focusedName, equals: id)
                .onSubmit { editing.finish() }
                .onExitCommand { editing.discard() }
                .accessibilityLabel(String(localized: "Tag name"))
            } else if let entry {
                Text(verbatim: entry.tag.name).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle()).onTapGesture(count: 2) { focusedName = editing.beginRename(entry) }
            }
            Picker(String(localized: "Color"), selection: Binding(get: { color }, set: {
                editing.color($0, for: id)
                focusedName = editing.draft?.id
            })) {
                Text(String(localized: "None")).tag(0)
                ForEach(FinderTag.standard, id: \.color) { tag in Text(verbatim: tag.shownName).tag(tag.color) }
            }.labelsHidden().pickerStyle(.menu).controlSize(.small).frame(width: 100)
            Button {
                if let entry { attempt { try catalog.favorite(entry.id, enabled: !entry.favorite) } }
            } label: { Image(systemName: entry?.favorite == true ? "star.fill" : "star") }
                .modifier(TagActionStyle()).disabled(entry == nil).help(String(localized: "Favorite Tags"))
        }.frame(height: Self.rowHeight)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
    }

    private var controls: some View {
        Form {
            Section {
                HStack {
                    Button { focusedName = editing.newTag() } label: { Label(String(localized: "New Tag"), systemImage: "plus") }
                    Button { if let selected { focusedName = editing.beginRename(selected) } } label: { Image(systemName: "pencil") }
                        .disabled(selected == nil).help(String(localized: "Rename"))
                    Button { if let selected { editing.discard(); management.prepare(selected, replacement: nil) } } label: { Image(systemName: "minus") }
                        .disabled(selected == nil).help(String(localized: "Delete Tag"))
                    Spacer()
                    Button { if let selected { catalog.move(selected.id, by: -1) } } label: { Image(systemName: "arrow.up") }
                        .disabled(selected == nil).help(String(localized: "Move Up"))
                    Button { if let selected { catalog.move(selected.id, by: 1) } } label: { Image(systemName: "arrow.down") }
                        .disabled(selected == nil).help(String(localized: "Move Down"))
                }.modifier(TagActionStyle())
                Text(String(localized: "Check tags to show them in the sidebar. Star up to seven favorites for file menus."))
                    .font(.callout).foregroundStyle(.secondary)
                Toggle(String(localized: "Tint folders based on tags"), isOn: Binding(get: { catalog.tintFolders }, set: { catalog.setTintFolders($0) }))
            }.disabled(!editing.canEdit)
            if management.busy {
                HStack { ProgressView().controlSize(.small); Button(String(localized: "Cancel")) { management.cancel() } }.modifier(TagActionStyle())
            }
            if let review = management.review {
                HStack {
                    Circle().fill(Color(nsColor: review.entry.tag.displayColor ?? .secondaryLabelColor)).frame(width: 10, height: 10)
                    Text(verbatim: review.entry.tag.name)
                    Image(systemName: "arrow.right")
                    if let replacement = review.replacement {
                        Circle().fill(Color(nsColor: replacement.displayColor ?? .secondaryLabelColor)).frame(width: 10, height: 10)
                        Text(verbatim: replacement.name)
                    } else { Text(String(localized: "Delete Tag")) }
                }
                Text(String(localized: "\(review.plan.count) files", comment: "plural"))
                Text(String(localized: "Only matching files found by Spotlight will be updated. Offline and unindexed files will stay unchanged."))
                HStack {
                    Button(String(localized: "Cancel")) { management.cancel() }
                    Button(String(localized: "Apply")) { management.apply() }
                }.modifier(TagActionStyle())
            }
            HStack {
                Button(String(localized: "Undo")) { management.undoChange() }.disabled(management.busy || !management.undo.canUndo)
                Spacer()
                Button(String(localized: "Refresh")) { Task { [catalog] in await catalog.refresh() } }.disabled(!editing.canEdit)
            }.modifier(TagActionStyle())
        }
        .formStyle(.grouped)
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action() } catch { management.error = error.localizedDescription }
    }
}

/// Grouped forms draw action text in the tint. Give the glyphs their own ink and keep the native disabled state.
private struct TagActionStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.buttonStyle(.borderless).tint(colorScheme == .dark ? .white : .black)
    }
}
