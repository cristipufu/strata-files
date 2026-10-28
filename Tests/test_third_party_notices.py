from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ThirdPartyNoticeTests(unittest.TestCase):
    """Every third-party package Strata ships is credited, and the credits travel inside the app."""

    def setUp(self):
        self.notices = (ROOT / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
        self.manifest = (ROOT / "Package.swift").read_text(encoding="utf-8")

    def test_every_package_dependency_is_credited_at_its_pinned_version(self):
        packages = re.findall(r'\.package\(url: "([^"]+)"(?:, exact: "([^"]+)")?', self.manifest)
        self.assertTrue(packages)
        self.assertEqual(len(packages), self.manifest.count(".package("), "Every package dependency is matched.")
        for url, version in packages:
            name = url.rstrip("/").split("/")[-1].removesuffix(".git")
            with self.subTest(package=name):
                self.assertIn(url, self.notices)
                self.assertRegex(self.notices, rf"(?m)^## {re.escape(name)} {re.escape(version)}$" if version
                                 else rf"(?m)^## {re.escape(name)}\b")

    def test_sparkles_license_is_reproduced_verbatim(self):
        # CI runs these checks before resolving packages; locally (and after any build) the resolved copy is compared.
        license = ROOT / ".build" / "artifacts" / "sparkle" / "Sparkle" / "LICENSE"
        if not license.exists():
            self.skipTest("Sparkle has not been resolved yet")

        def lines(text):
            return "\n".join(line.rstrip() for line in text.strip().splitlines())

        self.assertIn(lines(license.read_text(encoding="utf-8")), lines(self.notices))

    def test_the_app_carries_the_one_notices_file(self):
        script = (ROOT / "scripts" / "build.sh").read_text(encoding="utf-8")
        self.assertIn('cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"', script)
        self.assertFalse((ROOT / "Resources" / "ArchivePreviewNotice.txt").exists(),
                         "One notices file, so the repository's and the app's credits cannot drift apart.")


if __name__ == "__main__":
    unittest.main()
