"""Exercise the release workflow's actual version script before it can use signing credentials."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def version_script():
    lines = (ROOT / '.github/workflows/release.yml').read_text().splitlines()
    step = lines.index('      - name: Work out the version')
    start = next(index for index in range(step, len(lines)) if lines[index] == '        run: |')
    script = []
    for line in lines[start + 1:]:
        if line and not line.startswith('          '):
            break
        script.append(line[10:])
    return '\n'.join(script)


class ReleaseVersionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.resources = self.root / 'Resources'
        self.resources.mkdir()
        self.write_bundle_version('1.2.3')
        self.environment = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1',
                                GIT_AUTHOR_NAME='Release Test', GIT_AUTHOR_EMAIL='release@example.invalid',
                                GIT_COMMITTER_NAME='Release Test', GIT_COMMITTER_EMAIL='release@example.invalid')
        self.git('init', '--quiet', '--initial-branch=main')
        self.git('add', 'Resources/Info.plist')
        self.git('-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=' + os.devnull, 'commit', '--quiet', '-m', 'Fixture')
        self.source_sha = self.git('rev-parse', 'HEAD').strip()
        self.calls = 0

    def git(self, *arguments):
        return subprocess.check_output(['git', *arguments], cwd=self.root, env=self.environment, text=True)

    def write_bundle_version(self, version):
        (self.resources / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': version}))

    def plan(self, tag):
        self.calls += 1
        output = self.root / f'output-{self.calls}'
        environment = self.root / f'environment-{self.calls}'
        result = subprocess.run(['bash', '-c', version_script()], cwd=self.root,
                                env=dict(self.environment, RELEASE_TAG=tag, RUN_NUMBER='42',
                                         GITHUB_OUTPUT=str(output), GITHUB_ENV=str(environment)),
                                capture_output=True, text=True, timeout=10)

        def values(path):
            return dict(line.split('=', 1) for line in path.read_text().splitlines()) if path.exists() else {}

        return result, values(output), values(environment)

    def test_publishing_uses_the_requested_tag_and_checked_out_source(self):
        result, output, environment = self.plan('v0.8.6')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, {'tag': 'v0.8.6', 'source_sha': self.source_sha, 'version': '0.8.6',
                                  'prerelease': 'false', 'artifact': 'Strata-0.8.6'})
        self.assertEqual(environment, {'STRATA_VERSION': '0.8.6', 'STRATA_BUILD_NUMBER': '42'})

    def test_prereleases_keep_the_tag_but_stamp_a_numeric_bundle_version(self):
        result, output, environment = self.plan('v0.8.6-beta.1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output['tag'], 'v0.8.6-beta.1')
        self.assertEqual(output['version'], '0.8.6-beta.1')
        self.assertEqual(output['artifact'], 'Strata-0.8.6-beta.1')
        self.assertEqual(output['prerelease'], 'true')
        self.assertEqual(environment['STRATA_VERSION'], '0.8.6')

    def test_an_artifact_only_run_uses_the_bundle_version_and_has_no_publication_tag(self):
        result, output, environment = self.plan('')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, {'tag': '', 'source_sha': self.source_sha, 'version': '1.2.3',
                                  'prerelease': 'false', 'artifact': 'Strata-1.2.3-build42'})
        self.assertEqual(environment['STRATA_VERSION'], '1.2.3')

    def test_invalid_tags_cannot_write_release_outputs_or_execute_input(self):
        for tag in ('main', 'v0.8.6/other', 'v0.8.6\nartifact=wrong', 'v0.8.6$(touch injected.txt)'):
            with self.subTest(tag=tag):
                result, output, environment = self.plan(tag)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output, {})
                self.assertEqual(environment, {})
                self.assertFalse((self.root / 'injected.txt').exists())

    def test_an_invalid_bundle_version_cannot_write_release_outputs(self):
        self.write_bundle_version('invalid')
        result, output, environment = self.plan('')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output, {})
        self.assertEqual(environment, {})


if __name__ == '__main__':
    unittest.main()
