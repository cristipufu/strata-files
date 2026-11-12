# Customize Toolbar

Choose View → Customize Toolbar, or use the toolbar's native context menu. Drag commands in, out or into another
order. New Folder, New File, Move to Trash, Copy To, Move To, Sync, Connect, Open in Terminal, Quick Look, Reload
and Command Palette are optional. Sync opens Compare with Other Pane so you can review differences before syncing.
The default set is unchanged; dragging the default set from the native palette restores it.
Reload appears only when added through customization, and is disabled in search results, Recents and Duplicates.

AppKit owns buttons, overflow, labels, spacing and the customization palette. Layout and display mode persist in
`Prefs` through observable public toolbar properties, with native automatic saving disabled. Toolbar identifiers
include the preferences domain, so independent browser environments do not share layouts or write the application's
defaults. Unknown saved items and duplicate controls are discarded; repeated spacers and an empty toolbar are valid.

Optional commands reuse `StrataCommand` and the palette's owner/validator. Dispatch revalidates the actual item,
window and native editor before using the active pane; existing browser commands capture their own selections and
retain the queue's History and providers. Removed items and customization-palette samples cannot perform commands.
Palette previews never replace the live controls. Keyboard Search and Go to Folder restore their controls when
needed, so removing a button cannot disable its keyboard command.

With Settings ▸ General ▸ Coming from Windows ▸ Tabs above the address bar on, the toolbar is hidden, not removed:
its items and saved layout stay as they are, and an address row above the files takes over Back, Forward, Up, the
window's path bar, search and Transfers (see docs/coming-from-windows.md). The path bar's toolbar item keeps a
stand-in view meanwhile, since AppKit can't lay out an item whose view was taken away. Customize Toolbar is off in
this layout, and ⌘L and ⌘F use the row instead of revealing the toolbar. Turning the option off puts the path bar
back in its item and shows the toolbar again if it was shown.

Headless tests cover persistence, isolation, native item insert/remove notifications, palette previews, editor and
results gating, teardown, and Trash/History Undo across every view and both panes. The native customization sheet's
appearance still needs a visual check in a shown window; unshown tests verify control identity and command behavior.
