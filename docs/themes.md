# Contributing a color theme

Themes live in `Sources/Strata/App/Themes/`, one JSON file per palette. The app discovers them automatically and
shows their previews in Settings ▸ Appearance. No Swift cases, settings rows or build-file lists need editing.
These are bundled contributions: adding a file and rebuilding makes it available. Strata does not run theme code.
The catalog accepts up to 128 themes, each at most 16 KiB.

Copy an existing file, such as `sage.json`, and change its ID, English name, translator note and colors:

```json
{
  "version": 1,
  "id": "meadow",
  "name": "Meadow",
  "comment": "Color theme: soft yellow-green",
  "order": 150,
  "seed": [0.45, 0.60, 0.25],
  "tintStrength": 0.5,
  "lightnessShift": { "light": 0, "dark": -0.02 }
}
```

- Name the file after its ID: `meadow.json`. IDs use lowercase ASCII letters, digits and single hyphens, start with a
  letter and have at most 48 characters. Keep published IDs stable: preferences store the ID, not the translated name.
  `system` is reserved for macOS's own colors.
- Use a unique name and order. Order is an integer from 1 to 10,000; gaps let later themes sit between existing ones.
  System always comes first. Names have at most 40 characters; the comment helps translators understand the color.
- `seed` is red, green and blue in sRGB, each from 0 to 1. It supplies the hue and selections/accents. Status, tags and
  file-type colors retain their meanings.
- `tintStrength` ranges from 0 to 1.25. It controls surface saturation independently of the seed; lower values suit
  muted palettes. `lightnessShift` adjusts the shared surface levels: light accepts −0.02 through 0.04, dark accepts
  −0.12 through 0.04. Use modest adjustments and inspect both appearances.

## Published color schemes

A palette with its own published values, such as Catppuccin, can state each appearance's colors exactly instead of
deriving them. Replace `tintStrength` and `lightnessShift` with a `light` and a `dark` object, each listing every
surface, the emphasized selection and the accent as `#RRGGBB` in sRGB (see `catppuccin.json`, which uses Latte when
light and Mocha when dark):

```json
"light": { "content": "#eff1f5", "sidebar": "#e6e9ef", "inspector": "#e6e9ef", "preview": "#eff1f5",
           "chrome": "#ccd0da", "alternatingRow": "#e6e9ef", "selection": "#d8c9f4", "accent": "#702fc5" },
"dark":  { "content": "#1e1e2e", "sidebar": "#181825", "inspector": "#181825", "preview": "#11111b",
           "chrome": "#313244", "alternatingRow": "#181825", "selection": "#5b4e74", "accent": "#cba6f7" }
```

- `content` is the file list and toolbar, `sidebar` and `inspector` the side panels, `preview` text fields and file
  previews, `chrome` the selection of an unfocused list, and `alternatingRow` striped rows.
- Strata keeps black text on light colors and white text on dark ones: every light surface and selection needs a
  relative luminance of at least 0.4, every dark one at most 0.12. The accent needs 4.5:1 contrast with every
  surface; a published accent may need a deeper shade (Catppuccin Latte's Mauve is deepened to read on Surface 0).
- `seed` is still required: switches, checkboxes and other filled controls draw white on a deep shade of it.

Strata derives coordinated content, sidebar, inspector, preview, toolbar and alternating-row surfaces. macOS owns
controls, focus and materials. Every theme supports System, Light and Dark appearance, Window tint off, Reduce
Transparency and Increase Contrast. Increase Contrast restores native colors.

Run `python3 scripts/localize.py extract`. It extracts theme names and comments alongside Swift strings. Add the name's
translation to every `Localization/<language>.json`; a new theme uses the existing language catalogs.

Before submitting, run:

```sh
python3 scripts/localize.py check --all --complete
python3 scripts/audit-theme-colors.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'ThemeCatalogTests|ColorThemeTests'
```

The tests discover all bundled files too. Invalid schema, duplicate identities/names/order and out-of-range colors
fail CI. All themes run through the native UI tests, including selection and inspector text contrast of at least
4.5:1, native accessibility fallback, both panes and the different file views. Check the actual app in light and dark
appearance as well: headless rendering cannot verify the live full-screen compositor.
