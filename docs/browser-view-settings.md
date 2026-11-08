# Folder view settings

Strata remembers the view mode, sort column and direction, and icon size when you customize a local folder in View
Options. Returning to it or opening it in a new window restores those choices. An uncustomized folder uses the defaults,
and changing the view mode in the toolbar or View menu updates the default view mode so all view modes stay consistent
across uncustomized folders. Settings live in Strata’s preferences; Strata does not create `.DS_Store` files in the
folders you browse.

Command-J opens View Options for the originating pane. Its Folder section chooses the view and order; Icon size
belongs to that folder too. **Use as Defaults** makes its current choices the defaults for folders without a saved
choice. **Reset** removes only that folder’s saved choice and restores the current defaults. Other options, including
column visibility, alternating rows, item information and icon previews, remain shared appearance settings.

Other panes using the same preferences update when their folder’s choice changes. Independent environments keep
their own settings. Search, Recents and Duplicates retain their own presentation and cannot overwrite folder choices;
the Folder controls are disabled there. Provider copies and archive cache folders are temporary, so their paths do
not become remembered local folder settings.

A workspace’s explicit initial view and ordering can override the first folder for that window without rewriting
the folder’s saved choice. Later navigation uses each folder’s settings. Changes made during a folder read wait for
the actual resolved folder; navigation or closure cancels them, so a late read cannot save choices for another folder.

Each folder has one small preference record. Reading or updating it does not scan all remembered folders. Records
validate the view, sort and finite icon size; an invalid record falls back to defaults without rewriting that record
or disturbing its neighbors. `FolderViewSettingsTests`, native View Options/theme tests, browser ordering/preferences
and workspace tests cover these rules. The cancelled-read rule also has a mutation check.
