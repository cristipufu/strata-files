from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
SWIFT_TESTS = ROOT / "Tests" / "StrataTests"
HELPER = SWIFT_TESTS / "Support" / "IsolatedPreferences.swift"


class TestIsolationTests(unittest.TestCase):
    """Swift tests make settings suites only through Prefs.isolated(), which removes each suite and its file."""

    def sources(self):
        return [(path.relative_to(ROOT).as_posix(), path.read_text(encoding="utf-8"))
                for path in sorted(SWIFT_TESTS.rglob("*.swift")) if path != HELPER]

    def test_no_test_cleans_up_a_suite_by_hand(self):
        offenders = [name for name, text in self.sources() if "removePersistentDomain" in text]
        self.assertEqual(offenders, [], "Use Prefs.isolated(): emptying a suite by hand leaves its file behind.")

    def test_only_existing_suites_are_reopened_by_name(self):
        # Reopening an isolated suite to check persistence names it by its `domainName`.
        new_suite = re.compile(r"UserDefaults(?:\.init)?\(suiteName: (?![\w.]+\.domainName\))")
        offenders = [name for name, text in self.sources() if new_suite.search(text)]
        self.assertEqual(offenders, [], "Use Prefs.isolated() for a new suite.")


if __name__ == "__main__":
    unittest.main()
