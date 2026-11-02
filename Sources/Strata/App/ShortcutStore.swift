import AppKit

/// Keyboard shortcuts you choose (Settings ▸ Shortcuts). Every menu command gets a stable id (its action, and its tag
/// when several commands share one), its built-in shortcut is remembered, and your choices are applied over the menu
/// at launch and whenever they change. The palette and the Shortcuts window show the live keys.
final class ShortcutStore {
    static let shared = ShortcutStore(preferences: Prefs.shared.defaults)
    private let preferences: UserDefaults

    init(preferences: UserDefaults) {
        self.preferences = preferences
    }

    /// A key and its modifiers, as a menu item takes them. An empty key means "no shortcut".
    struct Combo: Codable, Equatable, Hashable {
        var key: String
        var modifiers: UInt

        static let cleared = Combo(key: "", modifiers: 0)

        var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection([.command, .option, .control, .shift]) }

        /// "⇧⌘G", "⌥⌘K", "F5", "⌘↑"; "" for none.
        var display: String {
            guard !key.isEmpty else { return "" }
            var text = ""
            if flags.contains(.control) { text += "⌃" }
            if flags.contains(.option) { text += "⌥" }
            if flags.contains(.shift) { text += "⇧" }
            if flags.contains(.command) { text += "⌘" }
            return text + Self.keyName(key)
        }

        static func keyName(_ key: String) -> String {
            guard let scalar = key.unicodeScalars.first else { return "" }
            switch Int(scalar.value) {
            case NSUpArrowFunctionKey: return "↑"
            case NSDownArrowFunctionKey: return "↓"
            case NSLeftArrowFunctionKey: return "←"
            case NSRightArrowFunctionKey: return "→"
            case 0x8, 0x7F: return "⌫"
            case NSDeleteFunctionKey: return "⌦"
            case 0xD, 0x3: return "↩"
            case 0x9: return "⇥"
            // Key names as printed on keycaps and in the shortcut lists (and matched by `live`): not translated.
            case 0x1B: return "esc"
            case 0x20: return "Space"
            case NSHomeFunctionKey: return "↖"
            case NSEndFunctionKey: return "↘"
            case NSPageUpFunctionKey: return "⇞"
            case NSPageDownFunctionKey: return "⇟"
            case NSF1FunctionKey...NSF35FunctionKey: return "F\(Int(scalar.value) - NSF1FunctionKey + 1)"
            default: return key.uppercased()
            }
        }

