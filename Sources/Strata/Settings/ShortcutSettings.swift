import AppKit
import SwiftUI

/// Settings ▸ Shortcuts: every menu command with its shortcut. Click one and press the new keys; ⌫ removes it, esc
/// leaves it as it was. A shortcut another command has moves here (after asking).
struct ShortcutSettings: View {
    @State private var query = ""
    /// Bumped when shortcuts change, so the list redraws.
    @State private var version = 0

    private var groups: [(menu: String, commands: [ShortcutStore.Command])] {
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        var order: [String] = []
        var byMenu: [String: [ShortcutStore.Command]] = [:]
        for command in ShortcutStore.shared.commands {
            let shown = ShortcutStore.shared.combo(for: command.id).display.lowercased()
            guard words.isEmpty || command.title.lowercased().contains(words) || command.menu.lowercased().contains(words)
                    || shown.contains(words) else { continue }
            if byMenu[command.menu] == nil { order.append(command.menu) }
            byMenu[command.menu, default: []].append(command)
        }
        return order.map { ($0, byMenu[$0] ?? []) }
    }

    var body: some View {
        // Read so a change redraws the rows (each passes its shortcut down; the list keeps its scroll position).
        let _ = version
        VStack(alignment: .leading, spacing: 10) {
            ThemeTextField(String(localized: "Search commands or shortcuts"), text: $query, search: true)
            List {
                ForEach(groups, id: \.menu) { group in
                    Section(group.menu) {
                        ForEach(group.commands) { command in
                            ShortcutRowView(command: command, display: ShortcutStore.shared.combo(for: command.id).display,
                                            customized: ShortcutStore.shared.isCustomized(command.id))
                        }
                    }
                }
            }
            // The list scrolls itself; the pane stays inside the Settings window's height without a scroll of its own.
            .frame(height: 360)
            .modifier(ThemedFormBackground())
            HStack {
                Text("Click a shortcut, then press the keys. ⌫ removes it; esc keeps it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { ShortcutStore.shared.resetAll() }
                    .disabled(ShortcutStore.shared.overrides.isEmpty)
            }
        }
        .padding(20)
        .onReceive(NotificationCenter.default.publisher(for: .shortcutsChanged)) { _ in version += 1 }
    }
}

private struct ShortcutRowView: View {
    let command: ShortcutStore.Command
    /// The current shortcut, so the row redraws when it changes.
    let display: String
    let customized: Bool

    var body: some View {
        HStack {
            Text(command.title)
            Spacer()
            if customized {
                Button {
                    ShortcutChange.apply(command.defaultCombo, to: command.id, title: command.title, window: NSApp.keyWindow, reset: true)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .help(command.defaultCombo.display.isEmpty
                      ? String(localized: "Back to no shortcut", comment: "Help tag: restore a command’s built-in state, which has no shortcut")
                      : String(localized: "Back to \(command.defaultCombo.display)", comment: "Help tag: restore a command’s built-in shortcut (“Back to ⇧⌘G”)"))
                .accessibilityLabel("Restore the built-in shortcut")
            }
            ShortcutRecorder(id: command.id, title: command.title, display: display)
                .frame(width: 120, height: 22)
        }
    }
}

/// The shortcut field: shows the keys; click to record new ones.
private struct ShortcutRecorder: NSViewRepresentable {
    let id: String
    let title: String
    let display: String

    func makeNSView(context: Context) -> RecorderButton {
        RecorderButton(id: id, title: title)
    }

    func updateNSView(_ view: RecorderButton, context: Context) {
        view.refresh()
    }
}

final class RecorderButton: NSButton {
    private let id: String
    private let commandTitle: String
    private var monitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    init(id: String, title: String) {
        self.id = id
        commandTitle = title
        super.init(frame: .zero)
        bezelStyle = .push
        controlSize = .small
        target = self
        action = #selector(clicked)
        setAccessibilityLabel(String(localized: "Shortcut for \(title)", comment: "Accessibility: the shortcut field of a command"))
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        guard monitor == nil else { return }
        let display = ShortcutStore.shared.combo(for: id).display
        title = display.isEmpty ? String(localized: "None", comment: "Shortcut field: the command has no shortcut") : display
        contentTintColor = display.isEmpty ? .secondaryLabelColor : nil
        setAccessibilityValue(display.isEmpty ? String(localized: "No shortcut") : display)
    }

