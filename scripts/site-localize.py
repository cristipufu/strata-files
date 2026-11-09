#!/usr/bin/env python3
"""Build crawlable website translations from complete, auto-discovered catalogs."""
import argparse
from collections import Counter
from dataclasses import dataclass, field
import html
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ORIGIN = 'https://stratafiles.app'
PAGES = {'home': 'index.html', 'privacy': 'privacy/index.html', 'releases': 'releases/index.html', '404': '404.html'}
UI = ['Language', 'Languages', 'This website is also available in {language}.',
      'Continue in {language}', 'Dismiss', 'Version {version} · {size} · Free', 'Star · {count}',
      'Appearance', 'System', 'Light', 'Dark', 'Latest']
VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'}
INLINE = {'a', 'b', 'br', 'code', 'em', 'kbd', 'small', 'span', 'strong', 'time'}
BLOCK = {'title', 'p', 'h1', 'h2', 'h3', 'h4', 'li', 'summary', 'button', 'figcaption', 'dt', 'dd', 'a', 'span', 'strong', 'small', 'label'}


def normalized(value):
    return re.sub(r'\s+', ' ', value).strip()


@dataclass
class Node:
    tag: str
    attrs: dict
    start: int
    inner: int
    end: int = 0
    children: list = field(default_factory=list)


class Document(HTMLParser):
    """Retain source offsets so translating prose never rewrites the surrounding HTML."""
    def __init__(self, source):
        super().__init__(convert_charrefs=False)
        self.source = source
        self.lines = [0]
        self.lines += [m.end() for m in re.finditer('\n', source)]
        self.root = Node('', {}, 0, 0, len(source))
        self.stack = [self.root]
        self.nodes = []
        self.feed(source)
        if len(self.stack) != 1:
            raise ValueError('Unclosed HTML element')

    def position(self):
        line, column = self.getpos()
        return self.lines[line - 1] + column

    def handle_starttag(self, tag, attrs):
        start = self.position()
        node = Node(tag, dict(attrs), start, start + len(self.get_starttag_text()))
        self.stack[-1].children.append(node)
        self.nodes.append(node)
        if tag in VOID:
            node.end = node.inner
        else:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        if self.stack[-1].tag != tag:
            raise ValueError('Unbalanced HTML element: ' + tag)
        self.stack.pop().end = self.position()

    def handle_data(self, data):
        self.stack[-1].children.append((self.position(), self.position() + len(data)))

    def handle_entityref(self, name):
        self.handle_data('&' + name + ';')

    def handle_charref(self, name):
        self.handle_data('&#' + name + ';')

    def messages(self):
        found = []
        def inline(node):
            return all(not isinstance(c, Node) or c.tag in INLINE and inline(c) for c in node.children)
        def meaningful(value):
            return any(c.isalpha() for c in html.unescape(re.sub('<[^>]+>', '', value)))
        def visit(node):
            attrs = node.attrs
            if node.tag in {'script', 'style', 'svg', 'code', 'kbd'} or attrs.get('translate') == 'no' or attrs.get('aria-hidden') == 'true':
                return
            for key in ['alt', 'aria-label'] + (['content'] if node.tag == 'meta' and (attrs.get('name') in {'description', 'twitter:title', 'twitter:description', 'twitter:image:alt'} or attrs.get('property') in {'og:title', 'og:description', 'og:image:alt'}) else []):
                value = attrs.get(key)
                if value:
                    tag = self.source[node.start:node.inner]
                    match = re.search(r'\b' + re.escape(key) + r'="([^"]*)"', tag)
                    if not match:
                        raise ValueError('Translatable attributes must use double quotes')
                    found.append((node.start + match.start(1), node.start + match.end(1), normalized(html.unescape(value)), True))
            if 'brand' in attrs.get('class', '').split():
                return
            value = normalized(self.source[node.inner:node.end])
            if node.tag in BLOCK and inline(node) and meaningful(value):
                found.append((node.inner, node.end, value, False))
            else:
                # Text beside an icon or a block retains its leading/trailing whitespace.
                # Adjacent entity callbacks are joined before translating the complete phrase.
                groups = []
                for child in node.children:
                    if isinstance(child, Node):
                        groups.append(child)
                    elif groups and isinstance(groups[-1], tuple) and groups[-1][1] == child[0]:
                        groups[-1] = (groups[-1][0], child[1])
                    else:
                        groups.append(child)
                for child in groups:
                    if isinstance(child, Node):
                        visit(child)
                    else:
                        start, end = child
                        text = self.source[start:end]
                        value = normalized(text)
                        if meaningful(value):
                            lead = len(text) - len(text.lstrip())
                            trail = len(text) - len(text.rstrip())
                            found.append((start + lead, end - trail, value, False))
        visit(self.root)
        return found


