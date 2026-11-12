import AppKit
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataModel

/// Coming from Windows ▸ Windows keyboard: Return opens, F2 renames, ⌦ moves to the Trash and ⌫ goes back, in every
/// view and pane, and nothing changes while it's off.
@MainActor struct WindowsKeyboardTests {
    private func context(typed: String = "", filtered: Bool? = nil, typesIntoFilter: Bool = true, returnOpens: Bool = false,
                         windows: Bool, renamesInPlace: Bool = true) -> PaneKeyAction.Context {
        PaneKeyAction.Context(typed: typed, filtered: filtered ?? !typed.isEmpty, typesIntoFilter: typesIntoFilter,
                              returnOpens: returnOpens, windowsKeyboard: windows, renamesInPlace: renamesInPlace)
    }

    @Test func offTheKeysDoWhatTheyDidBeforeAndF2AndForwardDeleteAreLeftToTheView() {
        let off = context(windows: false)
        #expect(PaneKeyAction.decide(.f2, off) == .none)
        #expect(PaneKeyAction.decide(.forwardDelete, off) == .none)
        #expect(PaneKeyAction.decide(.backspace, off) == .none)
        #expect(PaneKeyAction.decide(.returnKey, off) == .rename)
        #expect(PaneKeyAction.decide(.returnKey, context(returnOpens: true, windows: false)) == .open)
        #expect(PaneKeyAction.decide(.returnKey, context(typed: "a", windows: false)) == .open)
        #expect(PaneKeyAction.decide(.returnKey, context(windows: false, renamesInPlace: false)) == .open)
        #expect(PaneKeyAction.decide(.space, off) == .quickLook)
        #expect(PaneKeyAction.decide(.escape, off) == .none)
        #expect(PaneKeyAction.decide(.tab, off) == .tab)
        #expect(PaneKeyAction.decide(.type("a"), off) == .filter("a"))
    }

    @Test func onReturnOpensF2RenamesForwardDeleteTrashesAndBackspaceGoesBack() {
        let on = context(windows: true)
        #expect(PaneKeyAction.decide(.returnKey, on) == .open)
        #expect(PaneKeyAction.decide(.f2, on) == .command(#selector(BrowserViewController.renameSelection(_:))))
        #expect(PaneKeyAction.decide(.forwardDelete, on) == .command(#selector(BrowserViewController.moveToTrash(_:))))
        #expect(PaneKeyAction.decide(.backspace, on) == .back)
        // The rest stays as it was.
        #expect(PaneKeyAction.decide(.space, on) == .quickLook)
        #expect(PaneKeyAction.decide(.escape, on) == .none)
        #expect(PaneKeyAction.decide(.tab, on) == .tab)
        #expect(PaneKeyAction.decide(.type("a"), on) == .filter("a"))
    }

    @Test func forwardDeleteIsTheMenusMoveToTrashAndCommandBackspaceStaysItsShortcut() {
        #expect(PaneKeyAction.decide(.forwardDelete, context(windows: true)) == .command(StrataCommand.moveToTrash.action))
        #expect(PaneKeyAction.decide(.f2, context(windows: true)) == .command(StrataCommand.renameSelection.action))
        #expect(StrataCommand.moveToTrash.key == "\u{8}" && StrataCommand.moveToTrash.modifiers == .command)
        // A filter being typed doesn't change what ⌦ and F2 act on: the selection, as the menu's commands do.
        #expect(PaneKeyAction.decide(.forwardDelete, context(typed: "ab", windows: true)) == .command(StrataCommand.moveToTrash.action))
        #expect(PaneKeyAction.decide(.f2, context(typed: "ab", windows: true)) == .command(StrataCommand.renameSelection.action))
    }

