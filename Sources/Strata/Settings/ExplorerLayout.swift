import SwiftUI

extension Notification.Name {
    static let explorerLayoutApplied = Self("StrataExplorerLayoutApplied")
}

/// Coming from Windows ▸ Use Explorer Layout: applied once, not a mode, so each part stays an ordinary setting.
enum ExplorerLayout {
    struct Plan: Equatable {
        let defaults: FolderPresentation
        let hiddenColumns: Set<String>
    }

    static let shownColumns: Set<ListColumn> = [.modified, .kind, .size]

    static func plan(from current: FolderPresentation) -> Plan {
        var defaults = current
        defaults.mode = .list
        return Plan(defaults: defaults,
                    hiddenColumns: Set(ListColumn.allCases.filter { !shownColumns.contains($0) }.map(\.rawValue)))
    }

    /// Open windows of these preferences reset the folders they show and open their Inspector when it's posted.
    static func apply(to folderViews: FolderViewSettings) {
        let plan = plan(from: folderViews.defaults), preferences = folderViews.preferences
        preferences.hiddenListColumns = plan.hiddenColumns
        folderViews.useAsDefaults(plan.defaults)
        preferences.notifications.post(name: .explorerLayoutApplied, object: preferences)
    }
}

struct ExplorerLayoutSettings: View {
    let preferences: Prefs

    var body: some View {
        LabeledContent {
            Button("Use Explorer Layout", action: use)
        } label: {
            Text("Explorer layout")
            Text("List view with Date Modified, Kind and Size, and the Inspector open, in every window. The folders open now use it too; other folders you set up yourself keep their view.")
        }
    }

    func use() { ExplorerLayout.apply(to: FolderViewSettings(preferences: preferences)) }
}
