import SwiftUI

struct TagSettings: View {
    @ObservedObject var catalog: TagCatalog
    @ObservedObject var management: TagManagement
    @State private var selection: UUID?
    @State private var name = ""
    @State private var color = 0

    private var selected: TagCatalog.Entry? { catalog.entries.first { $0.id == selection } }

    var body: some View {
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(catalog.entries) { entry in
                        HStack {
                            Toggle(String(localized: "Show in Sidebar"), isOn: Binding(get: { entry.inSidebar }, set: { catalog.show(entry.id, inSidebar: $0) }))
                                .labelsHidden().help(String(localized: "Show in Sidebar"))
                            Circle().fill(Color(nsColor: entry.tag.displayColor ?? .secondaryLabelColor)).frame(width: 10, height: 10)
                            Text(verbatim: entry.tag.name)
                            Spacer()
                            Button { attempt { try catalog.favorite(entry.id, enabled: !entry.favorite) } } label: {
                                Image(systemName: entry.favorite ? "star.fill" : "star")
                            }.buttonStyle(.borderless).help(String(localized: "Favorite Tags"))
                        }.tag(entry.id)
                    }
                }.frame(height: 180)
                HStack {
                    Button { selection = nil; name = ""; color = 0 } label: { Image(systemName: "plus") }
                        .help(String(localized: "New Tag"))
                    Button { if let selected { management.prepare(selected, replacement: nil) } } label: { Image(systemName: "minus") }
                        .disabled(selected == nil).help(String(localized: "Delete Tag"))
                    Spacer()
                    Button { if let selection { catalog.move(selection, by: -1) } } label: { Image(systemName: "arrow.up") }
                        .disabled(selected == nil).help(String(localized: "Move Up"))
                    Button { if let selection { catalog.move(selection, by: 1) } } label: { Image(systemName: "arrow.down") }
                        .disabled(selected == nil).help(String(localized: "Move Down"))
                }
                HStack {
                    TextField(String(localized: "Tag name"), text: $name)
                    Picker(String(localized: "Color"), selection: $color) {
                        Text(String(localized: "None")).tag(0)
                        ForEach(FinderTag.standard, id: \.color) { tag in Text(verbatim: tag.shownName).tag(tag.color) }
                    }.frame(width: 140)
                    Button(String(localized: "Save")) {
                        let tag = FinderTag(name: TagStore.clean(name), color: color)
                        if let selected { management.prepare(selected, replacement: tag) }
                        else { attempt { selection = try catalog.add(tag) } }
                    }.disabled(TagStore.clean(name).isEmpty)
                }
                Text(String(localized: "Check tags to show them in the sidebar. Star up to seven favorites for file menus."))
                    .font(.callout).foregroundStyle(.secondary)
                Toggle(String(localized: "Tint folders based on tags"), isOn: Binding(get: { catalog.tintFolders }, set: { catalog.setTintFolders($0) }))
            }.disabled(management.busy || management.review != nil).settingAnchor(.tags)
            if management.busy {
                HStack { ProgressView().controlSize(.small); Button(String(localized: "Cancel")) { management.cancel() } }
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
                }
            }
            HStack {
                Button(String(localized: "Undo")) { management.undoChange() }.disabled(management.busy || !management.undo.canUndo)
                Spacer()
                Button(String(localized: "Refresh")) { Task { [catalog] in await catalog.refresh() } }.disabled(management.busy || management.review != nil)
            }
        }
        .formStyle(.grouped).modifier(ThemedFormBackground())
        .onChange(of: selection) { _, _ in name = selected?.tag.name ?? ""; color = selected?.tag.color ?? 0; management.cancel() }
        .onChange(of: selected?.tag) { _, tag in name = tag?.name ?? ""; color = tag?.color ?? 0 }
        .onDisappear { management.cancel() }
        .task { await catalog.load() }
        .alert(String(localized: "Tags"), isPresented: Binding(get: { management.error != nil }, set: { if !$0 { management.error = nil } })) {
            Button(String(localized: "OK"), role: .cancel) { management.error = nil }
        } message: { Text(verbatim: management.error ?? "") }
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action() } catch { management.error = error.localizedDescription }
    }
}