    @Test func backspaceKeepsEditingAFilterAndAFilterInADeeperColumnStopsItGoingBack() {
        for windows in [false, true] {
            #expect(PaneKeyAction.decide(.backspace, context(typed: "ab", windows: windows)) == .filter("a"))
            #expect(PaneKeyAction.decide(.backspace, context(typed: "a", windows: windows)) == .filter(""))
            // A match still being worked out counts as typed, before the rows show it.
            #expect(PaneKeyAction.decide(.backspace, context(typed: "ab", filtered: false, windows: windows)) == .filter("a"))
            #expect(PaneKeyAction.decide(.backspace, context(typed: "ab", typesIntoFilter: false, windows: windows)) == .none)
            #expect(PaneKeyAction.decide(.escape, context(typed: "ab", windows: windows)) == .filter(""))
            #expect(PaneKeyAction.decide(.space, context(typed: "ab", windows: windows)) == .filter("ab "))
        }
        #expect(PaneKeyAction.decide(.backspace, context(typesIntoFilter: false, windows: true)) == .back)
        #expect(PaneKeyAction.decide(.backspace, context(typesIntoFilter: false, windows: false)) == .none)
    }

    @Test func returnOpensWithTheWindowsKeyboardWhateverReturnsOwnSettingSays() {
        for returnOpens in [false, true] {
            for typed in ["", "a"] {
                for renamesInPlace in [false, true] {
                    let on = context(typed: typed, returnOpens: returnOpens, windows: true, renamesInPlace: renamesInPlace)
                    #expect(PaneKeyAction.decide(.returnKey, on) == .open)
                }
            }
        }
    }

    @Test func onlyPlainF2ForwardDeleteAndBackspaceAreTheirKeys() throws {
        let forwardDelete = try function(NSDeleteFunctionKey), f2 = try function(NSF2FunctionKey)
        let cases: [(UInt16, String, NSEvent.ModifierFlags, FileViewKey?)] = [
            (KeyCode.forwardDelete, forwardDelete, [], .forwardDelete),
            (KeyCode.forwardDelete, forwardDelete, [.function], .forwardDelete),
            (KeyCode.forwardDelete, forwardDelete, [.function, .numericPad], .forwardDelete),
            (KeyCode.forwardDelete, forwardDelete, [.command], nil),
            (KeyCode.forwardDelete, forwardDelete, [.option], nil),
            (KeyCode.forwardDelete, forwardDelete, [.shift], nil),
            (KeyCode.forwardDelete, forwardDelete, [.control], nil),
            (KeyCode.f2, f2, [.function], .f2),
            (KeyCode.f2, f2, [], .f2),
            (KeyCode.f2, f2, [.shift, .function], nil),
            (KeyCode.f2, f2, [.command, .function], nil),
            (KeyCode.f2, f2, [.option, .function], nil),
            (KeyCode.delete, "\u{7f}", [], .backspace),
            (KeyCode.delete, "\u{7f}", [.shift], .backspace),
            (KeyCode.delete, "\u{7f}", [.command], nil),
            (KeyCode.delete, "\u{7f}", [.option], nil),
            (KeyCode.delete, "\u{7f}", [.control], nil),
        ]
        for (code, characters, modifiers, expected) in cases {
            #expect(FileViewKey.from(try event(code, characters, modifiers)) == expected, "\(code) \(modifiers)")
        }
    }

    // MARK: - Every view and both panes

