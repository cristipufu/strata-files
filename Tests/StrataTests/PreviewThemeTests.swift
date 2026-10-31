import AppKit
import Testing
@testable import Strata
@testable import StrataFiles

extension ColorThemeTests {
    @Test func spacePreviewUsesTheExistingPaletteAndTypographyWithoutReplacingItsContent() async throws {
        let saved = ThemeStyle.options, savedContrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: savedContrast) }
        let tree = try TestTree("folder/readme.md")
        try Data("# Heading\n\nKeep this selection.\n".utf8).write(to: tree.url("folder/readme.md"))
        let environment = try PreviewEnvironment(tree)
        environment.preferences.nameTextSize = 15
        let before = tree.snapshot()
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        let coordinator = environment.services.previews
        coordinator.show(try #require(FileEntry(url: tree.url("folder"))), from: browser, present: false)
        let window = try #require(coordinator.panel)
        let password = PreviewPasswordPrompt.makeAlert("fixture.zip")
        let passwordField = try #require(password.accessoryView as? NSSecureTextField)
        passwordField.stringValue = "keep this input"
        let content = try #require(coordinator.content)
        await content.session.task?.value
        window.contentView?.layoutSubtreeIfNeeded()
        content.outline.selectRowIndexes([0], byExtendingSelection: false)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let rich = try #require(descendants(content.fileView).compactMap { $0 as? PreviewView }.first)
        let deadline = ContinuousClock.now + .seconds(20)
        while rich.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!rich.isLoading)
        let text = try #require(descendants(rich).compactMap { $0 as? NSTextView }.first)
        let storage = try #require(text.textStorage)
        text.setSelectedRange(NSRange(location: 0, length: min(3, storage.length)))
        let selectedText = text.selectedRange(), selectedItem = content.session.selected
        let cell = try #require(content.outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NameCellView)
        let backdrop = try #require(content.fileView.subviews.compactMap { $0 as? ThemeSurfaceView }.first)
        let controlsBackdrop = try #require(content.controls.subviews.compactMap { $0 as? ThemeSurfaceView }.first)
        let searchBezel = content.controls.search.isBezeled
        #expect(cell.textField?.font?.pointSize == 15)
        #expect(content.outline.rowHeight == FileViewStyle.listHeight(for: environment.preferences))
        try #require(backdrop.bounds.width > 0 && backdrop.bounds.height > 0)
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            window.appearance = appearance
            password.window.appearance = appearance
            for highContrast in [false, true] {
                for palette in ColorTheme.allCases {
                    ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window, password.window], highContrast: highContrast)
                    cell.backgroundStyle = .emphasized
                    let labelColor = try #require(cell.textField?.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
                    #expect(try chromeColorPixel(labelColor, appearance: appearance)
                            == chromeColorPixel(ThemeStyle.selectedText, appearance: appearance))
                    if ThemeStyle.colorsSurfaces {
                        #expect(try chromePixel(backdrop, at: NSPoint(x: 4, y: 4), appearance: appearance)
                                == chromeColorPixel(ThemeStyle.surface(.preview), appearance: appearance))
                        #expect(try chromePixel(controlsBackdrop, at: NSPoint(x: 4, y: 4), appearance: appearance)
                                == chromeColorPixel(ThemeStyle.surface(.content), appearance: appearance))
                    }
                    #expect(password.accessoryView === passwordField && passwordField.stringValue == "keep this input")
                    #expect(passwordField.isBezeled && !password.window.isVisible)
                    #expect(content.controls.search.isBezeled == searchBezel)
                    #expect(content.session.selected === selectedItem && content.outline.selectedRow == 0)
                    #expect(text.textStorage === storage && text.selectedRange() == selectedText)
                    #expect(descendants(content.fileView).contains { $0 === rich })
                    #expect(!window.isVisible)
                }
            }
        }
        environment.preferences.nameTextSize = 16
        let updatedCell = try #require(content.outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NameCellView)
        #expect(updatedCell.textField?.font?.pointSize == 16)
        #expect(content.session.selected === selectedItem && content.outline.selectedRow == 0)
        #expect(text.textStorage === storage && text.selectedRange() == selectedText)
        coordinator.close()
        #expect(tree.snapshot() == before)
        withExtendedLifetime(environment) {}
    }
}
