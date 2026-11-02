# Contributing to Strata

Thanks for helping make Strata better. Bug reports, ideas, translations, themes and code are all welcome.

Found a security problem? Please don't open an issue: [SECURITY.md](SECURITY.md) explains how to report it privately.

## Report a bug or suggest an idea

[Open an issue](https://github.com/cristipufu/strata-files/issues/new) with the Strata and macOS versions, the steps to
reproduce it, and what you expected instead. Say which view you were in (Icons, List, Columns, Gallery or Disk Usage),
whether Dual Pane was on, and what was selected: some bugs only happen in one of them.

## Translate

- **The app:** each language is one JSON file in [Localization](Localization). [Localization/README.md](Localization/README.md)
  has the steps, and no Xcode is needed.
- **The README:** see the [README translation guide](docs/readme-localization.md).
- **The website:** see [Website localization](docs/website.md#website-localization).

## Add a color theme

A theme is one JSON file. [docs/themes.md](docs/themes.md) describes the format, including published schemes such as
Catppuccin, and the checks to run.

## Change the code

Strata is a native macOS app in Swift and AppKit, built with Swift Package Manager. You need an Apple silicon Mac
running macOS 26, and Xcode for the tests.

```sh
scripts/build.sh debug --open    # builds build/Strata.app and opens it
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

[AGENTS.md](AGENTS.md) has the project's layout and detailed rules. The essentials:

- **Changes that touch files need tests.** Anything that deletes, trashes, moves, renames or overwrites files needs
  headless tests in the same pull request, showing that only the chosen items change and that Undo restores exactly
  them. [docs/destructive-actions.md](docs/destructive-actions.md) lists every such action with its tests.
- **Text people see is localized.** Use `String(localized:comment:)`, run `python3 scripts/localize.py extract`, and
  add the text to every `Localization/<language>.json`. `python3 scripts/localize.py check --all --complete` must pass.
- **Colors come from the theme.** Backgrounds and borders use `ThemeStyle`; `python3 scripts/audit-theme-colors.py`
  checks it.
- **Commit messages** read `Area: what changed, in the user's terms`, for example
  `Transfers: two items with one name never replace each other`.

Every pull request runs the build, the full test suite (also under Address Sanitizer) and the translation checks.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
