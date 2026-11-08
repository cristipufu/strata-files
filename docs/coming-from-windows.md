# Coming from Windows

Settings ▸ General ▸ Coming from Windows collects opt-in File Explorer habits for people who come to Strata from
Windows. Each row is a setting of its own, off by default, so Strata behaves as before until you turn one on. The
rows are independent: turning on one never turns on another. Settings search finds each row by its name and by
words such as "explorer", "windows" and "pc".

| Row | What it does |
|---|---|
| Windows keyboard | The keys work as in File Explorer (below). |

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
