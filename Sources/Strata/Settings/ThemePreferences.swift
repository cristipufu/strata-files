import Foundation
import StrataFiles
import StrataTheme

extension Notification.Name {
    /// Palette or window tint changed: redraw without reloading file views.
    static let colorThemeChanged = Notification.Name("StrataColorThemeChanged")
}

extension Prefs {
    /// The theme chosen, among the bundled themes and `userThemes`.
    func colorThemeOptions(among userThemes: UserThemes) -> ColorThemeOptions {
        ColorThemeOptions.read(from: defaults, userThemes: userThemes)
    }

    /// Saves a choice other than the saved one, and tells windows and Settings.
    func choose(_ options: ColorThemeOptions, among userThemes: UserThemes) {
        guard !options.isSaved(in: defaults) else { return }
        options.save(in: defaults, userThemes: userThemes)
        notifications.post(name: .colorThemeChanged, object: nil)
    }

    /// Reads the folder of `userThemes`. When its themes are other than those known, the copy kept with the choice
    /// follows, and windows and Settings are told: there may be more to choose from, and the theme chosen may have
    /// changed or be gone. Whoever started the read may have left meanwhile: the others are told all the same.
    func readThemes(of userThemes: UserThemes) async {
        guard await userThemes.read() else { return }
        userThemes.keepFile(of: colorThemeOptions(among: userThemes).palette, in: defaults)
        notifications.post(name: .colorThemeChanged, object: nil)
    }
}