def schema_messages(source):
    result = []
    def visit(value):
        if isinstance(value, dict):
            for key, item in value.items():
                if key in {'description', 'featureList', 'name', 'text', 'applicationSubCategory', 'operatingSystem'} and isinstance(item, str) and item not in {'Strata', 'Strata Files'}:
                    result.append(item)
                elif key == 'featureList':
                    result.extend(item)
                else:
                    visit(item)
        elif isinstance(value, list):
            for item in value:
                visit(item)
    for match in re.finditer(r'<script type="application/ld\+json">(.*?)</script>', source, re.S):
        visit(json.loads(match[1]))
    return result


def plain_text(value):
    return normalized(html.unescape(re.sub('<[^>]+>', '', value)))


def schema_keys(source):
    # The FAQ's structured data reuses the exact visible answer, including answers with emphasis.
    visible = {plain_text(item[2]): item[2] for item in Document(source).messages()}
    return {value: visible.get(value, value) for value in schema_messages(source)}


def sources(source_dir):
    pages = {key: (source_dir / path).read_text() for key, path in PAGES.items()}
    keys = set(UI)
    for source in pages.values():
        keys.update(item[2] for item in Document(source).messages())
        keys.update(schema_keys(source).values())
    return pages, sorted(keys)


def signature(value):
    """Translations may reorder prose, but may not introduce markup or change commands/links."""
    doc = Document(value)
    tags = Counter((n.tag, tuple(sorted(n.attrs.items()))) for n in doc.nodes)
    literal = Counter(doc.source[n.inner:n.end] for n in doc.nodes if n.tag in {'code', 'kbd'})
    placeholders = Counter(re.findall(r'\{[a-z]+\}', value))
    return tags, literal, placeholders


def catalogs(directory, keys, app_directory=None):
    result = []
    for path in sorted(directory.glob('*.json')):
        locale = json.loads(path.read_text())
        code = locale['code']
        if not re.fullmatch(r'[a-z]{2,3}(?:-[A-Za-z]{2,4})?', code) or path.stem != code:
            raise ValueError('Invalid language code: ' + path.name)
        if locale['slug'] != ('' if code == 'en' else code.lower()):
            raise ValueError('Language route must match its code: ' + code)
        if not locale['language'].strip() or not re.fullmatch('[a-z]{2}_[A-Z]{2}', locale['ogLocale']):
            raise ValueError('Invalid locale metadata: ' + code)
        if locale.get('direction', 'ltr') not in {'ltr', 'rtl'}:
            raise ValueError('Invalid text direction: ' + code)
        strings = locale['strings']
        missing, stale = set(keys) - strings.keys(), strings.keys() - set(keys)
        if missing or stale:
            raise ValueError(f'{code}: missing {sorted(missing)}, obsolete {sorted(stale)}')
        for key, value in strings.items():
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f'{code}: empty translation: {key}')
            if '\n' in value or re.search(r'__\w*\d\w*__|ZXQ|\[S\d{4}', value):
                raise ValueError(f'{code}: unexpected draft marker or line break: {key}')
            if 'Strata Files' in key and 'Strata Files' not in value:
                raise ValueError(f'{code}: changed the product name: {key}')
            if signature(key) != signature(value):
                raise ValueError(f'{code}: changed markup, command or placeholder: {key}')
        if code == 'en' and any(k != v for k, v in strings.items()):
            raise ValueError('Regenerate the English website catalog with extract')
        aliases = locale.get('aliases', [])
        if any(not isinstance(a, str) or not re.fullmatch('[a-zA-Z]{2,3}(?:-[a-zA-Z]{2,4})?', a) for a in aliases):
            raise ValueError('Invalid matching alias: ' + code)
        result.append(locale)
    codes = [locale['code'] for locale in result]
    if 'en' not in codes or len(codes) != len(set(codes)):
        raise ValueError('A unique English catalog is required')
    aliases = [a.lower() for locale in result for a in [locale['code'], *locale.get('aliases', [])]]
    if len(aliases) != len(set(aliases)):
        raise ValueError('Language matching aliases must be unique')
    if app_directory:
        missing = {p.stem for p in app_directory.glob('*.json')} - set(codes)
        if missing:
            raise ValueError('Missing app languages: ' + ', '.join(sorted(missing)))
    return sorted(result, key=lambda l: (l['code'] != 'en', l['language'].casefold()))