    @Test(.timeLimit(.minutes(20)))
    func forwardDeleteTrashesOnlyTheFocusedPanesSelectionInEveryViewAndUndoPutsItBack() async throws {
        for mode in BrowserViewMode.ordered {
            for index in 0...1 {
                let base = index == 0 ? "left" : "right"
                let tree = try TestTree("left/a", "left/ab", "left/a.txt", "left/sub/a", "right/a", "right/ab", "right/a.txt", "right/sub/a")
                let state = try TestTree(), environment = try PreviewEnvironment(state)
                let owner = controller(tree, environment)
                let history = environment.services.transfers.history
                defer {
                    owner.window?.contentViewController = nil
                    owner.panes.forEach { $0.stopBackgroundWork() }
                    for entry in history.entries {
                        for pair in entry.moves where pair.from.hasPrefix(tree.root.path + "/") {
                            TestTree.removeFromTrash(URL(fileURLWithPath: pair.to), matching: entry.expectation(at: pair.to).key)
                        }
                    }
                }
                for pane in owner.panes { await pane.browser.directoryReads.task?.value }
                let pane = owner.panes[index], source = pane.browser, window = try #require(owner.window)
                source.setMode(mode, remember: false)
                // In Columns, the deeper column's own selection.
                let selected = tree.url(base + (mode == .columns ? "/sub/a" : "/a"))
                try await select(selected, in: source)
                window.makeFirstResponder(source.focusView)
                let before = tree.snapshot()

                environment.preferences.windowsKeyboard = false
                #expect(!source.handle(.forwardDelete), "\(mode), pane \(index)")
                #expect(source.commandWork == nil && history.entries.isEmpty && tree.snapshot() == before)

                environment.preferences.windowsKeyboard = true
                source.focusView.keyDown(with: try event(KeyCode.forwardDelete, try function(NSDeleteFunctionKey), [.function], window: window))
                while FileManager.default.fileExists(atPath: selected.path) || history.entries.isEmpty {
                    try await Task.sleep(for: .milliseconds(20))
                }
                let trashed = String(selected.path.dropFirst(tree.root.path.count + 1))
                #expect(tree.snapshot() == before.filter { $0 != trashed }, "\(mode), pane \(index)")
                let recorded = try #require(history.entries.last)
                #expect(recorded.moves.map { URL(fileURLWithPath: $0.from).lexicallyStandardized } == [selected.lexicallyStandardized])
                #expect(owner.panes[1 - index].browser.selectedURLs.isEmpty)
                try await history.undo(recorded, undoManager: nil)
                #expect(tree.snapshot() == before)
                withExtendedLifetime((environment, state)) {}
            }
        }
    }

    /// ⌦ is on and off with File ▸ Move to Trash: while another folder is read, the rows still showing are the previous
    /// folder's, and nothing of them goes.
    @Test(.timeLimit(.minutes(20)))
    func forwardDeleteTrashesNothingWhileAnotherFolderLoads() async throws {
        let tree = try TestTree("first/a", "first/ab", "second/a")
        let environment = try IndependentEnvironment()
        let history = environment.services.transfers.history
        defer {
            for entry in history.entries {
                for pair in entry.moves where pair.from.hasPrefix(tree.root.path + "/") {
                    TestTree.removeFromTrash(URL(fileURLWithPath: pair.to), matching: entry.expectation(at: pair.to).key)
                }
            }
        }
        environment.preferences.windowsKeyboard = true
        let browser = BrowserViewController(services: environment.services)
        defer { browser.stopBackgroundWork() }
        _ = browser.view
        browser.load(tree.url("first"))
        await browser.directoryReads.task?.value
        try await select(tree.url("first/a"), in: browser)
        let before = tree.snapshot()
        // Nothing is awaited until ⌦: the folder counts as loading from the call on, and the old rows stay only
        // briefly (0.15 s) before the loading state replaces them.
        browser.load(tree.url("second"))
        try #require(browser.isLoadingFolder && browser.selectedURLs.map { same($0, tree.url("first/a")) } == [true])
        #expect(!browser.handle(.forwardDelete))
        await browser.commandWork?.value
        #expect(history.entries.isEmpty && tree.snapshot() == before)
        withExtendedLifetime(environment) {}
    }

    @Test func backspaceGoesBackInTheFocusedPaneOnlyAfterEmptyingAFilterInEveryView() async throws {
        for mode in BrowserViewMode.ordered {
            for index in 0...1 {
                let base = index == 0 ? "left" : "right"
                let tree = try TestTree("left/sub/x.txt", "left/y.txt", "right/sub/x.txt", "right/y.txt")
                let state = try TestTree(), environment = try PreviewEnvironment(state)
                let owner = controller(tree, environment)
                defer { owner.window?.contentViewController = nil; owner.panes.forEach { $0.stopBackgroundWork() } }
                for pane in owner.panes { await pane.browser.directoryReads.task?.value }
                let pane = owner.panes[index], other = owner.panes[1 - index], source = pane.browser
                let window = try #require(owner.window)
                source.setMode(mode, remember: false)
                owner.go(.folder(tree.url(base + "/sub")), in: pane)
                await source.directoryReads.task?.value
                window.makeFirstResponder(source.focusView)
                let otherLocation = other.location
                let backspace = try event(KeyCode.delete, "\u{7f}", window: window)

                environment.preferences.windowsKeyboard = false
                #expect(!source.handle(.backspace))
                #expect(same(pane.location, tree.url(base + "/sub")))

                environment.preferences.windowsKeyboard = true
                source.setFilter("xt")
                source.focusView.keyDown(with: backspace)
                #expect(source.filter == "x" && same(pane.location, tree.url(base + "/sub")), "\(mode), pane \(index)")
                source.focusView.keyDown(with: backspace)
                #expect(source.filter == "" && same(pane.location, tree.url(base + "/sub")), "\(mode), pane \(index)")
                source.focusView.keyDown(with: backspace)
                await source.directoryReads.task?.value
                #expect(same(pane.location, tree.url(base)), "\(mode), pane \(index)")
                #expect(other.location == otherLocation)
                #expect(tree.snapshot() == ["left/", "left/sub/", "left/sub/x.txt", "left/y.txt", "right/", "right/sub/", "right/sub/x.txt", "right/y.txt"])
                withExtendedLifetime((environment, state)) {}
            }
        }
    }

