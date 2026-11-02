import AppKit

/// ⌘/ and the sidebar's footer button: every shortcut, grouped and searchable.
final class ShortcutsWindowController: NSWindowController, NSSearchFieldDelegate {
    static let shared = ShortcutsWindowController()

    private struct Shortcut {
        let keys: [String]
        let action: String.LocalizationValue
    }

    private static let sections: [(title: String, items: [Shortcut])] = [
        (String(localized: "Go", comment: "Keyboard shortcuts section: getting around"), [
            Shortcut(keys: ["⌘", "K"], action: "Command palette: jump anywhere, run any command"),
            Shortcut(keys: ["⌘", "L"], action: "Type a path (Tab completes)"),
            Shortcut(keys: ["⇧", "⌘", "G"], action: "Go to folder"),
            Shortcut(keys: ["⌘", "["], action: "Back"),
            Shortcut(keys: ["⌘", "]"], action: "Forward"),
            Shortcut(keys: ["⌘", "↑"], action: "Enclosing folder"),
            Shortcut(keys: ["⌘", "↓"], action: "Open selection"),
            Shortcut(keys: ["⇧", "⌘", "F"], action: "Recents"),
            Shortcut(keys: ["⇧", "⌘", "H"], action: "Home"),
            Shortcut(keys: ["⇧", "⌘", "D"], action: "Desktop"),
            Shortcut(keys: ["⇧", "⌘", "O"], action: "Documents"),
            Shortcut(keys: ["⌥", "⌘", "L"], action: "Downloads"),
            Shortcut(keys: ["⇧", "⌘", "A"], action: "Applications"),
            Shortcut(keys: ["⌥", "⌘", "K"], action: "Connect to a server (SMB, AFP, NFS, WebDAV)"),
        ]),
        (String(localized: "Find", comment: "Keyboard shortcuts section: filtering and searching"), [
            Shortcut(keys: ["a–z"], action: "Type in the list to filter this folder (fuzzy)"),
            Shortcut(keys: ["↩"], action: "While filtering: open the top match"),
            Shortcut(keys: ["esc"], action: "Clear the filter"),
            Shortcut(keys: ["⌘", "F"], action: "Search your home folder and Applications (instant)"),
            Shortcut(keys: ["ext:pdf"], action: "Search by extension (also *.pdf)"),
            Shortcut(keys: ["kind:image"], action: "image, video, audio, doc, code, archive, app, folder"),
            Shortcut(keys: ["size:>1gb"], action: "By size (also size:1mb..1gb)"),
            Shortcut(keys: ["modified:<7d"], action: "By date (today, yesterday, 2026, >30d)"),
            Shortcut(keys: ["in:github"], action: "Inside a folder (name or ~/path)"),
            Shortcut(keys: ["github/acme"], action: "Folder, then name (also in ⌘K)"),
            Shortcut(keys: ["regex:^IMG_\\d+"], action: "Names matching a regular expression"),
            Shortcut(keys: ["case:"], action: "Match case exactly (also Match Case under the toolbar)"),
            Shortcut(keys: ["tag:Red"], action: "Finder tags (via Spotlight)"),
            Shortcut(keys: ["camera:iphone"], action: "Photo metadata: also width:>1920, height:<1000 (via Spotlight)"),
            Shortcut(keys: ["duration:>10m"], action: "Video and audio length; pages:>20 for PDFs (via Spotlight)"),
            Shortcut(keys: ["author:ana"], action: "Document author; artist: for music (via Spotlight)"),
        ]),
        (String(localized: "Files", comment: "Keyboard shortcuts section: working with files"), [
            Shortcut(keys: ["↩"], action: "Rename (or open — see Settings)"),
            Shortcut(keys: ["space"], action: "Quick Look (also ⌘Y)"),
            Shortcut(keys: ["⌘", "O"], action: "Open"),
            Shortcut(keys: ["⇧", "⌘", "N"], action: "New folder"),
            Shortcut(keys: ["⌥", "⌘", "N"], action: "New file (empty; its extension is in Settings)"),
            Shortcut(keys: ["⌘", "D"], action: "Duplicate"),
            Shortcut(keys: ["⌘", "⌫"], action: "Move to Trash (in the Trash: Put Back)"),
            Shortcut(keys: ["⌥", "⌘", "⌫"], action: "Delete immediately, skipping the Trash"),
            Shortcut(keys: ["⇧", "⌘", "⌫"], action: "Empty Trash"),
            Shortcut(keys: ["⌘", "C"], action: "Copy"),
            Shortcut(keys: ["⌘", "X"], action: "Cut (the next paste moves)"),
            Shortcut(keys: ["⌘", "V"], action: "Paste"),
            Shortcut(keys: ["⌥", "⌘", "V"], action: "Move copied items here"),
            Shortcut(keys: ["⌥", "⌘", "C"], action: "Copy path"),
            Shortcut(keys: ["⌘", "Z"], action: "Undo"),
            Shortcut(keys: ["⇧", "⌘", "Z"], action: "Redo"),
            Shortcut(keys: ["⌥", "⌘", "Z"], action: "History: undo past operations, even after quitting"),
            Shortcut(keys: ["⌥", "⌘", "A"], action: "Ask Strata: describe a bulk change"),
            Shortcut(keys: ["⌃", "⌘", "T"], action: "Open in Terminal"),
            Shortcut(keys: ["⌘", "E"], action: "Eject"),
            Shortcut(keys: ["⌥", "drag"], action: "Copy instead of move"),
        ]),
        (String(localized: "View", comment: "Keyboard shortcuts section: how the list looks"), [
            Shortcut(keys: ["⌘", "1"], action: "Icons"),
            Shortcut(keys: ["⌘", "2"], action: "List"),
            Shortcut(keys: ["⌘", "3"], action: "Columns"),
            Shortcut(keys: ["⌘", "4"], action: "Gallery"),
            Shortcut(keys: ["⌘", "5"], action: "Disk usage"),
            Shortcut(keys: ["⌘", "+"], action: "Bigger icons"),
            Shortcut(keys: ["⌘", "−"], action: "Smaller icons"),
            Shortcut(keys: ["⌃", "⌥", "⌘", "1"], action: "Sort by name (2 kind, 5 date modified, 7 size)"),
            Shortcut(keys: ["⇧", "⌘", "."], action: "Show or hide hidden files"),
            Shortcut(keys: ["⌘", "I"], action: "Inspector"),
            Shortcut(keys: ["⌃", "⌘", "S"], action: "Sidebar"),
            Shortcut(keys: ["⌘", "R"], action: "Reload (and recount sizes)"),
            Shortcut(keys: ["⌃", "⌘", "F"], action: "Full screen"),
        ]),
        (String(localized: "Panes, Tabs & Windows", comment: "Keyboard shortcuts section"), [
            Shortcut(keys: ["⌘", "\\"], action: "Dual pane on or off"),
            Shortcut(keys: ["tab"], action: "In dual pane: switch pane (also ⌥⌘\\)"),
            Shortcut(keys: ["F5"], action: "Copy selection to the other pane"),
            Shortcut(keys: ["F6"], action: "Move selection to the other pane"),
            Shortcut(keys: ["⌘", "T"], action: "New tab"),
            Shortcut(keys: ["⌃", "tab"], action: "Next tab"),
            Shortcut(keys: ["⌘", "N"], action: "New window"),
            Shortcut(keys: ["⌘", "W"], action: "Close window or tab"),
            Shortcut(keys: ["⌥", "⌘", "S"], action: "Shelf: gather files from anywhere"),
            Shortcut(keys: ["⌘", ","], action: "Settings"),
            Shortcut(keys: ["⌘", "/"], action: "This list"),
        ]),
    ]

