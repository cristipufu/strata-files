import Combine
import Foundation
import StrataFiles
import StrataTheme

/// The color themes to choose from and the one chosen, as they are now. Settings ▸ Appearance shows them whenever
/// it shows: the themes folder may be read, or a theme chosen, while another pane is in front.
@MainActor final class ThemeChoices: ObservableObject {
    @Published private(set) var palettes: [ColorTheme]
    @Published private(set) var chosen: ColorThemeOptions
    private let preferences: Prefs
    private let userThemes: UserThemes
    private var observation: (any NSObjectProtocol)?

    init(preferences: Prefs, userThemes: UserThemes) {
        self.preferences = preferences
        self.userThemes = userThemes
        palettes = ColorTheme.choices(with: userThemes)
        chosen = preferences.colorThemeOptions(among: userThemes)
        observation = preferences.notifications.addObserver(forName: .colorThemeChanged, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.showWhatIsNow() }
        }
    }

    isolated deinit {
        if let observation { preferences.notifications.removeObserver(observation) }
    }

    func choose(_ palette: ColorTheme) {
        preferences.choose(ColorThemeOptions(palette: palette, tintsWindow: chosen.tintsWindow), among: userThemes)
    }

    /// The system's colors take no tint, and are also what a chosen theme whose file is gone is shown as: saving a
    /// tint then would save the system's as the choice.
    func tintWindow(_ tintsWindow: Bool) {
        guard chosen.palette != .system else { return }
        preferences.choose(ColorThemeOptions(palette: chosen.palette, tintsWindow: tintsWindow), among: userThemes)
    }

    private func showWhatIsNow() {
        let palettes = ColorTheme.choices(with: userThemes), chosen = preferences.colorThemeOptions(among: userThemes)
        if self.palettes != palettes { self.palettes = palettes }
        if self.chosen != chosen { self.chosen = chosen }
    }
}