    @Test(.timeLimit(.minutes(20)))
    func backspaceInADeeperColumnGoesBackUnlessTheFirstColumnHasAFilter() async throws {
        let tree = try TestTree("start/", "left/sub/x.txt", "left/sub/y.txt", "right/")
        let state = try TestTree(), environment = try PreviewEnvironment(state)
        let owner = BrowserWindowController(location: tree.url("start"), secondPane: tree.url("right"), services: environment.services)
        owner.window?.setFrameAutosaveName(""); owner.split.splitView.autosaveName = nil
        defer { owner.window?.contentViewController = nil; owner.panes.forEach { $0.stopBackgroundWork() } }
        for pane in owner.panes { await pane.browser.directoryReads.task?.value }
        environment.preferences.windowsKeyboard = true
        let pane = owner.panes[0], source = pane.browser, window = try #require(owner.window)
        owner.go(.folder(tree.url("left")), in: pane)
        await source.directoryReads.task?.value
        source.setMode(.columns, remember: false)
        // A filter typed in the first column: ⌫ from a deeper one leaves it, and the pane stays.
        source.setFilter("su")
        #expect(!source.fileView(source.columns, handleOutsideFilter: .backspace))
        #expect(source.filter == "su" && same(pane.location, tree.url("left")))
        source.setFilter("")

        try await select(tree.url("left/sub/x.txt"), in: source)
        window.makeFirstResponder(source.focusView)
        #expect(source.columns.activeDirectory.map { same($0, tree.url("left/sub")) } == true)
        source.focusView.keyDown(with: try event(KeyCode.delete, "\u{7f}", window: window))
        await source.directoryReads.task?.value
        #expect(same(pane.location, tree.url("start")))
        #expect(same(owner.panes[1].location, tree.url("right")))
        #expect(tree.snapshot() == ["left/", "left/sub/", "left/sub/x.txt", "left/sub/y.txt", "right/", "start/"])
        withExtendedLifetime((environment, state)) {}
    }

    @Test(.timeLimit(.minutes(20)))
    func f2StartsRenamingTheFocusedPanesSelectionInEveryViewThatRenamesInPlace() async throws {
        for mode in BrowserViewMode.ordered {
            for index in 0...1 {
                let base = index == 0 ? "left" : "right"
                let tree = try TestTree("left/a.txt", "left/ab.txt", "right/a.txt", "right/ab.txt")
                let state = try TestTree(), environment = try PreviewEnvironment(state)
                let owner = controller(tree, environment)
                defer { owner.window?.contentViewController = nil; owner.panes.forEach { $0.stopBackgroundWork() } }
                for pane in owner.panes { await pane.browser.directoryReads.task?.value }
                let source = owner.panes[index].browser, window = try #require(owner.window)
                source.setMode(mode, remember: false)
                try await select(tree.url(base + "/a.txt"), in: source)
                window.makeFirstResponder(source.focusView)
                let before = tree.snapshot()

                environment.preferences.windowsKeyboard = false
                #expect(!source.handle(.f2))
                #expect(!(window.firstResponder is NSText))

                environment.preferences.windowsKeyboard = true
                guard mode != .treemap else {
                    // Disk Usage can't rename in place, and File ▸ Rename is off there too.
                    #expect(!source.handle(.f2) && !(window.firstResponder is NSText))
                    continue
                }
                window.contentView?.layoutSubtreeIfNeeded()
                source.focusView.keyDown(with: try event(KeyCode.f2, try function(NSF2FunctionKey), [.function], window: window))
                let fields = renameFields(in: source.view)
                #expect(source.inlineRename.isEditing || fields.count == 1, "\(mode), pane \(index)")
                #expect(fields.allSatisfy { $0.stringValue == "a.txt" }, "\(mode), pane \(index)")
                #expect(renameFields(in: owner.panes[1 - index].browser.view).isEmpty && !owner.panes[1 - index].browser.inlineRename.isEditing)
                source.cancelPendingActions()
                window.makeFirstResponder(nil)
                #expect(tree.snapshot() == before)
                withExtendedLifetime((environment, state)) {}
            }
        }
    }