    private let search = NSSearchField()
    private let content = NSStackView()

    init(restoresFrame: Bool = true) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: true)
        panel.title = String(localized: "Keyboard Shortcuts")
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = false
        panel.minSize = NSSize(width: 460, height: 360)
        super.init(window: panel)

        search.placeholderString = String(localized: "Search shortcuts")
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.edgeInsets = NSEdgeInsets(top: 4, left: 22, bottom: 22, right: 22)
        content.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = document

        let effect = NSVisualEffectView()
        effect.material = .windowBackground
        ThemeStyle.bind(effect, to: .content)
        effect.addSubview(search)
        effect.addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: effect.safeAreaLayoutGuide.topAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 22),
            search.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -22),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        panel.contentView = effect
        ThemeStyle.bind(panel)
        if restoresFrame { panel.setFrameAutosaveName("StrataShortcuts") }
        rebuild(filter: "")
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsChanged), name: .shortcutsChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func shortcutsChanged() {
        rebuild(filter: search.stringValue)
    }

    /// A shortcut's keys as currently set (Settings ▸ Shortcuts may have changed a menu command's): "—" when removed.
    private static func liveKeys(_ keys: [String]) -> [String] {
        // Shown with a typographic minus ("⌘−"); menus spell it "-".
        let builtIn = keys.joined().replacingOccurrences(of: "−", with: "-")
        let current = ShortcutStore.shared.live(builtIn)
        guard current != builtIn else { return keys }
        guard !current.isEmpty else { return ["—"] }
        let modifiers = current.prefix { "⌃⌥⇧⌘".contains($0) }
        return modifiers.map(String.init) + [String(current.dropFirst(modifiers.count))]
    }

    func show() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeFirstResponder(search)
    }

    func controlTextDidChange(_ notification: Notification) {
        rebuild(filter: search.stringValue)
    }

    private func rebuild(filter: String) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        for section in Self.sections {
            let all = section.items.map { (keys: $0.keys, action: String(localized: $0.action)) }
            let items = query.isEmpty ? all : all.filter {
                $0.action.lowercased().contains(query) || $0.keys.joined(separator: " ").lowercased().contains(query)
                    || section.title.lowercased().contains(query)
            }
            guard !items.isEmpty else { continue }
            let title = NSTextField(labelWithString: section.title)
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            content.addArrangedSubview(title)
            content.setCustomSpacing(8, after: title)
            if content.arrangedSubviews.count > 1, let previous = content.arrangedSubviews.dropLast().last {
                content.setCustomSpacing(22, after: previous)
            }
            for item in items {
                let row = ShortcutRow(keys: Self.liveKeys(item.keys), action: item.action)
                content.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -44).isActive = true
            }
        }
        if content.arrangedSubviews.isEmpty {
            let none = NSTextField(labelWithString: String(localized: "No shortcuts match “\(filter)”."))
            none.textColor = .secondaryLabelColor
            content.addArrangedSubview(none)
        }
    }
}

