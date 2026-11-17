"""Packaging checks: URLs survive deploys and downloaded assets are verified."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import call, patch
from urllib.error import HTTPError

spec = importlib.util.spec_from_file_location('site_assets', Path(__file__).resolve().parents[1] / 'scripts/site-assets.py')
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


def download_response(url, data):
    response = io.BytesIO(data)
    response.url = url
    return response


class SiteDownloadTests(unittest.TestCase):
    url = 'https://stratafiles.app/asset-manifest.json'

    def test_temporary_http_failures_close_before_retrying_and_recover(self):
        for code in [408, 429, 500, 502, 503, 504]:
            with self.subTest(code=code):
                failed_body = io.BytesIO(b'unavailable')
                error = HTTPError(self.url, code, '', {}, failed_body)
                response = download_response(self.url, b'asset bytes')
                with patch.object(assets, 'urlopen', side_effect=[error, response]) as opened, \
                     patch('time.sleep', side_effect=lambda _: self.assertTrue(failed_body.closed)) as sleep:
                    self.assertEqual(assets.fetch(self.url, 1024), b'asset bytes')
                self.assertEqual(opened.call_count, 2)
                sleep.assert_called_once_with(1)
                self.assertTrue(response.closed)

    def test_repeated_http_failures_stop_after_three_attempts(self):
        bodies = [io.BytesIO(b'unavailable') for _ in range(3)]
        errors = [HTTPError(self.url, 503, '', {}, body) for body in bodies]
        with patch.object(assets, 'urlopen', side_effect=errors) as opened, patch('time.sleep') as sleep:
            with self.assertRaises(HTTPError) as failure:
                assets.fetch(self.url, 1024)
        self.assertIs(failure.exception, errors[-1])
        self.assertEqual(opened.call_count, 3)
        self.assertEqual(sleep.call_args_list, [call(1), call(2)])
        self.assertTrue(all(body.closed for body in bodies))

    def test_permanent_http_failures_do_not_retry(self):
        for code in [400, 401, 403, 404, 410, 501, 505]:
            with self.subTest(code=code):
                error = HTTPError(self.url, code, '', {}, None)
                with patch.object(assets, 'urlopen', side_effect=error) as opened, patch('time.sleep') as sleep:
                    with self.assertRaises(HTTPError) as failure:
                        assets.fetch(self.url, 1024)
                self.assertIs(failure.exception, error)
                self.assertEqual(opened.call_count, 1)
                sleep.assert_not_called()

    def test_unsafe_or_oversized_responses_close_without_retrying(self):
        for url, data, problem in [
            ('http://stratafiles.app/asset-manifest.json', b'{}', 'redirected'),
            ('https://example.com/asset-manifest.json', b'{}', 'redirected'),
            (self.url, b'too large', 'download limit'),
        ]:
            with self.subTest(url=url, data=data):
                response = download_response(url, data)
                with patch.object(assets, 'urlopen', return_value=response) as opened, patch('time.sleep') as sleep:
                    with self.assertRaisesRegex(ValueError, problem):
                        assets.fetch(self.url, 3)
                self.assertEqual(opened.call_count, 1)
                self.assertTrue(response.closed)
                sleep.assert_not_called()


class SiteAssetsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def fixture(self, javascript='window.ready = true;'):
        for name, data in {
            'index.html': '<meta charset="utf-8"><link rel="stylesheet" href="styles.css"><script src="main.js"></script><img src="image.png" srcset="image.png 800w">',
            'privacy/index.html': '<meta charset="utf-8"><link rel="stylesheet" href="../styles.css">',
            'styles.css': 'body { background: url("image.png"); }',
            'main.js': javascript,
            'image.png': 'demo image bytes',
            'site.webmanifest': json.dumps({'icons': [{'src': 'image.png'}]}),
        }.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(data)

    def test_references_and_every_filename_match_contents(self):
        self.fixture()
        assets.prepare(self.root)
        manifest = json.loads((self.root / 'asset-manifest.json').read_text())
        names = {name.split('-', 1)[1]: '/' + name for name in manifest}
        for name in manifest:
            self.assertEqual(assets.ASSET.fullmatch(name)[1], hashlib.sha256((self.root / name).read_bytes()).hexdigest())
        home = (self.root / 'index.html').read_text()
        self.assertIn('src="' + names['main.js'] + '"', home)
        self.assertIn('srcset="' + names['image.png'] + ' 800w"', home)
        self.assertIn('url("' + names['image.png'] + '")', home)
        self.assertIn('href="' + names['styles.css'] + '"', (self.root / 'privacy/index.html').read_text())
        self.assertLess(home.index('Content-Security-Policy'), home.index('<script'))
        self.assertEqual(json.loads((self.root / 'site.webmanifest').read_text())['icons'][0]['src'], names['image.png'])

    def test_changed_asset_gets_new_url_and_old_url_survives(self):
        self.fixture()
        assets.prepare(self.root)
        before = json.loads((self.root / 'asset-manifest.json').read_text())
        previous = {name: (self.root / name).read_bytes() for name in before}
        self.fixture('window.ready = false;')
        assets.prepare(self.root)
        after = json.loads((self.root / 'asset-manifest.json').read_text())
        self.assertTrue(set(before) < set(after))
        for name, contents in previous.items():
            self.assertEqual((self.root / name).read_bytes(), contents)

    def test_inline_javascript_is_rejected(self):
        self.fixture()
        with (self.root / 'index.html').open('a') as page:
            page.write('<script>alert(1)</script>')
        with self.assertRaisesRegex(ValueError, 'inline JavaScript'):
            assets.prepare(self.root)

    def test_previous_asset_is_verified_and_restored(self):
        data = b'old script'
        name = 'immutable/' + hashlib.sha256(data).hexdigest() + '-main.js'
        def fetch(url, limit):
            return json.dumps([name]).encode() if url.endswith('asset-manifest.json') else data
        with patch.object(assets, 'fetch', side_effect=fetch):
            assets.restore_previous(self.root, 'https://stratafiles.app')
        self.assertEqual((self.root / name).read_bytes(), data)

    def test_manifest_and_asset_downloads_each_recover_from_temporary_failures(self):
        origin = 'https://stratafiles.app'
        data = b'old script'
        name = 'immutable/' + hashlib.sha256(data).hexdigest() + '-main.js'
        manifest_url, asset_url = origin + '/asset-manifest.json', origin + '/' + name
        responses = [
            HTTPError(manifest_url, 503, '', {}, None),
            download_response(manifest_url, json.dumps([name]).encode()),
            HTTPError(asset_url, 503, '', {}, None),
            download_response(asset_url, data),
        ]
        with patch.object(assets, 'urlopen', side_effect=responses) as opened, patch('time.sleep') as sleep:
            assets.restore_previous(self.root, origin)
        self.assertEqual((self.root / name).read_bytes(), data)
        self.assertEqual(opened.call_args_list, [call(manifest_url, timeout=30)] * 2 + [call(asset_url, timeout=30)] * 2)
        self.assertEqual(sleep.call_args_list, [call(1), call(1)])

    def test_invalid_manifest_is_refused_before_downloads(self):
        valid = 'immutable/' + 'a' * 64 + '-main.js'
        for manifest in [['../escaped.js'], [valid, '../escape'], [valid, valid], {'files': []}, [None], [valid] * 2001]:
            with self.subTest(manifest=str(manifest)[:80]):
                with patch.object(assets, 'fetch', return_value=json.dumps(manifest).encode()) as fetch:
                    with self.assertRaises(ValueError):
                        assets.restore_previous(self.root, 'https://stratafiles.app')
                    self.assertEqual(fetch.call_count, 1)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_wrong_digest_is_not_written(self):
        name = 'immutable/' + 'a' * 64 + '-main.js'
        with patch.object(assets, 'fetch', side_effect=[json.dumps([name]).encode(), b'wrong bytes']):
            with self.assertRaisesRegex(ValueError, 'does not match'):
                assets.restore_previous(self.root, 'https://stratafiles.app')
        self.assertEqual(list(self.root.iterdir()), [])

    def test_only_missing_manifest_is_allowed(self):
        for code in [404, 503]:
            with patch.object(assets, 'fetch', side_effect=HTTPError('https://stratafiles.app', code, '', {}, None)):
                if code == 404:
                    assets.restore_previous(self.root, 'https://stratafiles.app')
                else:
                    with self.assertRaises(HTTPError):
                        assets.restore_previous(self.root, 'https://stratafiles.app')
        with patch.object(assets, 'fetch') as fetch:
            with self.assertRaisesRegex(ValueError, 'HTTPS'):
                assets.restore_previous(self.root, 'http://stratafiles.app')
            fetch.assert_not_called()