        /// Whether it can be a menu shortcut without getting in the way of typing: ⌘ or ⌃ with a key, or a function key.
        var isUsable: Bool {
            guard let scalar = key.unicodeScalars.first else { return false }
            let isFunctionKey = (NSF1FunctionKey...NSF35FunctionKey).contains(Int(scalar.value))
            return isFunctionKey || flags.contains(.command) || flags.contains(.control)
        }
    }

    /// A command as Settings lists it.
    struct Command: Identifiable {
        let id: String
        let title: String
        /// The menu it's in ("File", "View ▸ Sort By").
        let menu: String
        let defaultCombo: Combo
    }

    private static let overridesKey = "shortcutOverrides"
    private(set) var commands: [Command] = []
    private var items: [String: NSMenuItem] = [:]
    private var defaults: [String: Combo] = [:]
    /// Hidden extra shortcuts (⌘= next to ⌘+), by the command they stand in for.
    private var aliasOf: [String: String] = [:]
    /// Option-alternates (Delete Immediately… under Move to Trash), by the command whose key they share plus ⌥.
    private var alternateOf: [String: String] = [:]
    /// Built-in shortcut (as shown) → the command's id, so text that names a shortcut can show its current one.
    private var idByDefaultDisplay: [String: String] = [:]

    var overrides: [String: Combo] {
        get {
            guard let data = preferences.data(forKey: Self.overridesKey) else { return [:] }
            return (try? JSONDecoder().decode([String: Combo].self, from: data)) ?? [:]
        }
        set {
            preferences.set(try? JSONEncoder().encode(newValue), forKey: Self.overridesKey)
            apply()
            NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
        }
    }

    /// Names every command in `menu`, remembers its built-in shortcut, and applies your choices.
    func install(_ menu: NSMenu) {
        // Built-in shortcuts seen before stay as they were (a menu installed again already carries your choices).
        let known = defaults
        commands = []
        items = [:]
        defaults = [:]
        aliasOf = [:]
        alternateOf = [:]
        idByDefaultDisplay = [:]
        var used: [String: Int] = [:]
        func walk(_ menu: NSMenu, path: [String]) {
            for item in menu.items {
                if let submenu = item.submenu {
                    // The app menu's Services and the Window list aren't commands of Strata's.
                    guard submenu !== NSApp.servicesMenu else { continue }
                    walk(submenu, path: path + [item.title])
                    continue
                }
                guard let action = item.action, !item.isSeparatorItem else { continue }
                // An explicit name (two commands sharing an action), else the action and its tag.
                var id = item.identifier?.rawValue ?? NSStringFromSelector(action) + (item.tag != 0 ? "#\(item.tag)" : "")
                let seen = used[id, default: 0]
                used[id] = seen + 1
                if seen > 0 { id += "~\(seen)" }
                item.identifier = NSUserInterfaceItemIdentifier(id)
                let built = item.keyEquivalent.isEmpty ? Combo.cleared
                    : Combo(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask.rawValue)
                let combo = known[id] ?? built
                items[id] = item
                defaults[id] = combo
                if !combo.key.isEmpty, idByDefaultDisplay[combo.display] == nil { idByDefaultDisplay[combo.display] = id }
                // Hidden aliases (⌘= for Bigger Icons) aren't listed, and neither are ⌥-alternates: they follow the
                // command they belong to.
                if item.isAlternate, let partner = commands.last {
                    alternateOf[id] = partner.id
                } else if !item.isHidden {
                    commands.append(Command(id: id, title: item.title, menu: path.joined(separator: " ▸ "), defaultCombo: combo))
                } else if let twin = commands.last(where: { $0.id.hasPrefix(NSStringFromSelector(action)) }) {
                    aliasOf[id] = twin.id
                }
            }
        }
        walk(menu, path: [])
        // Choices for commands that no longer exist go.
        let current = overrides
        let valid = current.filter { items[$0.key] != nil }
        if valid.count != current.count { preferences.set(try? JSONEncoder().encode(valid), forKey: Self.overridesKey) }
        apply()
    }

    /// Puts every command's current shortcut on its menu item.
    private func apply() {
        let chosen = overrides
        for (id, item) in items {
            // An alias goes quiet once its command has another shortcut (or another command took its keys).
            if let twin = aliasOf[id], chosen[twin] != nil {
                item.keyEquivalent = ""
                continue
            }
            // An alternate is its partner's shortcut with ⌥.
            if let partner = alternateOf[id] {
                let base = chosen[partner] ?? defaults[partner] ?? .cleared
                item.keyEquivalent = base.key
                item.keyEquivalentModifierMask = base.key.isEmpty ? [] : base.flags.union(.option)
                continue
            }
            let combo = chosen[id] ?? defaults[id] ?? .cleared
            item.keyEquivalent = combo.key
            item.keyEquivalentModifierMask = combo.flags
        }
    }

    /// The actual menu keys include aliases and Option-alternates, which follow their partner's customized keys.
    func display(for id: String, fallback: Combo) -> String {
        guard let item = items[id] else { return fallback.display }
        return Combo(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask.rawValue).display
    }

    func combo(for id: String) -> Combo {
        overrides[id] ?? defaults[id] ?? .cleared
    }

    func isCustomized(_ id: String) -> Bool {
        overrides[id] != nil
    }

    /// The listed command that already uses `combo`, other than `id` (a hidden alias or ⌥-alternate counts as its
    /// command).
    func conflict(for combo: Combo, except id: String) -> Command? {
        guard !combo.key.isEmpty else { return nil }
        for (other, item) in items where other != id && item.keyEquivalent == combo.key
            && item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == combo.flags {
            let owner = aliasOf[other] ?? alternateOf[other] ?? other
            if owner != id, let command = commands.first(where: { $0.id == owner }) { return command }
        }
        return nil
    }

    /// A shortcut that can't be taken: one macOS puts in the menus itself (Show All Tabs, Emoji & Symbols…), or an
    /// ⌥-alternate's (Delete Immediately…, which follows Move to Trash).
    func systemConflict(for combo: Combo) -> String? {
        guard !combo.key.isEmpty, let menu = NSApp.mainMenu else { return nil }
        let alternates = Set(alternateOf.keys.compactMap { items[$0] }.map(ObjectIdentifier.init))
        let ours = Set(items.values.map(ObjectIdentifier.init)).subtracting(alternates)
        func search(_ menu: NSMenu) -> String? {
            for item in menu.items {
                if let submenu = item.submenu, let found = search(submenu) { return found }
                if !ours.contains(ObjectIdentifier(item)), item.keyEquivalent == combo.key,
                   item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == combo.flags {
                    return item.title
                }
            }
            return nil
        }
        return search(menu)
    }

    /// Sets `id`'s shortcut (`.cleared` removes it); a command that had it loses it (an alias goes quiet).
    func set(_ combo: Combo, for id: String) {
        var chosen = overrides
        if !combo.key.isEmpty {
            for (other, item) in items where other != id && item.keyEquivalent == combo.key
                && item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == combo.flags {
                if alternateOf[other] == nil { chosen[other] = .cleared }
            }
        }
        chosen[id] = combo == defaults[id] ? nil : combo
        // A command losing its shortcut to another keeps "none" only while it differs from its default.
        overrides = chosen.filter { $0.value != defaults[$0.key] }
    }

    /// Back to the built-in shortcut; a command that has it now loses it.
    func reset(_ id: String) {
        set(defaults[id] ?? .cleared, for: id)
    }

    func resetAll() {
        overrides = [:]
    }

    /// A built-in shortcut as currently set: "⇧⌘G" → what you changed it to ("" when removed). Text that isn't a
    /// command's built-in shortcut ("Space", "a–z") comes back as it is.
    func live(_ builtIn: String) -> String {
        guard let id = idByDefaultDisplay[builtIn] else { return builtIn }
        return combo(for: id).display
    }
}

extension Notification.Name {
    static let shortcutsChanged = Notification.Name("StrataShortcutsChanged")
}
