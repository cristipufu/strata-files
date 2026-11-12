"""Website translations are complete, independently indexable and discovered from catalogs."""
import importlib.util
import json
from pathlib import Path
import re
import shutil
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('site_localize', ROOT / 'scripts/site-localize.py')
localize = importlib.util.module_from_spec(spec)
spec.loader.exec_module(localize)


class SiteLocalizationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_complete_catalogs_cover_every_app_language(self):
        _, keys = localize.sources(ROOT / 'site')
        locales = localize.catalogs(ROOT / 'site/localization', keys, ROOT / 'Localization')
        self.assertEqual({l['code'] for l in locales}, {p.stem for p in (ROOT / 'Localization').glob('*.json')})

    def test_every_route_has_own_canonical_reciprocal_alternates_and_translated_body(self):
        (self.root / 'llms.txt').write_text('# Strata Files\n')
        locales = localize.build(self.root)
        for locale in locales:
            manifest = json.loads((self.root / locale['slug'] / 'site.webmanifest').read_text())
            self.assertEqual(manifest['lang'], locale['code'])
            self.assertEqual(manifest['start_url'], localize.route(locale, 'home'))
            self.assertEqual(manifest['description'], locale['strings']['Strata Files is a fast, private file manager and Finder alternative for macOS, free and open source.'])
            for page in ['home', 'privacy', 'releases']:
                url = localize.route(locale, page)
                source = (self.root / url.lstrip('/') / 'index.html').read_text()
                self.assertIn(f'<html lang="{locale["code"]}"', source)
                self.assertIn(f'rel="canonical" href="{localize.ORIGIN}{url}"', source)
                for other in locales:
                    self.assertIn(f'hreflang="{other["code"]}" href="{localize.ORIGIN}{localize.route(other, page)}"', source)
                self.assertIn('hreflang="x-default"', source)
                heading = {
                    'home': 'The file manager <br><span class="gradient-text">your Mac deserves.</span>',
                    'privacy': 'Privacy Policy',
                    'releases': 'Releases',
                }[page]
                self.assertIn(locale['strings'][heading], source)
                self.assertIn(f'href="{localize.route(locale, "privacy")}"', source)
                self.assertIn(f'href="{localize.route(locale, "releases")}"', source)
                if page == 'releases':
                    self.assertIn('id="v0.8.5"', source)
                    self.assertIn('Strata 0.8.5', source)
                    self.assertIn(locale['strings']['Latest'], source)
                if page == 'home':
                    data = json.loads(re.search(r'<script type="application/ld\+json">(.*?)</script>', source, re.S)[1])
                    faq = next(item for item in data['@graph'] if item['@type'] == 'FAQPage')['mainEntity']
                    visible = re.findall(r'<details class="reveal">\s*<summary>(.*?)</summary>\s*<p>(.*?)</p>', source, re.S)
                    self.assertEqual([(q['name'], q['acceptedAnswer']['text']) for q in faq],
                                     [(localize.plain_text(q), localize.plain_text(a)) for q, a in visible])
                    self.assertLess(source.index('locale-data.js'), source.index('src="/main.js"'))
        sitemap = ET.parse(self.root / 'sitemap.xml')
        urls = [node.text for node in sitemap.findall('./{*}url/{*}loc')]
        self.assertEqual(set(urls), {localize.ORIGIN + localize.route(l, page) for l in locales for page in ['home', 'privacy', 'releases']})
        self.assertEqual(len(urls), len(locales) * 3)
        self.assertFalse((self.root / 'localization').exists())
        self.assertIn('https://stratafiles.app/pt-pt/', (self.root / 'llms.txt').read_text())

    def test_new_catalog_automatically_adds_routes_picker_and_sitemap(self):
        source = self.root / 'source'
        shutil.copytree(ROOT / 'site', source)
        locale = json.loads((source / 'localization/en.json').read_text())
        locale.update(code='fi', language='Suomi', slug='fi', ogLocale='fi_FI')
        (source / 'localization/fi.json').write_text(json.dumps(locale))
        output = self.root / 'output'
        localize.build(output, source)
        self.assertTrue((output / 'fi/index.html').is_file())
        self.assertTrue((output / 'fi/privacy/index.html').is_file())
        self.assertIn('hreflang="fi"', (output / 'index.html').read_text())
        self.assertIn('>Suomi</a>', (output / 'fr/privacy/index.html').read_text())
        self.assertIn('https://stratafiles.app/fi/', (output / 'sitemap.xml').read_text())

    def test_build_refuses_source_overlap_before_changing_files(self):
        source = self.root / 'source'
        shutil.copytree(ROOT / 'site', source)
        before = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        for output in [source, source / 'generated', self.root]:
            with self.subTest(output=output), self.assertRaisesRegex(ValueError, 'separate'):
                localize.build(output, source)
        self.assertEqual(before, {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob('*') if p.is_file()})

    def test_missing_blank_and_unsafe_translations_fail_before_generation(self):
        _, keys = localize.sources(ROOT / 'site')
        directory = self.root / 'catalogs'
        directory.mkdir()
        original = json.loads((ROOT / 'site/localization/en.json').read_text())
        (directory / 'en.json').write_text(json.dumps(original))
        for mutation in ['missing', 'blank', 'script', 'command', 'placeholder', 'draft', 'brand', 'link']:
            locale = json.loads(json.dumps(original))
            locale.update(code='fr', language='Français', slug='fr', ogLocale='fr_FR')
            strings = locale['strings']
            if mutation == 'missing':
                strings.pop('Language')
            elif mutation == 'blank':
                strings['Language'] = '  '
            elif mutation == 'script':
                strings['Language'] = '<script>alert(1)</script>'
            elif mutation == 'command':
                key = '<code>ext:swift modified:&lt;7d</code>'
                strings[key] = '<code>ext:swift modified:&gt;7d</code>'
            elif mutation == 'placeholder':
                strings['Star · {count}'] = 'Star'
            elif mutation == 'draft':
                strings['Language'] = '__KEEP1234__'
            elif mutation == 'brand':
                strings['Strata Files, home'] = 'Translated product name'
            else:
                key = next(k for k in strings if '<a href=' in k)
                strings[key] = key.replace('https://github.com/', 'https://example.com/')
            (directory / 'fr.json').write_text(json.dumps(locale))
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                localize.catalogs(directory, keys)

    def test_sentence_units_keep_inline_markup_word_order_and_attributes(self):
        source = '<p>Press <b>Space</b> to see <a href="/">files</a>.</p><img alt="A preview" src="image.webp">'
        units = localize.Document(source).messages()
        self.assertEqual([u[2] for u in units], ['Press <b>Space</b> to see <a href="/">files</a>.', 'A preview'])
        self.assertEqual(localize.signature('Press <b>Space</b>.'), localize.signature('<b>Leertaste</b> drücken.'))
        with self.assertRaises(ValueError):
            localize.Document('<p><b>broken</p>')

    def test_technical_examples_and_decorative_demo_data_are_preserved(self):
        source = '<p translate="no">ext:swift</p><div aria-hidden="true">Invoice.pdf</div><a class="brand">Strata <em>Files</em></a><p>Search</p>'
        self.assertEqual([u[2] for u in localize.Document(source).messages()], ['Search'])

    def test_github_releases_json_merges_dates_and_skips_drafts_and_prereleases(self):
        notes = self.root / 'notes'
        notes.mkdir()
        (notes / '0.8.5.md').write_text('Strata 0.8.5 from the repository.')
        (notes / '0.8.4.md').write_text('Strata 0.8.4 from the repository.')
        gh_json = self.root / 'releases.json'
        gh_json.write_text(json.dumps([
            {'tag_name': 'v0.9.0-beta.1', 'prerelease': True, 'body': 'Beta'},
            {'tag_name': 'v0.9.1', 'draft': True, 'body': 'Draft'},
            {'tag_name': 'v0.8.5', 'published_at': '2026-11-09T12:00:00Z', 'body': 'Strata 0.8.5 from GitHub.\n\n## New\n\n- **Live item.** Details.'},
        ]))
        releases = localize.load_releases(notes, gh_json)
        self.assertEqual([release['version'] for release in releases], ['0.8.5', '0.8.4'])
        self.assertEqual(releases[0]['date'], '2026-11-09')
        self.assertIn('Strata 0.8.5 from GitHub.', releases[0]['body'])
        self.assertEqual(releases[1]['body'], 'Strata 0.8.4 from the repository.')

