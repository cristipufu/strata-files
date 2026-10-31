import AppKit
import Combine
import SwiftUI

/// ⌘, — the standard toolbar-tabbed settings window, each pane a SwiftUI form.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private let room: SettingsRoom

    init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let room = SettingsRoom()
        self.room = room
        func pane(_ title: String.LocalizationValue, _ symbol: String, _ view: some View) -> NSTabViewItem {
            let title = String(localized: title)
            // Each pane reports its own height, so the window resizes to fit it (like System Settings panes) instead of
            // leaving short panes floating; a longer pane scrolls (see `fitToScreen`). Its title names it.
            let host = NSHostingController(rootView: SettingsPaneView(room: room, content: view))
            host.sizingOptions = [.preferredContentSize]
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return item
        }
        tabs.addTabViewItem(pane("General", "gearshape", GeneralSettings()))
        tabs.addTabViewItem(pane("Search & Index", "magnifyingglass", IndexSettings()))
        tabs.addTabViewItem(pane("Terminal", "terminal", TerminalSettings()))
        tabs.addTabViewItem(pane("Appearance", "paintbrush", AppearanceSettings()))
        tabs.addTabViewItem(pane("Shortcuts", "keyboard", ShortcutSettings()))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        // Settings joins Strata’s full-screen Space instead of taking focus back to its old desktop.
        window.collectionBehavior = [.auxiliary, .moveToActiveSpace, .fullScreenAuxiliary, .fullScreenDisallowsTiling]
        window.tabbingMode = .disallowed
        window.title = String(localized: "General", comment: "Settings pane: general settings")
        super.init(window: window)
        window.delegate = self
        ThemeStyle.bind(window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        fitToScreen()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        fitToScreen()
    }

    /// The tallest a pane gets on a big screen: a settings window, not a page; a longer pane scrolls.
    private static let tallestPane: CGFloat = 520

    /// How tall a pane may be: `tallestPane`, or less when the screen the window is on has less room under the title
    /// and the tabs.
    private func fitToScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let chrome = window.frame.height - window.contentLayoutRect.height
        let height = max(240, min(Self.tallestPane, screen.visibleFrame.height - chrome))
        if room.height != height { room.height = height }
    }
}

/// The tallest a Settings pane may be (see `SettingsWindowController.fitToScreen`).
private final class SettingsRoom: ObservableObject {
    @Published var height: CGFloat = 520
}

/// A Settings pane: as tall as its form, up to `room`, scrolling past that.
private struct SettingsPaneView<Content: View>: View {
    @ObservedObject var room: SettingsRoom
    let content: Content

    var body: some View {
        ScrollView { content.frame(width: 520).fixedSize(horizontal: false, vertical: true) }
            .frame(width: 520)
            .frame(maxHeight: room.height)
            .modifier(ThemedFormBackground())
    }
}

/// Bridges a `Prefs` property into SwiftUI and refreshes when it changes.
private struct PrefToggle: View {
    let title: String.LocalizationValue
    let caption: String.LocalizationValue?
    let get: () -> Bool
    let set: (Bool) -> Void
    @State private var value = false

    var body: some View {
        Toggle(isOn: Binding(get: { value }, set: { value = $0; set($0) })) {
            Text(String(localized: title))
            if let caption { Text(String(localized: caption)) }
        }
        .onAppear { value = get() }
    }
}

private struct GeneralSettings: View {
    @State private var returnOpens = Prefs.shared.returnOpens
    @State private var isFileViewer = FileViewer.isStrata

