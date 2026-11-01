import Foundation
import StrataFiles
import StrataTheme

extension Notification.Name {
    /// Palette or window tint changed: redraw without reloading file views.
    static let colorThemeChanged = Notification.Name("StrataColorThemeChanged")
}

extension Prefs {
    var colorThemeOptions: ColorThemeOptions {
        get { ColorThemeOptions.read(from: defaults) }
        set {
            guard newValue != colorThemeOptions else { return }
            newValue.save(in: defaults)
            notifications.post(name: .colorThemeChanged, object: nil)
        }
    }
}
