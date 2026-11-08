import SwiftUI

/// Coming from Windows ▸ This Mac in the sidebar.
struct ThisMacSidebarSetting: View {
    let preferences: Prefs
    @State private var isOn: Bool

    init(preferences: Prefs) {
        self.preferences = preferences
        _isOn = State(initialValue: preferences.sidebarThisMac)
    }

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { isOn = $0; choose($0) })) {
            Text("This Mac in the sidebar")
            Text("A This Mac section, like This PC in File Explorer: Desktop, Documents, Downloads, Pictures, Music, Movies and your disks, which leave Locations. Favorites and Frequent stay where they are. Not in the Folders sidebar.")
        }
    }

    func choose(_ on: Bool) { preferences.sidebarThisMac = on }
}