    // MARK: - The Shortcuts window

    private static let windowsRows = ["⌫ Back (Windows keyboard)", "↩ Open (Windows keyboard)", "F2 Rename (Windows keyboard)",
                                      "⌦ Move to Trash (Windows keyboard)"]
    private static let returnRow = "↩ Rename (or open — see Settings)"

    @Test func theShortcutsListHasTheWindowsKeysOnlyWhileTheOptionIsOnAndNothingElseChanges() {
        func rows(_ windows: Bool, in title: String? = nil) -> [String] {
            ShortcutsWindowController.sections(windowsKeyboard: windows).filter { title == nil || $0.title == title }.flatMap { section in
                section.items.map { ($0.keys + [String(localized: $0.action)]).joined(separator: " ") }
            }
        }
        let on = rows(true), off = rows(false)
        #expect(Self.windowsRows.allSatisfy(on.contains) && !on.contains(Self.returnRow))
        #expect(off.contains(Self.returnRow) && Self.windowsRows.allSatisfy { !off.contains($0) })
        #expect(off.allSatisfy { !$0.hasPrefix("F2 ") && !$0.hasPrefix("⌦ ") && !$0.hasPrefix("⌫ ") })
        #expect(on.filter { !Self.windowsRows.contains($0) } == off.filter { $0 != Self.returnRow })
        #expect(rows(true, in: "Go").contains("⌫ Back (Windows keyboard)"))
        #expect(Array(rows(true, in: "Files").prefix(3)) == Array(Self.windowsRows.dropFirst()))
        #expect(rows(false, in: "Files").first == Self.returnRow)
    }

    @Test func theShortcutsWindowFollowsItsOwnPreferencesWhileOpen() throws {
        let preferences = try Prefs.isolated(), other = try Prefs.isolated()
        let shortcuts = ShortcutsWindowController(preferences: preferences, restoresFrame: false)
        let window = try #require(shortcuts.window)
        defer { window.contentView = nil }
        let root = try #require(window.contentView)
        #expect(shownRows(root).contains(Self.returnRow))
        #expect(Self.windowsRows.allSatisfy { !shownRows(root).contains($0) })

        other.windowsKeyboard = true
        #expect(Self.windowsRows.allSatisfy { !shownRows(root).contains($0) })

        preferences.windowsKeyboard = true
        let on = shownRows(root)
        #expect(Self.windowsRows.allSatisfy(on.contains) && !on.contains(Self.returnRow))
        let search = try #require(root.subviews.compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "F2"
        shortcuts.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        #expect(shownRows(root) == ["F2 Rename (Windows keyboard)"])

        search.stringValue = ""
        shortcuts.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        preferences.windowsKeyboard = false
        #expect(shownRows(root).contains(Self.returnRow))
        #expect(Self.windowsRows.allSatisfy { !shownRows(root).contains($0) })
        #expect(!window.isVisible)
    }