def route(locale, page):
    prefix = '/' + locale['slug'] + '/' if locale['slug'] else '/'
    return prefix + {'home': '', 'privacy': 'privacy/', 'releases': 'releases/', '404': '404.html'}[page]


def render_inline_code_and_text(text):
    parts = re.split(r'(`[^`]+`)', text)
    return ''.join(
        '<code>' + html.escape(part[1:-1]) + '</code>' if part.startswith('`') and part.endswith('`') and len(part) >= 2
        else html.escape(part)
        for part in parts
    )


def render_inline_markdown(text):
    token_re = re.compile(r'(`[^`]+`)|\*\*(.+?)\*\*|\[([^\]]+)\]\((https://[^\s)]+)\)')
    out = []
    pos = 0
    for match in token_re.finditer(text):
        out.append(html.escape(text[pos:match.start()]))
        if match.group(1) is not None:
            out.append('<code>' + html.escape(match.group(1)[1:-1]) + '</code>')
        elif match.group(2) is not None:
            out.append('<strong>' + render_inline_code_and_text(match.group(2)) + '</strong>')
        else:
            label = render_inline_code_and_text(match.group(3))
            url = html.escape(match.group(4), quote=True)
            out.append(f'<a href="{url}">{label}</a>')
        pos = match.end()
    out.append(html.escape(text[pos:]))
    return ''.join(out)


def render_markdown(source):
    blocks = []
    paragraph = []
    quote = []
    items = []
    seen_heading = False

    def flush():
        nonlocal paragraph, quote, items
        if paragraph:
            cls = '' if seen_heading else ' class="release-card__summary"'
            blocks.append(f'<p{cls}>' + render_inline_markdown(' '.join(paragraph)) + '</p>')
            paragraph = []
        if quote:
            blocks.append('<blockquote class="release-card__note"><p>' + render_inline_markdown(' '.join(quote)) + '</p></blockquote>')
            quote = []
        if items:
            lis = ''.join('<li>' + render_inline_markdown(' '.join(item)) + '</li>' for item in items)
            blocks.append('<ul>' + lis + '</ul>')
            items = []

    for raw in source.splitlines():
        stripped = raw.strip()
        if not stripped:
            flush()
        elif stripped.startswith('## '):
            flush()
            seen_heading = True
            blocks.append('<h3 class="release-card__section">' + render_inline_markdown(stripped[3:].strip()) + '</h3>')
        elif stripped.startswith('### '):
            flush()
            seen_heading = True
            blocks.append('<h4 class="release-card__subsection">' + render_inline_markdown(stripped[4:].strip()) + '</h4>')
        elif stripped.startswith('>'):
            if paragraph or items:
                flush()
            quote.append(stripped[1:].strip())
        elif stripped.startswith('- '):
            if paragraph or quote:
                flush()
            items.append([stripped[2:].strip()])
        elif items and (raw.startswith('  ') or raw.startswith('\t')):
            items[-1].append(stripped)
        else:
            if quote or items:
                flush()
            paragraph.append(stripped)
    flush()
    return '\n        '.join(blocks)


