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

Headless tests cover persistence, isolation, native item insert/remove notifications, palette previews, editor and
results gating, teardown, and Trash/History Undo across every view and both panes. The native customization sheet's
appearance still needs a visual check in a shown window; unshown tests verify control identity and command behavior.
