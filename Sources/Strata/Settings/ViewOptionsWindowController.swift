import AppKit
import SwiftUI

final class ViewOptionsWindowController: NSWindowController {
    init(preferences: Prefs) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 410, height: 650),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = String(localized: "View Options", comment: "Title of the window opened with Command-J")
        panel.contentViewController = NSHostingController(rootView: ViewOptionsView(preferences: preferences))
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        ThemeStyle.bind(panel)
        panel.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() { showWindow(nil) }
}

struct ViewOptionsView: View {
    let preferences: Prefs
    @State private var options: IconViewOptions
    @State private var iconSize: Double
    @State private var previews: Bool
    @State private var hiddenColumns: Set<String>

    init(preferences: Prefs) {
        self.preferences = preferences
        _options = State(initialValue: preferences.iconViewOptions)
        _iconSize = State(initialValue: preferences.gridIconSize)
        _previews = State(initialValue: preferences.showIconPreviews)
        _hiddenColumns = State(initialValue: preferences.hiddenListColumns)
    }

    var body: some View {
        Form {
            Section("Icons") {
                Slider(value: Binding(get: { iconSize }, set: { iconSize = $0; preferences.gridIconSize = $0 }), in: 32...256) {
                    Text("Icon size")
                }
                Toggle("Show item info", isOn: $options.showsInfo)
                Picker("Folder info", selection: $options.folderInfo) {
                    Text("Item count").tag(FolderIconInfo.itemCount)
                    Text("Total size").tag(FolderIconInfo.size)
                }
                .disabled(!options.showsInfo)
                Text("Pictures and movies show their dimensions. Other files show their size.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show icon previews", isOn: Binding(get: { previews }, set: { previews = $0; preferences.showIconPreviews = $0 }))
            }
            Section("List columns") {
                ForEach(ListColumn.allCases, id: \.self) { column in
                    Toggle(column.title, isOn: Binding(get: { !hiddenColumns.contains(column.rawValue) }, set: { shown in
                        if shown { hiddenColumns.remove(column.rawValue) } else { hiddenColumns.insert(column.rawValue) }
                        preferences.hiddenListColumns = hiddenColumns
                    }))
                }
            }
            Text("Applies to all windows.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .modifier(ThemedFormBackground())
        .onChange(of: options) { _, value in
            if value != preferences.iconViewOptions { preferences.iconViewOptions = value }
        }
        .onReceive(preferences.notifications.publisher(for: .viewOptionsChanged)) { _ in
            options = preferences.iconViewOptions
            iconSize = preferences.gridIconSize
        }
        .onReceive(preferences.notifications.publisher(for: .appearanceChanged)) { _ in previews = preferences.showIconPreviews }
        .onReceive(preferences.notifications.publisher(for: .listColumnsChanged)) { _ in hiddenColumns = preferences.hiddenListColumns }
    }
}