def load_releases(notes_dir=ROOT / 'docs/release-notes', github_releases=None):
    tag_dates = {}
    try:
        proc = subprocess.run(['git', 'for-each-ref', '--format=%(refname:short) %(creatordate:short)', 'refs/tags/v*'],
                              cwd=ROOT, capture_output=True, text=True, check=False)
        for line in proc.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) == 2 and parts[0].startswith('v') and re.match(r'^\d{4}-\d{2}-\d{2}$', parts[1]):
                tag_dates[parts[0][1:]] = parts[1]
    except OSError:
        pass
    entries = {}
    if notes_dir and notes_dir.is_dir():
        for path in notes_dir.glob('*.md'):
            if re.fullmatch(r'\d+(?:\.\d+)+', path.stem):
                entries[path.stem] = {
                    'version': path.stem,
                    'body': path.read_text(),
                    'date': tag_dates.get(path.stem),
                    'url': f'https://github.com/cristipufu/strata-files/releases/tag/v{path.stem}',
                }
    gh_path = Path(github_releases) if github_releases else (Path(os.environ['SITE_GITHUB_RELEASES']) if os.environ.get('SITE_GITHUB_RELEASES') else None)
    if gh_path and gh_path.is_file():
        payload = json.loads(gh_path.read_text())
        if isinstance(payload, list):
            for release in payload:
                if not isinstance(release, dict) or release.get('draft') or release.get('prerelease'):
                    continue
                tag = str(release.get('tag_name', '')).strip()
                version = tag[1:] if tag.startswith('v') else tag
                if not re.fullmatch(r'\d+(?:\.\d+)+', version):
                    continue
                entry = entries.setdefault(version, {
                    'version': version,
                    'body': '',
                    'date': None,
                    'url': f'https://github.com/cristipufu/strata-files/releases/tag/v{version}',
                })
                body = str(release.get('body') or '').strip()
                if body:
                    entry['body'] = body
                published = str(release.get('published_at') or '')
                if re.match(r'^\d{4}-\d{2}-\d{2}', published):
                    entry['date'] = published[:10]
                html_url = str(release.get('html_url') or '')
                if html_url.startswith('https://github.com/'):
                    entry['url'] = html_url
    return sorted(entries.values(), key=lambda item: tuple(int(part) for part in item['version'].split('.')), reverse=True)


def render_releases_html(releases, locale):
    cards = []
    latest_label = html.escape(locale['strings']['Latest'])
    github_label = html.escape(locale['strings']['GitHub'])
    for index, item in enumerate(releases):
        version = item['version']
        tag = 'v' + html.escape(version, quote=True)
        badge = f'\n          <span class="pill__badge" lang="{locale["code"]}">{latest_label}</span>' if index == 0 else ''
        date = item.get('date')
        date_html = f'\n          <time class="release-card__date" datetime="{html.escape(date, quote=True)}">{html.escape(date)}</time>' if date else ''
        url = html.escape(item['url'], quote=True)
        body_html = render_markdown(item['body'])
        cards.append(
            f'      <article class="release-card" id="{tag}">\n'
            f'        <header class="release-card__head">\n'
            f'          <div class="release-card__meta">\n'
            f'            <h2 class="release-card__title"><a href="#{tag}">Strata {html.escape(version)}</a></h2>{badge}{date_html}\n'
            f'          </div>\n'
            f'          <a class="btn btn--ghost btn--sm release-card__link" href="{url}" lang="{locale["code"]}">{github_label} <span aria-hidden="true">↗</span></a>\n'
            f'        </header>\n'
            f'        <div class="release-card__body">\n'
            f'        {body_html}\n'
            f'        </div>\n'
            f'      </article>'
        )
    return '\n'.join(cards)


def appearance_picker(locale):
    t = locale['strings']
    buttons = ''.join('<button type="button" data-appearance-choice="' + choice.lower() + '" aria-pressed="' +
                      ('true' if choice == 'System' else 'false') + '">' + html.escape(t[choice]) + '</button>'
                      for choice in ['System', 'Light', 'Dark'])
    return ('<details class="appearance-picker" name="website-preferences" hidden><summary aria-label="' +
            html.escape(t['Appearance'], quote=True) + '"><svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true">'
            '<circle cx="12" cy="12" r="9" fill="none"/><path d="M12 3a9 9 0 0 1 0 18Z" fill="currentColor" stroke="none"/>'
            '</svg></summary><div class="appearance-picker__options" role="group" aria-label="' +
            html.escape(t['Appearance'], quote=True) + '">' + buttons + '</div></details>')


def language_picker(locale, locales, page):
    t = locale['strings']
    links = ''.join('<a href="' + route(other, page) + '" lang="' + other['code'] + '" hreflang="' + other['code'] + '" data-language="' + other['code'] + '"' + (' aria-current="true"' if other == locale else '') + '>' + html.escape(other['language']) + '</a>' for other in locales)
    return '<details class="language-picker"><summary aria-label="' + html.escape(t['Language'], quote=True) + '"><svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c5 5 5 13 0 18-5-5-5-13 0-18Z"/></svg><span>' + html.escape(locale['language']) + '</span></summary><nav class="language-picker__options" aria-label="' + html.escape(t['Languages'], quote=True) + '">' + links + '</nav></details>'


