import AppKit
import SwiftUI

final class ViewOptionsWindowController: NSWindowController {
    private let folderOptions: FolderViewOptions

    init(settings: FolderViewSettings) {
        folderOptions = FolderViewOptions(settings: settings)
        let contentSize = NSSize(width: 410, height: 650)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: contentSize),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = String(localized: "View Options", comment: "Title of the window opened with Command-J")
        let host = NSHostingController(rootView: ViewOptionsView(folderOptions: folderOptions))
        // The panel owns its size; the scrollable Form has no useful intrinsic height.
        host.sizingOptions = []
        panel.contentViewController = host
        panel.setContentSize(contentSize)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        ThemeStyle.bind(panel)
        panel.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(for browser: BrowserViewController) { folderOptions.bind(browser); showWindow(nil) }
}

struct ViewOptionsView: View {
    let preferences: Prefs
    @ObservedObject private var folderOptions: FolderViewOptions
    @State private var options: IconViewOptions
    @State private var previews: Bool
    @State private var alternatingRows: Bool
    @State private var showNameExtensions: Bool
    @State private var hiddenColumns: Set<String>

    init(folderOptions: FolderViewOptions) {
        self.folderOptions = folderOptions
        let preferences = folderOptions.settings.preferences
        self.preferences = preferences
        _options = State(initialValue: preferences.iconViewOptions)
        _alternatingRows = State(initialValue: preferences.alternatingRows)
        _showNameExtensions = State(initialValue: preferences.showListNameExtensions)
        _previews = State(initialValue: preferences.showIconPreviews)
        _hiddenColumns = State(initialValue: preferences.hiddenListColumns)
    }

    var body: some View {
        Form {
            Section("Folder") {
                Text(folderOptions.folderName).lineLimit(1).truncationMode(.middle)
                Picker("View", selection: Binding(get: { folderOptions.presentation.mode }, set: folderOptions.chooseMode)) {
                    ForEach(BrowserViewMode.ordered, id: \.rawValue) { Text($0.title).tag($0) }
                }
                Picker("Sort By", selection: Binding(get: { folderOptions.presentation.sort.key }, set: folderOptions.chooseSort)) {
                    ForEach(SortKey.allCases, id: \.rawValue) { key in
                        Text(key == .name ? String(localized: "Name") : ListColumn(rawValue: key.rawValue)?.title ?? key.rawValue).tag(key)
                    }
                }
                Toggle(String(localized: "Ascending", comment: "Sort direction for the current folder"), isOn: Binding(get: { folderOptions.presentation.sort.ascending }, set: folderOptions.chooseAscending))
                HStack {
                    Button(String(localized: "Use as Defaults", comment: "Use this folder’s view, sort and icon size for folders without a saved choice"), action: folderOptions.useAsDefaults)
                    Button("Reset", action: folderOptions.reset)
                }
            }
            .disabled(!folderOptions.canEditFolder)
            Section("Icons") {
                Slider(value: Binding(get: { folderOptions.presentation.iconSize }, set: folderOptions.chooseIconSize), in: FolderPresentation.iconSizeRange) {
                    Text("Icon size")
                }
                .disabled(!folderOptions.canEditFolder)
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
                Toggle("Alternating row colors", isOn: Binding(get: { alternatingRows }, set: { alternatingRows = $0; preferences.alternatingRows = $0 }))
                Toggle("Show extensions in Name column", isOn: Binding(get: { showNameExtensions }, set: { showNameExtensions = $0; preferences.showListNameExtensions = $0 }))
                ForEach(ListColumn.allCases, id: \.self) { column in
                    Toggle(column.title, isOn: Binding(get: { !hiddenColumns.contains(column.rawValue) }, set: { shown in
                        if shown { hiddenColumns.remove(column.rawValue) } else { hiddenColumns.insert(column.rawValue) }
                        preferences.hiddenListColumns = hiddenColumns
                    }))
                }
            }
            Text(String(localized: "Other options apply to all windows.", comment: "View Options: folder view, sort and icon size are saved per folder; the remaining appearance options are shared")).font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .modifier(ThemedFormBackground())
        .onChange(of: options) { _, value in
            if value != preferences.iconViewOptions { preferences.iconViewOptions = value }
        }
        .onReceive(preferences.notifications.publisher(for: .viewOptionsChanged)) { _ in
            options = preferences.iconViewOptions
            folderOptions.refresh()
        }
        .onReceive(preferences.notifications.publisher(for: .appearanceChanged)) { _ in previews = preferences.showIconPreviews }
        .onReceive(preferences.notifications.publisher(for: .alternatingRowsChanged, object: preferences)) { _ in alternatingRows = preferences.alternatingRows }
        .onReceive(preferences.notifications.publisher(for: .listNamesChanged, object: preferences)) { _ in showNameExtensions = preferences.showListNameExtensions }
        .onReceive(preferences.notifications.publisher(for: .listColumnsChanged)) { _ in hiddenColumns = preferences.hiddenListColumns }
    }
}