    @objc private func clicked() {
        monitor == nil ? start() : stop()
    }

    private func start() {
        title = String(localized: "Type shortcut…", comment: "Shortcut field while recording: press the new keys")
        window?.makeFirstResponder(self)
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: String(localized: "Type the new shortcut for \(commandTitle). Escape keeps it, Delete removes it.")])
        // Every key in this window goes here while recording, ⌘ combinations included (they mustn't run menu commands).
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            // A key meant for another window ends recording, and goes where it was meant to.
            guard event.window === window else {
                stop()
                return event
            }
            handle(event)
            return nil
        }
        // Settings going to the background (or closing) ends it too.
        if let window {
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.stop() }
                })
            }
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        refresh()
    }

    override func resignFirstResponder() -> Bool {
        stop()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stop() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case KeyCode.escape where flags.isEmpty: // esc: keep it
            return stop()
        case KeyCode.delete where flags.isEmpty, KeyCode.forwardDelete where flags.isEmpty: // ⌫ or ⌦: none
            ShortcutStore.shared.set(.cleared, for: id)
            return stop()
        default:
            break
        }
        guard let combo = Self.combo(from: event, flags: flags) else { return Sounds.beep() }
        guard combo.isUsable else {
            // A plain key would stop typing (the list filters as you type): ⌘ or ⌃ is needed, or a function key.
            Sounds.beep()
            title = String(localized: "Add ⌘ or ⌃", comment: "Shortcut field: the keys pressed need Command or Control too")
            return
        }
        stop()
        ShortcutChange.apply(combo, to: id, title: commandTitle, window: window, reset: false)
    }

    /// The key as a menu item takes it: letters lowercase (⇧ stays a modifier), other keys unshifted, ⌫ as the menu's
    /// backspace.
    private static func combo(from event: NSEvent, flags: NSEvent.ModifierFlags) -> ShortcutStore.Combo? {
        guard let base = event.charactersIgnoringModifiers, let scalar = base.unicodeScalars.first else { return nil }
        var key: String
        if Int(scalar.value) >= 0xF700 {
            key = base  // arrows, function keys, Home, End…
        } else if scalar.value == 0x7F {
            key = "\u{8}"
        } else if CharacterSet.letters.contains(scalar) {
            key = base.lowercased()
        } else {
            // A symbol typed with ⇧ is the symbol it makes ("+", not ⇧ and "="), as menus spell their shortcuts.
            key = base
            if flags.contains(.shift), let shifted = event.characters(byApplyingModifiers: [.shift]), shifted != event.characters(byApplyingModifiers: []) {
                key = shifted
                return ShortcutStore.Combo(key: key, modifiers: flags.subtracting(.shift).rawValue)
            }
        }
        guard !key.isEmpty else { return nil }
        if key == "\r" || key == "\u{3}" { key = "\r" }
        return ShortcutStore.Combo(key: key, modifiers: flags.rawValue)
    }
}

/// Giving a command a shortcut, or its own back: one another command has moves (after asking); one macOS keeps is
/// refused.
enum ShortcutChange {
    static func apply(_ combo: ShortcutStore.Combo, to id: String, title: String, window: NSWindow?, reset: Bool) {
        let store = ShortcutStore.shared
        if let system = store.systemConflict(for: combo) {
            let alert = NSAlert()
            alert.messageText = String(localized: "\(combo.display) belongs to “\(system)”.", comment: "A keyboard shortcut (“⌘H”), then a menu command of macOS")
            alert.informativeText = String(localized: "That shortcut can’t be changed here. Choose another one.")
            if let window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            return
        }
        guard let other = store.conflict(for: combo, except: id), let window else {
            reset ? store.reset(id) : store.set(combo, for: id)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "\(combo.display) is used by “\(other.title)”.", comment: "A keyboard shortcut (“⌘K”), then a menu command")
        alert.informativeText = String(localized: "Use it for “\(title)” instead? “\(other.title)” will have no shortcut.")
        alert.addButton(withTitle: String(localized: "Use Here", comment: "Alert button: give the shortcut to this command"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            reset ? store.reset(id) : store.set(combo, for: id)
        }
    }
}
