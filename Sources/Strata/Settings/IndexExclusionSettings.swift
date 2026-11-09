import AppKit
import SwiftUI

/// The folders not indexed as Settings shows them, kept in step with the index's preferences however the list changes.
@MainActor final class IndexExclusionList: ObservableObject {
    @Published private(set) var folders: [String]
    /// Why the folders of the latest Add Folder… weren't added.
    @Published private(set) var refused: [IndexExclusions.Refused] = []
    private let index: FileIndex
    private var observer: NSObjectProtocol?
    private var adding: Task<Void, Never>?

    init(index: FileIndex) {
        self.index = index
        folders = index.preferences?.indexExcludedFolders ?? []
        guard let preferences = index.preferences else { return }
        // Preferences post on the main actor, as the index's own observer relies on.
        observer = preferences.notifications.addObserver(forName: .indexExclusionsChanged, object: preferences,
                                                         queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    isolated deinit {
        adding?.cancel()
        if let observer { index.preferences?.notifications.removeObserver(observer) }
    }

    private func reload() {
        let current = index.preferences?.indexExcludedFolders ?? []
        if current != folders { folders = current }
    }

    /// Leaves `chosen` out of the index. Only the latest request shows its refusals; an earlier one still adds what it
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
        index.indexAgain(folder)
    }

    /// One message per refused folder, except that a full list is named once with a count: choosing many folders at
    /// once could otherwise show a thousand identical lines.
    nonisolated static func messages(for refused: [IndexExclusions.Refused]) -> [String] {
        let full = refused.filter { $0.reason == .full }.count
        guard full > 1 else { return refused.map(message(for:)) }
        return refused.filter { $0.reason != .full }.map(message(for:))
            + [String(localized: "\(full) folders weren’t added: the list is full. Remove a folder first.", comment: "plural")]
    }

    nonisolated static func message(for refused: IndexExclusions.Refused) -> String {
        let folder = refused.path
        switch refused.reason {
        case .indexRoot:
            return String(localized: "“\(folder)” is one of the folders the index covers. Leave out folders inside it instead.",
                          comment: "Settings ▸ Search & Index: a folder that can't be left out; placeholder: its path")
        case .holdsIndexRoot:
            return String(localized: "“\(folder)” holds your home folder or Applications, so it can’t be left out.",
                          comment: "Settings ▸ Search & Index: a folder that can't be left out; placeholder: its path")
        case .outsideIndex:
            return String(localized: "“\(folder)” isn’t in your home folder or Applications, so it isn’t indexed anyway.",
                          comment: "Settings ▸ Search & Index: a folder that can't be left out; placeholder: its path")
        case .alreadyLeftOut:
            return String(localized: "“\(folder)” is already left out, or is inside a folder that is.",
                          comment: "Settings ▸ Search & Index: a folder that can't be left out; placeholder: its path")
        case .full:
            return String(localized: "“\(folder)” wasn’t added: the list is full. Remove a folder first.",
                          comment: "Settings ▸ Search & Index: a folder that can't be left out; placeholder: its path")
        }
    }
}

/// Settings ▸ Search & Index ▸ Folders not indexed.
struct IndexExclusionSettings: View {
    @StateObject private var list: IndexExclusionList

    init(index: FileIndex) {
        _list = StateObject(wrappedValue: IndexExclusionList(index: index))
    }

    var body: some View {
        Section {
            if list.folders.isEmpty {
                Text("None").foregroundStyle(.secondary)
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
                Button("Add Folder…", action: chooseFolders).settingAnchor(.foldersNotIndexed)
            } label: {
                Text("Searches skip these folders and everything in them, and the index frees the memory they took. Removing a folder indexes it again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Folders not indexed", comment: "Settings ▸ Search & Index: folders the file index leaves out")
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