def render(source, locale, locales, page, releases=None):
    t = locale['strings']
    structured_keys = schema_keys(source)
    replacements = [(start, end, html.escape(t[key], quote=True) if attribute else t[key]) for start, end, key, attribute in Document(source).messages()]
    for start, end, value in sorted(replacements, reverse=True):
        source = source[:start] + value + source[end:]
    def schema(match):
        def visit(value):
            if isinstance(value, dict):
                return {key: locale['code'] if key == 'inLanguage' else visit(item) for key, item in value.items()}
            if isinstance(value, list):
                return [visit(item) for item in value]
            if isinstance(value, str):
                if value in structured_keys:
                    return plain_text(t[structured_keys[value]])
                if value.startswith(ORIGIN + '/#') or value == ORIGIN + '/':
                    return ORIGIN + route(locale, 'home') + value[len(ORIGIN + '/'):]
            return value
        return '<script type="application/ld+json">\n' + json.dumps(visit(json.loads(match[1])), ensure_ascii=False, indent=2).replace('</', '<\\/') + '\n  </script>'
    source = re.sub(r'<script type="application/ld\+json">(.*?)</script>', schema, source, flags=re.S)
    source = source.replace('<html lang="en">', '<html lang="' + locale['code'] + '" dir="' + locale.get('direction', 'ltr') + '">')
    source = re.sub(r'(<link rel="canonical" href=")[^"]+', lambda m: m[1] + ORIGIN + route(locale, page), source)
    source = re.sub(r'(<meta property="og:url" content=")[^"]+', lambda m: m[1] + ORIGIN + route(locale, page), source)
    source = re.sub(r'(<meta property="og:locale" content=")[^"]+', lambda m: m[1] + locale['ogLocale'], source)
    if page != '404' and 'property="og:locale"' not in source:
        source = source.replace('</head>', '  <meta property="og:locale" content="' + locale['ogLocale'] + '">\n</head>')
    # Assets are shared, rather than copied under every language route.
    source = re.sub(r'\b(href|src)="(?![a-z]+:|/|#)([^"]+)"', lambda m: m[1] + '="/' + m[2] + '"', source)
    source = re.sub(r'\b(srcset|imagesrcset)="([^"]+)"', lambda m: m[1] + '="' + ', '.join('/' + item.strip().lstrip('/') for item in m[2].split(',')) + '"', source)
    source = source.replace('href="/#', 'href="' + route(locale, 'home') + '#')
    source = (source.replace('href="/privacy/"', 'href="' + route(locale, 'privacy') + '"')
              .replace('href="/releases/"', 'href="' + route(locale, 'releases') + '"')
              .replace('href="/"', 'href="' + route(locale, 'home') + '"'))
    if page == 'releases' and releases is not None:
        marker = '<div class="releases__list" data-releases translate="no" lang="en" dir="ltr"></div>'
        if marker not in source:
            raise ValueError('Missing releases container in releases page')
        source = source.replace(marker, '<div class="releases__list" data-releases translate="no" lang="en" dir="ltr">\n' + render_releases_html(releases, locale) + '\n    </div>', 1)
    if page != '404':
        alternate = '\n'.join('  <link rel="alternate" hreflang="' + other['code'] + '" href="' + ORIGIN + route(other, page) + '">' for other in locales)
        alternate += '\n  <link rel="alternate" hreflang="x-default" href="' + ORIGIN + route({'slug': ''}, page) + '">'
        source = source.replace('</head>', alternate + '\n</head>')
    manifest_url = ('/' + locale['slug'] if locale['slug'] else '') + '/site.webmanifest'
    source = source.replace('rel="manifest" href="/site.webmanifest"', 'rel="manifest" href="' + manifest_url + '"')
    picker = appearance_picker(locale) + language_picker(locale, locales, page).replace(
        'class="language-picker"', 'class="language-picker" name="website-preferences"', 1)
    if '<div class="nav__actions">' in source:
        source = source.replace('<div class="nav__actions">', '<div class="nav__actions">\n        ' + picker, 1)
    elif '<main class="notfound">' in source:
        source = source.replace('<main class="notfound">', '<main class="notfound">\n    <div class="notfound__preferences">' + picker + '</div>', 1)
    else:
        raise ValueError('No language picker placement for ' + page)
    data_path = ('/' + locale['slug'] if locale['slug'] else '') + '/locale-data.js'
    data_script = '<script src="' + data_path + '" defer></script>\n  '
    if '<script src="/main.js" defer></script>' in source:
        source = source.replace('<script src="/main.js" defer></script>', data_script + '<script src="/main.js" defer></script>')
    else:
        source = source.replace('</head>', '  ' + data_script + '\n</head>')
    source = source.replace('</head>', '  <script src="/language.js" defer></script>\n</head>')
    return source


