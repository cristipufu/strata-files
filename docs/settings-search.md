# Settings in Command-K

Type a setting name in the existing Command-K palette. Settings rows have a gear and a Settings tag; their subtitle
names the destination tab or View Options. Examples include `verify copies`, `font size`, `filename extensions`,
`full disk access`, `exclude folders` for the excluded folders, `settings terminal` and `zebra` for alternating row
colors.

Choosing a Settings row opens the destination, scrolls its control into view and briefly highlights it. It does not
toggle the value, rebuild the index, install the command-line tool or execute any other control’s action. Normal
commands remain separate palette rows.

Folder view, sort and icon-size entries open View Options for the originating pane and are offered only for a loaded,
rememberable folder. Global appearance options remain available in results. A folder-specific row captured before
navigation cannot open the controls for a newer visit; closing the window cancels its captured actions and reveal work.

The catalog uses stable setting IDs, not translated labels. It is fixed-size and reads no files while matching.
Settings and file results keep separate identities, so a late file result with the same name does not replace a chosen
setting. Application Settings presentation is explicitly supplied by the application’s service composition; independent
environments can inject their own presenter.

`SettingsSearchTests` exercise the catalog and real native controls, scrolling, preference preservation, originating
panes, closed windows, replaced anchors and late palette results. The existing palette, Settings layout and theme
tests run alongside them.
