import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

extension ColorThemeTests {
    @Test func commandPaletteThemesItsContentWithoutChangingQuerySelectionOrActions() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        let palette = CommandPalette()
        var actions: [String] = []
        let icon = NSImage(size: NSSize(width: 20, height: 20))
        palette.prepare(items: [
            PaletteItem(title: "Alpha", subtitle: "First", icon: icon, kind: .action, run: { actions.append("Alpha") }),
            PaletteItem(title: "Beta", subtitle: "Second", icon: icon, kind: .action, run: { actions.append("Beta") }),
        ])
        let root = try #require(palette.panel.contentView as? ShadowedGlass)
        let content = try #require(root.glass.contentView)
        let canvas = try #require(content.subviews.compactMap { $0 as? ThemeSurfaceView }.first)
        let field = try #require(commandThemeDescendants(content).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        let table = try #require(commandThemeDescendants(content).compactMap { $0 as? NSTableView }.first)
        table.selectRowIndexes([1], byExtendingSelection: false)
        field.stringValue = "unfinished query"
        let originalChildren = root.subviews
        let radius = root.glass.cornerRadius
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            palette.panel.appearance = NSAppearance(named: name)
            for color in ColorTheme.allCases {
                ThemeStyle.apply(ColorThemeOptions(palette: color), windows: [palette.panel], highContrast: false)
                #expect(canvas.isHidden == (color == .system))
                #expect(table.selectedRow == 1 && table.numberOfRows == 2 && field.stringValue == "unfinished query")
                #expect(actions.isEmpty && !palette.isVisible)
                #expect(root.subviews == originalChildren && root.glass.cornerRadius == radius)
                #expect(palette.panel.backgroundColor == .clear && !palette.panel.isOpaque)
                #expect(!field.drawsBackground && table.refusesFirstResponder)
                let row = try #require(palette.tableView(table, rowViewForRow: 0))
                #expect(row is PaletteRowView)
                let cell = try #require(palette.tableView(table, viewFor: table.tableColumns.first, row: 0) as? PaletteCell)
                #expect(cell.usesTheme)
            }
        }
        // These are the field delegate's normal key commands, without ordering the panel or posting events.
        field.stringValue = "Beta"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        let editor = NSTextView()
        #expect(palette.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(table.numberOfRows == 1)
        #expect(palette.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(actions == ["Beta"] && !palette.isVisible)
        #expect(!PaletteCell().usesTheme, "Shared Dock results keep their own native glass styling.")
    }

    @Test func askStrataThemesEveryPhaseWithoutChangingThePromptOrPlan() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let tree = try TestTree("original.txt")
        let controller = PlanSheetController(urls: [tree.url("original.txt")], baseFolder: tree.root, undoManager: nil, files: FileCommands(transfers: .shared))
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: PlanSheetController.size),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { window.contentViewController = nil }
        ThemeStyle.bind(window)
        let step = PlanStep(id: 1, kind: .rename, source: tree.url("original.txt"), destination: tree.url("renamed.txt"), isEnabled: false)
        let plan = Plan(instruction: "rename", source: .rules, interpretation: "Rename", baseFolder: tree.root,
                        steps: [step], excluded: [], unaffected: 0)
        let phases: [PlanSheetController.Phase] = [.prompt, .planning, .review(plan), .failed("Example", suggestions: [])]
        for phase in phases {
            controller.show(phase, items: [], instruction: "unfinished instruction")
            let descendants = commandThemeDescendants(controller.view)
            let field = try #require(descendants.compactMap { $0 as? NSTextField }.first { $0.isEditable })
            let well = try #require(descendants.compactMap { $0 as? WellView }.first)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: name)
                for palette in ColorTheme.allCases {
                    ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: false)
                    well.updateLayer()
                    #expect(field.stringValue == "unfinished instruction")
                    if case .review(let unchanged) = controller.phase { #expect(unchanged.steps == [step]) }
                    let color = try #require(well.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
                    #expect(try chromeColorPixel(color, appearance: window.effectiveAppearance)
                            == chromeColorPixel(ThemeStyle.surface(.content), appearance: window.effectiveAppearance))
                    #expect(!window.isVisible)
                }
            }
        }
        #expect(tree.snapshot() == ["original.txt"])
    }
}

private func commandThemeDescendants(_ root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(commandThemeDescendants)
}