def build(output, source_dir=ROOT / 'site', app_directory=ROOT / 'Localization', notes_dir=ROOT / 'docs/release-notes', github_releases=None):
    source_path, output_path = source_dir.resolve(), output.resolve()
    if source_path == output_path or source_path in output_path.parents or output_path in source_path.parents:
        raise ValueError('Build output must be separate from website sources')
    pages, keys = sources(source_dir)
    locales = catalogs(source_dir / 'localization', keys, app_directory)
    releases = load_releases(notes_dir, github_releases)
    for locale in locales:
        for page, source in pages.items():
            path = output / route(locale, page).lstrip('/')
            if page != '404':
                path /= 'index.html'
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(render(source, locale, locales, page, releases=releases))
        manifest = json.loads((source_dir / 'site.webmanifest').read_text())
        manifest.update(lang=locale['code'], dir=locale.get('direction', 'ltr'), start_url=route(locale, 'home'),
                        description=locale['strings']['Strata Files is a fast, private file manager and Finder alternative for macOS, free and open source.'])
        (output / locale['slug'] / 'site.webmanifest').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
        public = {key: locale[key] for key in ['code', 'language', 'slug']}
        public['strings'] = {key: html.unescape(locale['strings'][key]) for key in UI}
        public['locales'] = [{**{key: other[key] for key in ['code', 'language', 'slug']}, 'aliases': other.get('aliases', []),
                              'suggestion': other['strings'][UI[2]].replace('{language}', other['language']),
                              'continue': other['strings'][UI[3]].replace('{language}', other['language']),
                              'dismiss': other['strings']['Dismiss']} for other in locales]
        path = output / locale['slug'] / 'locale-data.js'
        path.write_text('window.strataLocale = ' + json.dumps(public, ensure_ascii=False).replace('<', '\\u003c') + ';\n')
    # Reuse the source image sitemap while expanding its canonical pages to every locale.
    ns = 'http://www.sitemaps.org/schemas/sitemap/0.9'
    image_ns = 'http://www.google.com/schemas/sitemap-image/1.1'
    ET.register_namespace('', ns)
    ET.register_namespace('image', image_ns)
    original = ET.fromstring((source_dir / 'sitemap.xml').read_text())
    sitemap = ET.Element('{' + ns + '}urlset')
    for locale in locales:
        for page in ['home', 'privacy', 'releases']:
            node = ET.SubElement(sitemap, '{' + ns + '}url')
            ET.SubElement(node, '{' + ns + '}loc').text = ORIGIN + route(locale, page)
            if page == 'home':
                for image in original.findall('.//{' + image_ns + '}image'):
                    node.append(ET.fromstring(ET.tostring(image)))
    ET.indent(sitemap, space='  ')
    ET.ElementTree(sitemap).write(output / 'sitemap.xml', encoding='utf-8', xml_declaration=True)
    # Machine-readable discovery follows the same catalog list as the human language picker.
    llms = output / 'llms.txt'
    if llms.exists():
        links = '\n'.join('- [' + locale['language'] + '](' + ORIGIN + route(locale, 'home') + ')' for locale in locales)
        llms.write_text(llms.read_text().rstrip() + '\n\n## Website languages\n\n' + links + '\n')
    # Translation sources are build inputs, not extra public endpoints.
    import shutil
    shutil.rmtree(output / 'localization', ignore_errors=True)
    return locales


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['extract', 'check', 'build'])
    parser.add_argument('output', type=Path, nargs='?')
    args = parser.parse_args()
    _, keys = sources(ROOT / 'site')
    if args.command == 'extract':
        path = ROOT / 'site/localization/en.json'
        locale = json.loads(path.read_text()) if path.exists() else {'code': 'en', 'language': 'English', 'slug': '', 'ogLocale': 'en_US'}
        locale['strings'] = {key: key for key in keys}
        path.write_text(json.dumps(locale, ensure_ascii=False, indent=2) + '\n')
    elif args.command == 'check':
        locales = catalogs(ROOT / 'site/localization', keys, ROOT / 'Localization')
        print(f'{len(locales)} complete website catalogs, {len(keys)} messages each')
    elif not args.output:
        parser.error('build requires an output directory')
    else:
        locales = build(args.output)
        print(f'Built {len(locales)} website languages')


if __name__ == '__main__':
    main()
