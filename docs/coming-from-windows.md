# Coming from Windows

Settings ▸ General ▸ Coming from Windows collects opt-in File Explorer habits for people who come to Strata from
Windows. Each row is a setting of its own, off by default, so Strata behaves as before until you turn one on. The
rows are independent: turning on one never turns on another. Settings search finds each row by its name and by
words such as "explorer", "windows" and "pc".

| Row | What it does |
|---|---|
| Windows keyboard | The keys work as in File Explorer (below). |
| Explorer layout | A button, Use Explorer Layout, that sets up the List view as in File Explorer's Details view (below). |

## Windows keyboard

With Windows keyboard on, these keys act on the selection of the focused pane, in every view (List, Icons, Columns
and its deeper columns, Gallery, Disk Usage) and in both panes:

| Key | Action |
|---|---|
| Return (↩) | Opens the selection. |
| F2 | Renames the selection, through File ▸ Rename. Disk Usage can't rename in place, so F2 does nothing there. |
| Forward Delete (⌦, fn-⌫ on a Mac keyboard) | Moves the selection to the Trash, through File ▸ Move to Trash: the same checks, History and Undo. |
| Backspace (⌫) | Goes back in the focused pane's history. |

- While you type a filter, ⌫ still edits the filter. It goes back only once the filter is empty. In a deeper
  column, ⌫ leaves a filter in the first column as it is.
- ⌘⌫ still moves the selection to the Trash, and ⌘[ still goes back.
- F2 and ⌦ act only without ⌘, ⌥, ⌃ or ⇧. Keys typed into text (a name being edited, the path bar, search, a
  sheet) go to that text.
- The Return key picker above shows "Opens the selection" and is off while Windows keyboard is on. Its own choice
  comes back when you turn Windows keyboard off.
- The Keyboard Shortcuts window (⌘/) lists the four keys while the option is on, and the usual Return row
  ("Rename (or open — see Settings)") while it is off. An open Shortcuts window follows the setting at once. The ⌦
  row's tooltip says to press fn-⌫ on a Mac keyboard, so its caption fits in every language.

`PaneKeyAction.decide` makes the decision for each key; `WindowsKeyboardTests` covers it, the keys in every view
and both panes, and the Shortcuts window with the option on and off.

## Explorer layout

Use Explorer Layout is a button, not a setting that stays on: it changes ordinary settings once, and you can change
each of them again afterwards. Pressing it twice gives the same result. It applies to the windows of the Strata it's
pressed in, at once, without a restart:

- List becomes the default view. The default sort and icon size stay as they are.
- The list shows Name, Date Modified, Size and Kind, and hides every other column. The columns keep Strata's order,
  so Size comes before Kind.
- The folders open in a pane now lose the view you set up for them in View Options, so they show the new List at
  once. Folders you never set up already follow the defaults and get no saved view. Other folders you set up
  yourself keep their view; Strata doesn't go through every remembered folder.
- Every open window opens its Inspector, with the preview of the selection.

Search results, Recents and Duplicates keep their own view. `ExplorerLayout.plan` decides the defaults and the
hidden columns; `ExplorerLayoutTests` covers it, open windows and both panes of a Dual Pane window following at once,
the folders open now reset and others kept, another environment's windows left alone, and pressing twice.
