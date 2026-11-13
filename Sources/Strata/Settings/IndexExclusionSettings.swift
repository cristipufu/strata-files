import AppKit
import SwiftUI

/// The excluded folders as Settings shows them, kept in step with the index's preferences however the list changes.
@MainActor final class IndexExclusionList: ObservableObject {
    @Published private(set) var folders: [String]
    /// Why the folders of the latest Add Folder… weren't added.
    @Published private(set) var refused: [IndexExclusions.Refused] = []
    private let index: FileIndex
    private var observer: NSObjectProtocol?
    private var adding: Task<Void, Never>?

    init(index: FileIndex) {
        self.index = index
        let preferences = index.preferences
        folders = preferences.indexExcludedFolders
        // Preferences post on the main actor, as the index's own observer relies on.
        observer = preferences.notifications.addObserver(forName: .indexExclusionsChanged, object: preferences,
                                                         queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    isolated deinit {
        adding?.cancel()
        if let observer { index.preferences.notifications.removeObserver(observer) }
    }

    private func reload() {
        let current = index.preferences.indexExcludedFolders
        if current != folders { folders = current }
    }

    /// Excludes `chosen` from the index. Only the latest request shows its refusals; an earlier one still adds what it
    /// could, since those folders were chosen too.
    @discardableResult func add(_ chosen: [URL]) -> Task<Void, Never> {
        adding?.cancel()
        let task = Task { [weak self, index] in
            let refused = await index.exclude(chosen)
            guard !Task.isCancelled, let self else { return }
            self.refused = refused
        }
        adding = task
        return task
    }

    func remove(_ folder: String) {
        adding?.cancel()
        adding = nil
        refused = []
        index.include(folder)
    }

    /// How many refused folders are named one by one. Choosing a folder's whole contents at once can refuse thousands.
    nonisolated static let namedRefusals = 5

    /// One message per refused folder, as far as `namedRefusals`, with the rest counted. A full list is named once
    /// with its own count, since every folder past it is refused for that.
    nonisolated static func messages(for refused: [IndexExclusions.Refused]) -> [String] {
        let full = refused.filter { $0.reason == .full }
        let others = full.count > 1 ? refused.filter { $0.reason != .full } : refused
        var messages = others.prefix(namedRefusals).map(message(for:))
        let more = others.count - namedRefusals
        if more > 0 {
            messages.append(String(localized: "\(more) more folders weren’t added.", comment: "plural"))
        }
        if full.count > 1 {
            messages.append(String(localized: "\(full.count) folders weren’t added: the list is full. Remove a folder first.",
                                   comment: "plural"))
        }
        return messages
    }

    nonisolated static func message(for refused: IndexExclusions.Refused) -> String {
        let folder = refused.path
        switch refused.reason {
        case .indexRoot:
            return String(localized: "“\(folder)” is one of the folders the index covers. Exclude folders inside it instead.",
                          comment: "Settings ▸ Search & Index: a folder that can't be excluded; placeholder: its path")
        case .holdsIndexRoot:
            return String(localized: "“\(folder)” holds your home folder or Applications, so it can’t be excluded.",
                          comment: "Settings ▸ Search & Index: a folder that can't be excluded; placeholder: its path")
        case .outsideIndex:
            return String(localized: "“\(folder)” isn’t in your home folder or Applications, so it isn’t indexed anyway.",
                          comment: "Settings ▸ Search & Index: a folder that can't be excluded; placeholder: its path")
        case .alreadyExcluded:
            return String(localized: "“\(folder)” is already excluded, or is inside a folder that is.",
                          comment: "Settings ▸ Search & Index: a folder that can't be excluded; placeholder: its path")
        case .full:
            return String(localized: "“\(folder)” wasn’t added: the list is full. Remove a folder first.",
                          comment: "Settings ▸ Search & Index: a folder that can't be excluded; placeholder: its path")
        }
    }
}

/// Settings ▸ Search & Index ▸ Excluded folders.
struct IndexExclusionSettings: View {
    @StateObject private var list: IndexExclusionList

    init(index: FileIndex) {
        _list = StateObject(wrappedValue: IndexExclusionList(index: index))
    }

    var body: some View {
        Section {
            if list.folders.isEmpty {
                Text("No Folders").foregroundStyle(.secondary)
            }
            ForEach(list.folders, id: \.self) { folder in
                LabeledContent {
                    Button("Remove") { list.remove(folder) }
                } label: {
                    Text(verbatim: folder).lineLimit(1).truncationMode(.middle).help(folder)
                }
            }
            ForEach(Array(IndexExclusionList.messages(for: list.refused).enumerated()), id: \.offset) { _, message in
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.callout)
            }
            LabeledContent {
                Button("Add Folder…", action: chooseFolders).settingAnchor(.excludedFolders)
            } label: {
                Text("The index skips these folders and everything in them: searches by name and folder sizes leave them out, and their memory is freed. Removing a folder indexes it again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Excluded folders", comment: "Settings ▸ Search & Index: folders the file index leaves out")
        }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.begin { [list] response in
            guard response == .OK else { return }
            list.add(panel.urls)
        }
    }
}