/// "Action ………… ⌘ K" with each key drawn as a keycap.
private final class ShortcutRow: NSView {
    init(keys: [String], action: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: action)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let caps = NSStackView(views: keys.map(Keycap.init))
        caps.spacing = 3
        caps.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [label, caps] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: caps.leadingAnchor, constant: -12),
            caps.trailingAnchor.constraint(equalTo: trailingAnchor),
            caps.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private final class Keycap: NSView {
    private let label: NSTextField

    init(_ key: String) {
        label = NSTextField(labelWithString: key)
        super.init(frame: .zero)
        let symbolic = key.count == 1 || key.hasPrefix("F") && key.count <= 3
        label.font = symbolic ? .systemFont(ofSize: 12, weight: .medium) : .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }
}

/// The sidebar's footer: a quiet button that opens the shortcuts list.
final class SidebarFooterController: NSSplitViewItemAccessoryViewController {
    override func loadView() {
        let button = NSButton(title: String(localized: "Keyboard Shortcuts"), image: NSImage(systemSymbolName: "command", accessibilityDescription: nil) ?? NSImage(),
                              target: nil, action: #selector(AppDelegate.showShortcuts(_:)))
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.contentTintColor = .secondaryLabelColor
        button.font = .systemFont(ofSize: 12)
        button.toolTip = String(localized: "Every shortcut in Strata (⌘/)")
        button.translatesAutoresizingMaskIntoConstraints = false
        let container = ThemeAccessoryView(role: .sidebar)
        container.addSubview(button)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 36),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
    }
}
