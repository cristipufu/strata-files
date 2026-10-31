import AppKit
import SwiftUI
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

extension ColorThemeTests {
    @Test func headerObserversDoNotRetainDiscardedMaterialsOrSections() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(palette: .teal), windows: [], highContrast: false)
        weak var discardedMaterial: NSVisualEffectView?
        autoreleasepool {
            let material = NSVisualEffectView()
            material.material = .titlebar
            material.blendingMode = .withinWindow
            discardedMaterial = material
            ThemeStyle.tintHeaderMaterial(material, withinWindow: true)
        }
        #expect(discardedMaterial == nil, "The theme’s weak-key map must not retain a view through KVO.")
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 52),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let tint = ToolbarBackdropTint()
        weak var discardedSection: NSView?
        autoreleasepool {
            let section = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 52))
            section.wantsLayer = true
            section.layer?.backgroundColor = NSColor.white.cgColor
            section.addSubview(NSVisualEffectView(frame: section.bounds))
            host.contentView?.addSubview(section)
            discardedSection = section
            tint.apply(in: host)
            section.removeFromSuperview()
        }
        #expect(discardedSection == nil, "The backing observer must not retain a discarded titlebar section.")
        tint.restore()
        #expect(!host.isVisible)
    }

    @Test func shortcutSearchKeepsTheNativeBezelAndFiltersWhileTypingOrClearing() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let field = try #require(ThemeTextField.makeField(search: true) as? NSSearchField)
        let native = NSSearchField()
        let cell = try #require(field.cell as? NSSearchFieldCell)
        var query = ""
        let coordinator = ThemeTextField.Coordinator(text: Binding(get: { query }, set: { query = $0 }))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            field.appearance = NSAppearance(named: appearance)
            for palette in ColorTheme.allCases {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                ThemeStyle.bind(field, to: .preview)
                #expect(field.bezelStyle == native.bezelStyle && field.isBezeled == native.isBezeled)
                #expect(field.isBordered == native.isBordered && field.focusRingType == native.focusRingType)
                #expect(cell.searchButtonCell != nil && cell.cancelButtonCell != nil)
                #expect(field.sendsSearchStringImmediately && !field.sendsWholeSearchString)
                for value in ["Rename", "⌘K", ""] {
                    field.stringValue = value
                    coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
                    #expect(query == value)
                }
            }
        }
    }

    @Test func inputThemingDoesNotLeaveAFieldBackgroundOnAnInlineRenameLabel() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = try #require(window.contentView)
        ThemeStyle.bind(window)
        for list in [NSTableView(), NSCollectionView()] as [NSView] {
            root.addSubview(list)
            let field = NSTextField(labelWithString: "unfinished name")
            list.addSubview(field)
            let original = field.backgroundColor
            field.isEditable = true
            field.drawsBackground = true
            ThemeStyle.apply(ColorThemeOptions(palette: .teal), windows: [window], highContrast: false)
            #expect(field.backgroundColor == original && field.stringValue == "unfinished name")
            field.isEditable = false
            field.drawsBackground = false
            ThemeStyle.apply(ColorThemeOptions(palette: .purple), windows: [window], highContrast: false)
            #expect(!field.drawsBackground && field.backgroundColor == original && !window.isVisible)
        }
    }

    @Test func nativeInputFillsDrawThePaletteInLightAndDark() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for palette in ColorTheme.allCases where palette != .system {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                for field in [NSTextField(), NSSecureTextField(), NSComboBox()] {
                    field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
                    field.bezelStyle = .roundedBezel
                    field.appearance = appearance
                    ThemeStyle.bind(field, to: .preview)
                    let actual = try chromePixel(field, at: NSPoint(x: 120, y: 12), appearance: appearance)
                    let expected = try chromeColorPixel(ThemeStyle.surface(.preview), appearance: appearance)
                    #expect(abs(actual.redComponent - expected.redComponent) < 0.04)
                    #expect(abs(actual.greenComponent - expected.greenComponent) < 0.04)
                    #expect(abs(actual.blueComponent - expected.blueComponent) < 0.04)
                }
            }
        }
    }

    @Test func settingsInputKeepsItsBindingAndDoesNotReplaceMarkedText() {
        var value = "original"
        let coordinator = ThemeTextField.Coordinator(text: Binding(get: { value }, set: { value = $0 }))
        let field = ComposingThemeField()
        field.stringValue = "typed text"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(value == "typed text")
        ThemeTextField.updateValue("external change", in: field)
        #expect(field.stringValue == "typed text", "Recoloring must preserve an active input-method composition.")
        field.editor.marked = false
        ThemeTextField.updateValue("external change", in: field)
        #expect(field.stringValue == "external change")
    }

    @Test func swiftUIInputBackgroundsFollowTheThemeAfterTheirNativeFieldsAreCreated() async throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        let host = NSHostingView(rootView: ThemeTextField("Example", text: .constant("draft"))
            .padding().modifier(ThemedFormBackground()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if !fields(host).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let field = try #require(fields(host).first { $0.isEditable })
        let original = field.backgroundColor
        for palette in [ColorTheme.purple, .teal, .system] {
            ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
            let expected = palette == .system ? original ?? .textBackgroundColor : ThemeStyle.surface(.preview)
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                if try chromeColorPixel(field.backgroundColor ?? .textBackgroundColor, appearance: window.effectiveAppearance)
                    == chromeColorPixel(expected, appearance: window.effectiveAppearance) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try chromeColorPixel(field.backgroundColor ?? .textBackgroundColor, appearance: window.effectiveAppearance)
                    == chromeColorPixel(expected, appearance: window.effectiveAppearance))
            #expect(field.stringValue == "draft" && !window.isVisible)
            if palette != .system { #expect(field.drawsBackground) }
        }
    }

    @Test func repeatedHeaderRefreshesDoNotReassignTheSameGlassTint() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let glass = CountingThemeGlass()
        glass.tintColor = .cyan
        glass.assignments = 0
        ThemeStyle.apply(ColorThemeOptions(palette: .purple), windows: [], highContrast: false)
        for _ in 0..<100 { ThemeStyle.tintHeaderMaterial(glass) }
        #expect(glass.assignments == 1, "Resizing should not repeatedly invalidate the same native material.")
        ThemeStyle.apply(ColorThemeOptions(palette: .green), windows: [], highContrast: false)
        ThemeStyle.tintHeaderMaterial(glass)
        #expect(glass.assignments == 2)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            glass.appearance = NSAppearance(named: appearance)
            ThemeStyle.tintHeaderMaterial(glass)
        }
        #expect(glass.assignments == 2, "The tint itself adapts to light and dark.")
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        ThemeStyle.tintHeaderMaterial(glass)
        #expect(glass.tintColor == .cyan && glass.assignments == 3)
        ThemeStyle.apply(ColorThemeOptions(palette: .green), windows: [], highContrast: false)
        ThemeStyle.tintHeaderMaterial(glass)
        #expect(glass.assignments == 4 && glass.tintColor != .cyan)
        ThemeStyle.restoreHeaderMaterial(glass)
        #expect(glass.tintColor == .cyan)
    }

    @Test func detachedToolbarMaterialsSampleTheThemeCanvasAndRestoreTheirNativeBlending() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let controller = ToolbarThemeController(window: owner)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 74),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let material = NSVisualEffectView(frame: try #require(host.contentView).bounds)
        material.material = .contentBackground
        material.blendingMode = .behindWindow
        let mask = NSImage(size: NSSize(width: 20, height: 20))
        material.maskImage = mask
        let button = NSButton(title: "Back", target: nil, action: nil)
        material.addSubview(button)
        host.contentView?.addSubview(material)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: name)
            for palette in ColorTheme.allCases where palette != .system {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                controller.refreshToolbarWindow(host)
                #expect(material.blendingMode == .withinWindow)
                #expect(material.maskImage === mask && material.subviews == [button])
                #expect(material.material == .titlebar && material.state == .followsWindowActiveState)
            }
        }
        for (options, contrast) in [(ColorThemeOptions(), false),
                                   (ColorThemeOptions(palette: .blue, tintsWindow: false), false),
                                   (ColorThemeOptions(palette: .blue), true)] {
            ThemeStyle.apply(options, windows: [], highContrast: contrast)
            controller.refreshToolbarWindow(host)
            #expect(material.blendingMode == .behindWindow && material.material == .contentBackground && material.maskImage === mask)
        }
        ThemeStyle.apply(ColorThemeOptions(palette: .blue), windows: [], highContrast: false)
        controller.refreshToolbarWindow(host)
        controller.refreshToolbarWindow(nil)
        #expect(material.blendingMode == .behindWindow && material.material == .contentBackground && !owner.isVisible && !host.isVisible)
    }

    @Test func inputColorsPreserveTextEditingAndRestoreTheOriginalBackgrounds() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = try #require(window.contentView)
        let field = NSTextField()
        field.bezelStyle = .roundedBezel
        let secure = NSSecureTextField()
        let combo = NSComboBox()
        let text = NSTextView()
        let transparent = NSTextField()
        transparent.drawsBackground = false
        transparent.isBezeled = false
        let editor = NSTextView()
        editor.isFieldEditor = true
        let label = NSTextField(labelWithString: "Label")
        for view in [field, secure, combo, text, transparent, editor, label] as [NSView] { root.addSubview(view) }
        field.stringValue = "unfinished name"
        secure.stringValue = "test fixture"
        combo.stringValue = "sftp://example.invalid"
        text.string = "selected paragraph"
        text.setSelectedRange(NSRange(location: 2, length: 5))
        let selection = text.selectedRange()
        let originals = [field.backgroundColor, secure.backgroundColor, combo.backgroundColor, text.backgroundColor]
        let originalBezel = (field.bezelStyle, field.isBezeled, field.isBordered, field.drawsBackground)
        let editorColor = editor.backgroundColor
        let transparentColor = transparent.backgroundColor
        ThemeStyle.bind(window)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: name)
            for palette in ColorTheme.allCases {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: false)
                let actual = [field.backgroundColor, secure.backgroundColor, combo.backgroundColor, text.backgroundColor]
                for (index, color) in actual.enumerated() {
                    let expected = palette == .system ? originals[index] ?? .textBackgroundColor : ThemeStyle.surface(.preview)
                    #expect(try chromeColorPixel(color ?? .textBackgroundColor, appearance: window.effectiveAppearance)
                            == chromeColorPixel(expected, appearance: window.effectiveAppearance))
                }
                #expect(field.stringValue == "unfinished name" && secure.stringValue == "test fixture")
                #expect(combo.stringValue == "sftp://example.invalid" && text.string == "selected paragraph")
                #expect(text.selectedRange() == selection && editor.backgroundColor == editorColor)
                #expect(!transparent.drawsBackground && transparent.backgroundColor == transparentColor)
                #expect(!label.isEditable && !window.isVisible)
            }
        }
        ThemeStyle.apply(ColorThemeOptions(palette: .purple), windows: [window], highContrast: true)
        #expect([field.backgroundColor, secure.backgroundColor, combo.backgroundColor, text.backgroundColor] == originals)
        #expect(field.bezelStyle == originalBezel.0 && field.isBezeled == originalBezel.1)
        #expect(field.isBordered == originalBezel.2 && field.drawsBackground == originalBezel.3)
        let unowned = NSWindow(contentRect: window.frame, styleMask: [.titled], backing: .buffered, defer: false)
        let externalField = NSTextField()
        unowned.contentView?.addSubview(externalField)
        let externalColor = externalField.backgroundColor
        ThemeStyle.apply(ColorThemeOptions(palette: .purple), windows: [unowned], highContrast: false)
        #expect(externalField.backgroundColor == externalColor)
    }
}

private final class CountingThemeGlass: NSGlassEffectView {
    var assignments = 0
    override var tintColor: NSColor? { didSet { assignments += 1 } }
}

private final class ComposingThemeField: NSTextField {
    let editor = ComposingThemeEditor()
    override func currentEditor() -> NSText? { editor }
}

private final class ComposingThemeEditor: NSTextView {
    var marked = true
    override func hasMarkedText() -> Bool { marked }
}
