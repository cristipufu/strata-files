import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("localize", ROOT / "scripts" / "localize.py")
localize = importlib.util.module_from_spec(spec)
spec.loader.exec_module(localize)

GERMAN_COLUMNS = {"Date Added": "Hinzugefügt am", "Width": "Breite", "Height": "Höhe", "Duration": "Dauer"}
NEW_LABELS = [
    "Other options apply to all windows.", "Ascending", "Use as Defaults", "Date Added", "Duration", "Folder info", "Height", "Icon size", "Item count",
    "List columns", "Pictures and movies show their dimensions. Other files show their size.",
    "Show View Options…", "Show item info", "Total size", "View Options", "Width",
    "/usr/local/bin/strata isn’t Strata’s command, so it was left as it is. Remove or rename it, then install again.",
    "Another “strata” is installed.",
]


class CatalogTranslationTests(unittest.TestCase):
    def test_contributed_theme_names_are_extracted_with_notes_and_translated(self):
        themes = localize.theme_strings()
        english = localize.load(localize.SOURCE)["strings"]
        self.assertTrue(themes)
        for path in localize.language_files():
            strings = localize.load(path)["strings"]
            for name, info in themes.items():
                with self.subTest(language=path.stem, theme=name):
                    self.assertIn(name, english)
                    self.assertTrue(strings[name].strip())
                    self.assertTrue(info["comments"])

    def test_new_theme_names_need_no_swift_localization_declaration(self):
        with tempfile.TemporaryDirectory(prefix="strata-theme-strings-") as scratch:
            root = Path(scratch)
            themes = root / "Sources/Strata/App/Themes"
            themes.mkdir(parents=True)
            (themes / "meadow.json").write_text(json.dumps({"name": "Meadow", "comment": "A soft green"}))
            with patch.object(localize, "ROOT", root):
                strings = localize.theme_strings()
            self.assertEqual(set(strings), {"Meadow"})
            self.assertEqual(strings["Meadow"]["places"], ["Themes/meadow.json"])
            self.assertEqual(strings["Meadow"]["comments"], {"A soft green"})

    def test_supported_languages_have_every_source_translation(self):
        english = localize.load(localize.SOURCE)["strings"]
        for path in localize.language_files():
            with self.subTest(language=path.stem):
                data = localize.load(path)
                strings = data["strings"]
                self.assertEqual(set(strings), set(english))
                required, _ = localize.plural_rules(path.stem, data)
                for key, source in english.items():
                    value = strings[key]
                    if isinstance(source, dict):
                        self.assertIsInstance(value, dict, (path.stem, key))
                        for category in required:
                            self.assertTrue(isinstance(value.get(category), str) and value[category].strip(),
                                            (path.stem, key, category))
                    else:
                        self.assertTrue(isinstance(value, str) and value.strip(), (path.stem, key))

    def test_reported_german_column_names_match_the_contribution(self):
        german = localize.load(localize.FOLDER / "de.json")["strings"]
        self.assertEqual({key: german.get(key) for key in GERMAN_COLUMNS}, GERMAN_COLUMNS)

    @unittest.skipUnless(sys.platform == "darwin", "plutil validates the macOS app's strings resources")
    def test_generated_resources_include_new_controls_and_columns_in_every_language(self):
        with tempfile.TemporaryDirectory(prefix="strata-translations-") as scratch:
            with contextlib.redirect_stdout(io.StringIO()):
                localize.build(scratch)
            for path in localize.language_files():
                with self.subTest(language=path.stem):
                    resource = Path(scratch) / f"{path.stem}.lproj" / "Localizable.strings"
                    result = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(resource)],
                                            capture_output=True, text=True, check=True)
                    strings = json.loads(result.stdout)
                    expected = localize.load(path)["strings"]
                    self.assertTrue(all(strings.get(key) for key in NEW_LABELS),
                                    [key for key in NEW_LABELS if not strings.get(key)])
                    self.assertEqual({key: strings.get(key) for key in NEW_LABELS},
                                     {key: expected[key] for key in NEW_LABELS})
                    if path.stem == "de":
                        self.assertEqual({key: strings.get(key) for key in GERMAN_COLUMNS}, GERMAN_COLUMNS)


class CompletenessCheckTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="strata-localization-check-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.folder = self.root / "Localization"
        self.folder.mkdir()
        self.count_key = "%lld Items"
        self.english = {"Width": "Width", "Git": "Git", self.count_key: {"one": "%lld Item", "other": "%lld Items"}}
        self.german = {"Width": "Breite", "Git": "Git", self.count_key: {"one": "%lld Objekt", "other": "%lld Objekte"}}
        self.write_language("en", self.english)
        self.write_language("de", self.german)
        for name, value in [("FOLDER", self.folder), ("SOURCE", self.folder / "en.json")]:
            replacement = patch.object(localize, name, value)
            replacement.start()
            self.addCleanup(replacement.stop)

    def write_language(self, code, strings, plurals=None):
        data = {"language": code, "english": code, "code": code, "strings": strings}
        if plurals:
            data["plurals"] = plurals
        (self.folder / f"{code}.json").write_text(json.dumps(data), encoding="utf-8")

    def check_result(self, target="--all", complete=True):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            try:
                localize.check(target, complete=complete)
            except SystemExit as error:
                return error.code, output.getvalue()
        return 0, output.getvalue()

    def test_complete_languages_accept_shared_names_and_optional_plural_forms(self):
        forms = {
            "fr": {"one": "%lld élément", "other": "%lld éléments"},
            "ja": {"other": "%lld項目"},
            "pl": {"one": "%lld rzecz", "few": "%lld rzeczy", "many": "%lld rzeczy", "other": "%lld rzeczy"},
            "xx": {"one": "%lld item", "other": "%lld items"},
        }
        for code, values in forms.items():
            self.write_language(code, {**self.german, self.count_key: values})
        self.assertEqual(self.check_result(), (0, "No problems.\n"))

    def test_missing_key_fails_with_language_and_key_in_the_error(self):
        self.write_language("de", {key: value for key, value in self.german.items() if key != "Width"})
        code, output = self.check_result()
        self.assertEqual(code, 1)
        self.assertIn("de: “Width” is missing its translation", output)

    def test_blank_plain_translations_are_rejected(self):
        for value in ["", " \t\n", "\u2003", None, 42]:
            with self.subTest(value=value):
                self.write_language("de", {**self.german, "Width": value})
                code, output = self.check_result()
                self.assertEqual(code, 1)
                self.assertIn("de: “Width”", output)

    def test_each_language_requires_all_its_plural_forms(self):
        for language, required in [("de", ["one", "other"]), ("pl", ["one", "few", "many", "other"]),
                                   ("ja", ["other"]), ("ro", ["one", "few", "other"])]:
            forms = {category: f"%lld {category}" for category in required}
            for category in required:
                for missing in [True, False]:
                    with self.subTest(language=language, category=category, missing=missing):
                        broken = dict(forms)
                        if missing:
                            del broken[category]
                        else:
                            broken[category] = " \t"
                        self.write_language(language, {**self.german, self.count_key: broken})
                        code, output = self.check_result(target=language)
                        self.assertEqual(code, 1)
                        self.assertIn(f"{language}: “{self.count_key}” needs translated plural forms", output)
                        self.assertIn(category, output)

    def test_completely_untranslated_plurals_and_blank_optional_forms_are_rejected(self):
        for value in [{}, {"one": "", "other": ""}]:
            with self.subTest(value=value):
                self.write_language("de", {**self.german, self.count_key: value})
                self.assertEqual(self.check_result()[0], 1)
        self.write_language("de", self.german)
        self.write_language("fr", {**self.german, self.count_key: {"one": "%lld élément", "other": "%lld éléments", "many": " "}})
        self.assertEqual(self.check_result()[0], 1)

    def test_draft_check_can_still_allow_missing_and_untranslated_strings(self):
        self.write_language("de", {"Git": "Git", self.count_key: {"one": "", "other": ""}})
        self.assertEqual(self.check_result(complete=False), (0, "No problems.\n"))
        self.assertEqual(self.check_result()[0], 1)

    def test_complete_check_keeps_placeholder_and_unknown_key_validation(self):
        for strings in [
            {**self.german, self.count_key: {"one": "%@ Objekt", "other": "%lld Objekte"}},
            {**self.german, "Unknown key": "Unbekannter Schlüssel"},
        ]:
            with self.subTest(strings=strings):
                self.write_language("de", strings)
                self.assertEqual(self.check_result()[0], 1)

    def test_english_also_requires_nonblank_text_and_plural_forms(self):
        for strings in [{**self.english, "Width": " \t"},
                        {**self.english, self.count_key: {"one": " ", "other": "%lld Items"}}]:
            with self.subTest(strings=strings):
                self.write_language("en", strings)
                self.assertEqual(self.check_result()[0], 1)

    def test_command_used_by_workflows_exits_nonzero_for_an_incomplete_catalog(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        script = scripts / "localize.py"
        script.write_text((ROOT / "scripts" / "localize.py").read_text(), encoding="utf-8")

        def run(target="--all", complete=True):
            arguments = [sys.executable, str(script), "check", target] + (["--complete"] if complete else [])
            return subprocess.run(arguments, capture_output=True, text=True)

        self.assertEqual(run().returncode, 0)
        self.write_language("de", {key: value for key, value in self.german.items() if key != "Width"})
        for target in ["--all", "de"]:
            with self.subTest(target=target):
                result = run(target)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("de: “Width” is missing its translation", result.stdout)
        self.assertEqual(run(complete=False).returncode, 0)


if __name__ == "__main__":
    unittest.main()
