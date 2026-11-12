import AppKit

/// What a key pressed in one of a pane's file views does there. Keys typed into text (a name being edited, the path
/// bar, the search field, a sheet) never get here: the text field has the keyboard.
enum PaneKeyAction: Equatable {
    /// The filter becomes this text.
    case filter(String)
    case open
    case rename
    case quickLook
    /// A menu command, checked and sent the way its menu item is.
    case command(Selector)
    case back
    case tab
    /// Not the pane's: the view handles the key as usual.
    case none

    struct Context {
        /// What was typed to filter the rows by, including a match still being worked out.
        var typed: String
        /// The rows show a filter.
        var filtered: Bool
        /// False in a deeper column, where typing selects by name instead of filtering the pane's folder.
        var typesIntoFilter: Bool
        var returnOpens: Bool
        var windowsKeyboard: Bool
        /// Disk Usage can't rename in place.
        var renamesInPlace: Bool
    }

    static func decide(_ key: FileViewKey, _ context: Context) -> PaneKeyAction {
        let typed = context.typed
        switch key {
        case .type(let text):
            return .filter(typed + text)
        case .backspace:
            if !typed.isEmpty { return context.typesIntoFilter ? .filter(String(typed.dropLast())) : .none }
            return context.windowsKeyboard ? .back : .none
        case .escape:
            return typed.isEmpty ? .none : .filter("")
        case .returnKey:
            let opens = context.filtered || context.returnOpens || context.windowsKeyboard || !context.renamesInPlace
            return opens ? .open : .rename
        case .space:
            return typed.isEmpty ? .quickLook : .filter(typed + " ")
        case .tab:
            return .tab
        case .f2:
            return context.windowsKeyboard ? .command(StrataCommand.renameSelection.action) : .none
        case .forwardDelete:
            return context.windowsKeyboard ? .command(StrataCommand.moveToTrash.action) : .none
        }
    }
}
