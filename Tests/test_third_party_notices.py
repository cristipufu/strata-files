from pathlib import Path
import re
import hashlib
import json
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

    def test_offline_diagram_bundle_matches_the_credited_upstream_release(self):
        resource = ROOT / "Sources/Strata/Previews/Mermaid"
        checksum = hashlib.sha256((resource / "mermaid.min.js").read_bytes()).hexdigest()
        self.assertIn(checksum, self.notices)
        self.assertIn((resource / "LICENSE").read_text(encoding="utf-8"), self.notices)
        self.assertIn('.copy("Mermaid")', self.manifest)
        script = (ROOT / "scripts/build.sh").read_text(encoding="utf-8")
        self.assertIn('cp -R "$bins/Strata_StrataPreviews.bundle" "$app/Contents/Resources/Strata_StrataPreviews.bundle"', script)

    def test_every_library_in_the_diagram_inventory_has_its_full_license_text(self):
        resource = ROOT / "Sources/Strata/Previews/Mermaid"
        inventory = json.loads((resource / "packages.json").read_text(encoding="utf-8"))
        self.assertEqual(inventory["bundleSHA256"], hashlib.sha256((resource / "mermaid.min.js").read_bytes()).hexdigest())
        blocks = re.findall(r"```text\n(.*?)\n```", self.notices, re.S)
        checksums = {hashlib.sha256(block.rstrip().encode()).hexdigest() for block in blocks}
        self.assertEqual(len(inventory["packages"]), 66)
        for package in inventory["packages"]:
            with self.subTest(package=package["name"], version=package["version"]):
                self.assertIn(f'### {package["name"]} {package["version"]}\n', self.notices)
                self.assertIn(package["source"], self.notices)
                self.assertTrue(package["licenseFiles"])
                for license in package["licenseFiles"]:
                    self.assertIn(license["noticeTextSHA256"], checksums)

    def test_the_app_carries_the_one_notices_file(self):
        script = (ROOT / "scripts" / "build.sh").read_text(encoding="utf-8")
        self.assertIn('cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"', script)
        self.assertFalse((ROOT / "Resources" / "ArchivePreviewNotice.txt").exists(),
                         "One notices file, so the repository's and the app's credits cannot drift apart.")


if __name__ == "__main__":
    unittest.main()
