import SwiftUI

/// Coming from Windows ▸ Tabs above the address bar.
struct TabsLayoutSetting: View {
    let preferences: Prefs
    @State private var isOn: Bool

    init(preferences: Prefs) {
        self.preferences = preferences
        _isOn = State(initialValue: preferences.explorerTabs)
    }

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { isOn = $0; choose($0) })) {
            Text("Tabs above the address bar")
            Text("Tabs sit at the top of the window, with an address bar under them as in File Explorer: Back, Forward, Up, the path, search and Transfers. The toolbar is hidden; its commands stay in the menus and their shortcuts.")
        }
    }

    func choose(_ on: Bool) { preferences.explorerTabs = on }
}
