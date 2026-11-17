#!/usr/bin/env python3
"""Version website assets and add the CSP supported by GitHub Pages' static HTML."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import html
import json
from pathlib import Path
import re
import sys
import time
from urllib.error import HTTPError
from urllib.parse import urljoin, urlsplit
from urllib.request import urlopen

CSP = "; ".join([
    "default-src 'none'", "script-src 'self' https://plausible.io",
    "style-src 'self' 'unsafe-inline'", "img-src 'self' data:", "font-src 'self'",
    "connect-src https://api.github.com https://plausible.io", "manifest-src 'self'",
    "base-uri 'none'", "form-action 'none'", "object-src 'none'",
])
ASSET = re.compile(r"immutable/([0-9a-f]{64})-([A-Za-z0-9_.-]+)\Z")
EXTENSIONS = {'.js', '.css', '.png', '.jpg', '.jpeg', '.svg', '.webp', '.ico', '.webmanifest'}
RETRYABLE_HTTP_ERRORS = frozenset({408, 429, 500, 502, 503, 504})
DOWNLOAD_RETRY_DELAYS = (1, 2)


def fetch(url, limit):
    for attempt in range(len(DOWNLOAD_RETRY_DELAYS) + 1):
        try:
            return fetch_once(url, limit)
        except HTTPError as error:
            error.close()
            if error.code not in RETRYABLE_HTTP_ERRORS or attempt == len(DOWNLOAD_RETRY_DELAYS):
                raise
            delay = DOWNLOAD_RETRY_DELAYS[attempt]
            print(f'HTTP {error.code} downloading {url}; retrying in {delay}s.', file=sys.stderr, flush=True)
            time.sleep(delay)


def fetch_once(url, limit):
    with urlopen(url, timeout=30) as response:
        if urlsplit(response.url).scheme != 'https' or urlsplit(response.url).netloc != urlsplit(url).netloc:
            raise ValueError('Asset download redirected away from the website')
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError('Website asset exceeded the download limit')
    return data


def restore_previous(root, origin):
    """Keep old URLs working for cached HTML and tabs left open across deployments."""
    if urlsplit(origin).scheme != 'https':
        raise ValueError('Previous site must use HTTPS')
    try:
        manifest = json.loads(fetch(origin.rstrip('/') + '/asset-manifest.json', 1024 * 1024))
    except HTTPError as error:
        if error.code == 404:
            return  # First deployment with versioned assets.
        raise
    if not isinstance(manifest, list) or len(manifest) > 2000:
        raise ValueError('Unexpected asset manifest')
    for name in manifest:
        if not isinstance(name, str) or not ASSET.fullmatch(name):
            raise ValueError('Unsafe asset path in manifest')
    def download(name):
        data = fetch(origin.rstrip('/') + '/' + name, 8 * 1024 * 1024)
        if hashlib.sha256(data).hexdigest() != ASSET.fullmatch(name)[1]:
            raise ValueError('Previous asset does not match its filename: ' + name)
        return name, data
    if len(set(manifest)) != len(manifest):
        raise ValueError('Duplicate asset paths in manifest')
    total = 0
    with ThreadPoolExecutor(max_workers=4) as pool:
        # Bound both in-flight downloads and completed results, even if an early request is slow.
        for start in range(0, len(manifest), 4):
            for name, data in pool.map(download, manifest[start:start + 4]):
                total += len(data)
                if total > 128 * 1024 * 1024:
                    raise ValueError('Asset archive needs a size review before publishing')
                target = root / name
                target.parent.mkdir(exist_ok=True)
                target.write_bytes(data)



def prepare(root):
    root = Path(root)
    assets = sorted(p for p in root.rglob('*') if p.is_file()
                    and p.suffix in EXTENSIONS and 'immutable' not in p.relative_to(root).parts)
    mapping = {}
    (root / 'immutable').mkdir(exist_ok=True)

    def version(path):
        data = path.read_bytes()
        name = 'immutable/' + hashlib.sha256(data).hexdigest() + '-' + path.name
        (root / name).write_bytes(data)
        mapping['/' + path.relative_to(root).as_posix()] = '/' + name

    def rewrite(value, base):
        parsed = urlsplit(urljoin('https://stratafiles.app/' + base, value))
        if parsed.scheme != 'https' or parsed.netloc != 'stratafiles.app' or parsed.query or parsed.fragment:
            return value
        return mapping.get(parsed.path, value)

    for asset in assets:
        if asset.suffix not in {'.css', '.webmanifest'}:
            version(asset)
    for asset in assets:
        base = asset.relative_to(root).as_posix()
        if asset.suffix == '.css':
            css = re.sub(r'url\([\'\"]?([^\)\'\"]+)[\'\"]?\)',
                         lambda m: 'url("' + rewrite(m[1], base) + '")', asset.read_text())
            asset.write_text(css)
            version(asset)
        elif asset.suffix == '.webmanifest':
            manifest = json.loads(asset.read_text())
            for icon in manifest.get('icons', []):
                icon['src'] = rewrite(icon['src'], base)
            asset.write_text(json.dumps(manifest, indent=2) + '\n')
            version(asset)

    for page in root.rglob('*.html'):
        base = page.relative_to(root).as_posix()
        content = page.read_text()
        for script in re.finditer(r'<script\b([^>]*)>(.*?)</script>', content, flags=re.S):
            if not re.search(r'\bsrc=', script[1]) and 'application/ld+json' not in script[1] and script[2].strip():
                raise ValueError('Executable inline JavaScript in ' + base)
        # Keep the homepage's first paint independent of a stylesheet request.
        if base == 'index.html' or '<main id="main">' in content:
            link = '<link rel="stylesheet" href="/styles.css">' if 'href="/styles.css"' in content else '<link rel="stylesheet" href="styles.css">'
            if content.count(link) != 1:
                raise ValueError('Homepage must link styles.css exactly once before packaging')
            content = content.replace(link, '<style>\n' + (root / 'styles.css').read_text() + '</style>')
        def attribute(match):
            name, quote, value = match[1], match[2], match[3]
            if name in ('srcset', 'imagesrcset'):
                value = ', '.join(' '.join([rewrite(parts[0], base)] + parts[1:])
                                  for item in value.split(',') if (parts := item.strip().split()))
            else:
                value = rewrite(value, base)
            return name + '=' + quote + value + quote
        content = re.sub(r'\b(href|src|srcset|imagesrcset)=([\'\"])(.*?)\2', attribute, content)
        charset = '<meta charset="utf-8">'
        if content.count(charset) != 1:
            raise ValueError('Missing unique charset declaration in ' + base)
        content = content.replace(charset, charset + '\n  <meta http-equiv="Content-Security-Policy" content="'
                                  + html.escape(CSP, quote=True) + '">', 1)
        page.write_text(content)
    manifest = sorted(p.relative_to(root).as_posix() for p in (root / 'immutable').iterdir() if p.is_file())
    (root / 'asset-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--previous-origin')
    args = parser.parse_args()
    if args.previous_origin:
        restore_previous(args.directory, args.previous_origin)
    prepare(args.directory)