    var body: some View {
        Form {
            LanguageSection()
            Section("Browsing") {
                PrefToggle(title: "Show hidden files", caption: "Also ⇧⌘. in any window.",
                           get: { Prefs.shared.showHidden }, set: { Prefs.shared.showHidden = $0 })
                PrefToggle(title: "Keep folders on top", caption: nil,
                           get: { Prefs.shared.foldersFirst }, set: { Prefs.shared.foldersFirst = $0 })
                PrefToggle(title: "Address bar in each pane",
                           caption: "In Dual Pane, each side has its own path bar instead of just the folder name.",
                           get: { Prefs.shared.dualPaneAddressBars }, set: { Prefs.shared.dualPaneAddressBars = $0 })
                PrefToggle(title: "Reopen windows from last time", caption: "Windows, tabs and panes come back when Strata starts.",
                           get: { Prefs.shared.reopenWindows }, set: { Prefs.shared.reopenWindows = $0 })
                PrefToggle(title: "Open archives like folders",
                           caption: "Opening a zip (or tar, 7z, rar…) shows what's inside; copy things out from there. Extract unpacks it.",
                           get: { Prefs.shared.openArchivesAsFolders }, set: { Prefs.shared.openArchivesAsFolders = $0 })
                Picker("Return key", selection: Binding(get: { returnOpens }, set: { returnOpens = $0; Prefs.shared.returnOpens = $0 })) {
                    Text("Renames the selection (like Finder)").tag(false)
                    Text("Opens the selection").tag(true)
                }
                NewWindowFolderSettings(preferences: .shared)
            }
            Section("New Files") {
                NewFileExtensionField()
            }
            UpdatesSection()
            Section("Copying") {
                PrefToggle(title: "Verify copies",
                           caption: "Reads every copied file back and compares it with the original. Slower, but catches failing disks and cables.",
                           get: { Prefs.shared.verifyCopies }, set: { Prefs.shared.verifyCopies = $0 })
            }
            Section("Dock") {
                PrefToggle(title: "Search box in the Dock",
                           caption: "A search box next to Strata in the Dock finds apps, files and folders as you type. Strata needs Accessibility access to place it, and keeps a few empty tiles in the Dock for it.",
                           get: { Prefs.shared.dockSearch }, set: { Prefs.shared.dockSearch = $0; DockSearch.shared.apply() })
            }
            Section {
                Toggle(isOn: Binding(get: { isFileViewer }, set: { isFileViewer = $0; FileViewer.setStrata($0) })) {
                    Text("Open “Reveal in Finder” in Strata")
                    Text("Apps that show files in Finder (Show in Finder, Reveal) open Strata instead. Applies to apps launched after the change.")
                }
            } header: {
                Text("Default File Browser")
            }
            Section("Command Line") {
                // The command's name, as typed: not translated.
                LabeledContent {
                    Button("Install…") { CommandLineTool.install() }
                } label: {
                    Text(verbatim: "strata")
                }
                Text("Then `strata .` opens the current folder in Strata, and `strata -s \"ext:pdf invoice\"` searches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .modifier(ThemedFormBackground())
    }
}

/// The extension File ▸ New File gives a file. Saved as you type, once it's one an extension can be.
private struct NewFileExtensionField: View {
    @State private var text = Prefs.shared.newFileExtension

    var body: some View {
        LabeledContent("Extension") {
            ThemeTextField(String(localized: "Extension"), text: Binding(get: { text }, set: { typed in
                text = typed
                if FileOps.newFileExtension(typed) != nil { Prefs.shared.newFileExtension = typed }
            }))
        }
        if let ext = FileOps.newFileExtension(text) {
            let name = FileOps.newFileName(extension: ext)
            Text(String(localized: "File ▸ New File makes an empty “\(name)”. Leave the extension empty for none.",
                        comment: "Settings caption; placeholder: the new file's name, like “untitled.txt”"))
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text("An extension can only have letters, numbers, “-”, “_” and “+”.")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }
}

private struct IndexSettings: View {
    @State private var status = ""
    @State private var hasAccess = Privacy.hasFullDiskAccess
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: status)
                LabeledContent(String(localized: "Covers", comment: "Settings ▸ Search & Index: which folders the index includes"),
                               value: String(localized: "Your home folder and Applications"))
                LabeledContent("Rebuild") {
                    Button("Rebuild Index") { FileIndex.shared.rebuild() }
                }
            } header: {
                Text("Index", comment: "Settings ▸ Search & Index: section about the file index")
            }
            Section {
                LabeledContent("Full Disk Access") {
                    if hasAccess {
                        Label(String(localized: "On", comment: "Settings: Full Disk Access is granted"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Open Privacy Settings…") { NSWorkspace.shared.open(Privacy.settingsURL) }
                    }
                }
                if !hasAccess {
                    Text("Without it, Desktop, Documents and Downloads are indexed only after you open them in Strata, and other apps’ data is skipped.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Access", comment: "Settings ▸ Search & Index: section about Full Disk Access")
            }
            Section("Search Syntax") {
                syntax("invoice 2026", "names containing all words")
                syntax("ext:pdf;png  or  *.pdf", "file extensions")
                syntax("kind:image|video|audio|doc|code|archive|app|folder", "kind of item")
                syntax("size:>100mb  size:1mb..1gb", "size")
                syntax("modified:today  modified:<7d  modified:2026", "date modified")
                syntax("in:~/Documents  in:github", "inside a folder (path or name)")
                syntax("github/acme  !draft  \"exact phrase\"", "folder/name, exclude a word, phrase")
            }
        }
        .formStyle(.grouped)
        .modifier(ThemedFormBackground())
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func syntax(_ example: String, _ meaning: String.LocalizationValue) -> some View {
        LabeledContent {
            Text(String(localized: meaning)).foregroundStyle(.secondary)
        } label: {
            Text(example).font(.system(.callout, design: .monospaced))
        }
    }

    private func refresh() {
        Privacy.refresh()
        hasAccess = Privacy.hasFullDiskAccess
        switch FileIndex.shared.phase {
        case .loading: status = String(localized: "Loading…")
        case .scanning(let items): status = String(localized: "Indexing… \(items) items so far", comment: "plural")
        case .ready: status = String(localized: "\(FileIndex.shared.itemCount) items · up to date", comment: "plural")
        }
    }
}

private struct TerminalSettings: View {
    @State private var selection = Prefs.shared.terminal ?? ""
    /// The terminals found installed; the one chosen is offered until that's read.
    @State private var installed: Set<String> = []

    var body: some View {
        Form {
            Picker("Open in Terminal uses", selection: Binding(get: { selection }, set: { selection = $0; Prefs.shared.terminal = $0.isEmpty ? nil : $0 })) {
                Text("Automatic").tag("")
                ForEach(Prefs.shared.terminals.filter { installed.contains($0.bundleID) || $0.bundleID == selection },
                        id: \.bundleID) { terminal in
                    Text(terminal.name).tag(terminal.bundleID)
                }
            }
            Text("Automatic picks the first installed of Ghostty, iTerm, Warp and Terminal. ⌃⌘T opens the current folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .modifier(ThemedFormBackground())
        .task { installed = await Prefs.installed(Prefs.shared.terminals.map(\.bundleID)) }
    }
}

/// The system-wide "file viewer" that `NSWorkspace.activateFileViewerSelecting` (Reveal in Finder) talks to.
enum FileViewer {
    private static let key = "NSFileViewer"

    static var isStrata: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? String == Bundle.main.bundleIdentifier
    }

    static func setStrata(_ on: Bool) {
        var global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        if on { global[key] = Bundle.main.bundleIdentifier } else { global.removeValue(forKey: key) }
        UserDefaults.standard.setPersistentDomain(global, forName: UserDefaults.globalDomain)
    }
}

/// Installs the `strata` command (shipped inside the app) by linking it into /usr/local/bin.
enum CommandLineTool {
    static func install() {
        let tool = Bundle.main.bundleURL.appending(path: "Contents/Helpers/strata").path
        let link = "/usr/local/bin/strata"
        // /usr/local/bin may not exist yet; the app's path is quoted for the shell ("'" becomes '\'').
        let quoted = "'" + tool.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "sudo mkdir -p /usr/local/bin && sudo ln -sf \(quoted) \(link)"
        let alert = NSAlert()
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == tool {
            alert.messageText = String(localized: "The strata command is already installed.")
        } else if !mayReplace(link) {
            alert.messageText = String(localized: "Another “strata” is installed.")
            alert.informativeText = String(localized: "/usr/local/bin/strata isn’t Strata’s command, so it was left as it is. Remove or rename it, then install again.")
        } else if FileManager.default.isWritableFile(atPath: "/usr/local/bin") {
            _ = unlink(link)
            do {
                try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: tool)
                alert.messageText = String(localized: "Installed the strata command.")
                alert.informativeText = String(localized: "Try “strata .” in a terminal.")
            } catch {
                alert.messageText = String(localized: "Couldn’t install the strata command.")
                alert.informativeText = error.localizedDescription
            }
        } else {
            alert.messageText = String(localized: "Install the strata command")
            alert.informativeText = String(localized: "/usr/local/bin isn’t writable without an administrator password. Run this in a terminal:\n\n\(command)",
                                           comment: "The last part is a shell command")
            alert.addButton(withTitle: String(localized: "Copy Command"))
            alert.addButton(withTitle: String(localized: "Close", comment: "Alert button: close this message"))
            if alert.runModal() == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            return
        }
        alert.runModal()
    }

    /// Whether what's at `link` may make way for the command: nothing, or a link to the command inside an app (an
    /// older or moved copy of Strata). Anything else belongs to someone else and is never removed.
    static func mayReplace(_ link: String) -> Bool {
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) {
            return target.hasSuffix(".app/Contents/Helpers/strata")
        }
        var info = stat()
        return lstat(link, &info) != 0 && errno == ENOENT
    }
}