    @Test func theTrashRowKeepsTheMacKeyInItsTooltipAndSearchFindsIt() throws {
        let preferences = try Prefs.isolated()
        preferences.windowsKeyboard = true
        let shortcuts = ShortcutsWindowController(preferences: preferences, restoresFrame: false)
        let window = try #require(shortcuts.window)
        defer { window.contentView = nil }
        let root = try #require(window.contentView)
        let row = try #require(rowViews(root).first { labels($0).contains("Move to Trash (Windows keyboard)") })
        #expect(row.toolTip == "On a Mac keyboard, press fn-⌫.")
        let search = try #require(root.subviews.compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "fn-⌫"
        shortcuts.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        #expect(shownRows(root) == ["⌦ Move to Trash (Windows keyboard)"])
    }

    /// Every language's Windows keyboard captions fit beside their keys, even with the window at its smallest.
    @Test func theWindowsKeyboardCaptionsFitInEveryLanguage() throws {
        let preferences = try Prefs.isolated()
        preferences.windowsKeyboard = true
        let shortcuts = ShortcutsWindowController(preferences: preferences, restoresFrame: false)
        let window = try #require(shortcuts.window)
        defer { window.contentView = nil }
        window.setContentSize(window.minSize)
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()
        let windowsActions = ShortcutsWindowController.sections(windowsKeyboard: true).flatMap(\.items)
            .filter { $0.keyboard == .windows }.map { String(localized: $0.action) }
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Localization")
        let languages = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(languages.count == 22)
        for action in windowsActions {
            let row = try #require(rowViews(root).first { labels($0).contains(action) }, "\(action)")
            let label = try #require(textFields(row).first { $0.stringValue == action })
            let keys = try #require(row.subviews.first { $0 is NSStackView })
            let room = keys.frame.minX - 12 - label.frame.minX
            #expect(room > 200, "\(action): \(room)")
            for language in languages {
                let file = try JSONSerialization.jsonObject(with: Data(contentsOf: language)) as? [String: Any]
                let caption = try #require((file?["strings"] as? [String: Any])?[action] as? String, "\(language.lastPathComponent) \(action)")
                let width = NSAttributedString(string: caption, attributes: [.font: try #require(label.font)]).size().width
                #expect(width <= room, "\(language.lastPathComponent): “\(caption)” needs \(width) of \(room)")
            }
        }
    }

    // MARK: - Helpers

    private func rowViews(_ root: NSView) -> [NSView] {
        func scrollViews(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews) }
        guard let content = scrollViews(root).first?.documentView?.subviews.first as? NSStackView else { return [] }
        return content.arrangedSubviews.filter { !($0 is NSTextField) }
    }

    private func textFields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(textFields) }

    private func labels(_ view: NSView) -> [String] { textFields(view).map(\.stringValue) }

    /// Each row of the Shortcuts window as its keycaps, then its action.
    private func shownRows(_ root: NSView) -> [String] {
        func scrollViews(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews) }
        func labels(_ view: NSView) -> [String] { (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels) }
        guard let content = scrollViews(root).first?.documentView?.subviews.first as? NSStackView else { return [] }
        return content.arrangedSubviews.filter { !($0 is NSTextField) }.map { row in
            let texts = labels(row)
            return (texts.dropFirst() + texts.prefix(1)).joined(separator: " ")
        }
    }

    private func controller(_ tree: TestTree, _ environment: PreviewEnvironment) -> BrowserWindowController {
        let controller = BrowserWindowController(location: tree.url("left"), secondPane: tree.url("right"), services: environment.services)
        controller.window?.setFrameAutosaveName("")
        controller.split.splitView.autosaveName = nil
        return controller
    }

    private func renameFields(in view: NSView) -> [InlineRenameField] {
        (view as? InlineRenameField).map { [$0] } ?? view.subviews.flatMap(renameFields)
    }

    /// The temporary folder has two spellings (/var and /private/var), and a pane can keep either.
    private func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.fileViewKey == b.standardizedFileURL.fileViewKey
    }

    /// No deadline, which a loaded machine can exceed: the calling test's time limit guards a hang.
    private func select(_ url: URL, in browser: BrowserViewController) async throws {
        browser.select([url], scroll: false)
        while browser.selectedURLs.map({ $0.standardizedFileURL.fileViewKey }) != [url.standardizedFileURL.fileViewKey] {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func function(_ key: Int) throws -> String {
        String(Character(try #require(UnicodeScalar(key))))
    }

    private func event(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = [],
                       window: NSWindow? = nil) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                      windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
}
