import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

extension ColorThemeTests {
    @Test func inspectorTextHasReadableContrastAndCachedGitCountsFollowThemeChanges() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        let status = StatusItem(GitColors.untracked, "3 untracked")
        let ink = try #require(status.text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let originalSize = status.intrinsicContentSize
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for palette in ColorTheme.allCases where palette != .system {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                let background = try chromeColorPixel(ThemeStyle.surface(.inspector), appearance: appearance)
                for color in [ink, InspectorColors.primary, InspectorColors.secondary, InspectorColors.tertiary,
                              InspectorColors.error, InspectorColors.warning, InspectorColors.success,
                              InspectorColors.link, InspectorColors.accent, InspectorColors.conflict] {
                    let sample = InspectorInkSample(color: color)
                    let foreground = try chromePixel(sample, at: NSPoint(x: 4, y: 4), appearance: appearance)
                    #expect(inspectorContrast(foreground, background) >= 4.5, "\(palette) \(name.rawValue)")
                }
                #expect(status.text.string == "3 untracked" && status.intrinsicContentSize == originalSize)
            }
            for (options, contrast) in [(ColorThemeOptions(), false),
                                       (ColorThemeOptions(palette: .teal, tintsWindow: false), false),
                                       (ColorThemeOptions(palette: .teal), true)] {
                ThemeStyle.apply(options, windows: [], highContrast: contrast)
                #expect(try chromeColorPixel(ink, appearance: appearance)
                        == chromeColorPixel(.secondaryLabelColor, appearance: appearance))
                #expect(try chromeColorPixel(InspectorColors.tertiary, appearance: appearance)
                        == chromeColorPixel(.tertiaryLabelColor, appearance: appearance))
                for (themed, native) in [(InspectorColors.primary, NSColor.labelColor),
                                         (InspectorColors.error, NSColor.systemRed),
                                         (InspectorColors.warning, NSColor.systemOrange),
                                         (InspectorColors.success, NSColor.systemGreen),
                                         (InspectorColors.link, NSColor.linkColor),
                                         (InspectorColors.accent, NSColor.controlAccentColor),
                                         (InspectorColors.conflict, GitColors.conflicted)] {
                    #expect(try chromeColorPixel(themed, appearance: appearance)
                            == chromeColorPixel(native, appearance: appearance))
                }
            }
        }
    }

    @Test func scriptAndArtifactLabelsRecolorWithoutRebuildingCardsOrRunningActions() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let tree = try TestTree(".venv/")
        let view = ProjectInspectorView(files: FileCommands(transfers: .shared), git: GitStatusStore())
        var actions = 0
        view.onRunScript = { _ in actions += 1 }
        view.onClean = { _ in actions += 1 }
        view.configure(ProjectInfo(folder: tree.root, kinds: [.init(kind: .python, detail: "uv")],
                                   artifacts: [.init(name: ".venv", urls: [tree.root.appending(path: ".venv")],
                                                     kind: .python, role: .environment, bytes: 1024, files: 1)],
                                   scripts: [.init(name: "test", command: "python -m pytest", runner: .make,
                                                   directory: tree.root, source: "Makefile")], git: nil))
        func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
        let original = descendants(view)
        let command = try #require(original.compactMap { $0 as? NSTextField }.first { $0.stringValue == "python -m pytest" })
        let checkbox = try #require(original.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == ".venv" })
        let selection = checkbox.state
        for palette in [ColorTheme.teal, .purple, .system] {
            ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
            ThemeStyle.refresh(view)
            #expect(descendants(view) == original && checkbox.state == selection)
            #expect(command.textColor === InspectorColors.secondary && actions == 0)
        }
        #expect(tree.snapshot() == [".venv/"])
    }
}

private final class InspectorInkSample: NSView {
    let color: NSColor
    init(color: NSColor) { self.color = color; super.init(frame: NSRect(x: 0, y: 0, width: 8, height: 8)) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        ThemeStyle.surface(.inspector).setFill()
        bounds.fill()
        color.setFill()
        bounds.fill(using: .sourceOver)
    }
}

private func inspectorContrast(_ first: NSColor, _ second: NSColor) -> Double {
    func luminance(_ color: NSColor) -> Double {
        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
    }
    let a = luminance(first), b = luminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}
