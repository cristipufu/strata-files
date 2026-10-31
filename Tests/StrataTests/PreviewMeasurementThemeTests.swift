import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

extension ColorThemeTests {
    @Test func folderMeasurementsKeepTheirNativeControlsAndResultAcrossEveryPalette() async throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let tree = try TestTree("folder/file")
        let environment = try PreviewEnvironment(tree)
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        let before = tree.snapshot(), coordinator = environment.services.previews
        coordinator.show(try #require(FileEntry(url: tree.url("folder"))), from: browser, present: false)
        let window = try #require(coordinator.panel), content = try #require(coordinator.content)
        await content.session.task?.value
        content.measureButton.performClick(nil)
        await content.measurement.task?.value
        let result = try #require(content.measurement.result), text = content.measurement.text
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            window.appearance = appearance
            for highContrast in [false, true] {
                for palette in ColorTheme.allCases {
                    ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: highContrast)
                    #expect(content.measurement.result?.logical == result.logical && content.measurement.result?.allocated == result.allocated)
                    #expect(content.measurement.text == text && content.measurement.task == nil)
                    #expect(!content.measureButton.isHidden && content.measureButton.isEnabled)
                    #expect(content.measureButton.controlSize == .small && content.measureButton.superview != nil)
                    #expect(!window.isVisible)
                }
            }
        }
        coordinator.close()
        #expect(tree.snapshot() == before)
        withExtendedLifetime(environment) {}
    }
}
