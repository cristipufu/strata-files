# Customize Toolbar

Choose View → Customize Toolbar, or use the toolbar's native context menu. Drag commands in, out or into another
order. Reload sits beside the view controls by default, and New Folder, New File, Move to Trash, Open in Terminal,
Quick Look and Command Palette are optional. Dragging the default set from the native palette restores it.

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
