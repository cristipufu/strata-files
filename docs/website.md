# Website checks and publishing

The public site is built from `site/` and the real app screenshots in `docs/screenshots/`.
The themes stack is composed from actual Strata windows with demo files, including native System Light.
Its PNG is shared by the README and the website; the build creates responsive lossless WebP versions
at 800, 1100, 1400, 2360 and the original 3960 pixels. The homepage preload and image use the same
responsive candidates so only the appropriate size is downloaded.

The Color Themes section pairs its copy with the approved Appearance settings capture, `docs/screenshots/appearance.png`.
It shows System and the original fourteen themes in the actual settings window, with its native border, shadow and transparency.
The portrait image is displayed at up to 632 CSS pixels; lossless WebP delivery preserves palette colors and alpha at
480, 800, 1100 and the original 1264 pixels. The README shares the primary `appearance.webp` export.

The Quick Look image uses live Strata windows with Acme Studio demo files. Native window captures retain the real
controls, materials, borders and shadows at their screen positions; the selected Brand Assets folder stays visible
above the preview. Its PNG master is `docs/screenshots/quicklook.png`. The README uses the matching WebP export;
the website serves 480, 800, 1100, 1400 and 2120-pixel versions. Keep it immediately after Disk Usage in both the README
and the homepage.

The Views tabs and README show all five views plus Dual Pane, captured from the same live app and Acme Studio
demo files. Columns opens Photos → Selects → Autumn Campaign with a photo selected at the deepest level.
Native window borders, shadows and color profiles are retained. High-quality WebP delivery is capped at twice the
1060-point display width, with smaller responsive versions; alpha stays at full precision. PNG masters stay unchanged.
List and Disk Usage use their own captures. The earlier Disk Usage section keeps its previous image with the inspector,
while the Views tab uses the new map. Demo photographs are from
[Unsplash](https://unsplash.com/license), including
[Alpine Morning](https://images.unsplash.com/photo-1464822759023-fed622ff2c3b),
[Lake Reflection](https://images.unsplash.com/photo-1470770841072-f978cf4d019e),
[Golden Hour](https://images.unsplash.com/photo-1500530855697-b586d89ba3ee),
[Forest Trail](https://images.unsplash.com/photo-1448375240586-882707db888b),
[Ocean Light](https://images.unsplash.com/photo-1507525428034-b723cf961d3e) and
[Mountain Pass](https://images.unsplash.com/photo-1501785888041-af3ef285b470).

Run `scripts/site.sh --refresh-readme` after changing these PNG masters to refresh their shared README WebP exports.

Run the same checks locally as the Website workflow:

```sh
python3 -m unittest discover -s Tests -p 'test_site*.py'
scripts/site.sh
npm ci --prefix Tests/site --ignore-scripts
cd Tests/site && npx playwright install chromium && npm test
```

The browser checks cover downloads, analytics initialization, tab controls and keyboard navigation,
image loading, narrow layouts, 44-pixel touch targets and CSP enforcement. Packaging tests verify
fingerprints, rewritten URLs, retention of previous assets and rejection of unsafe or corrupt manifests.
Pull requests run these checks; main publishes only after they pass.

## Security and caching

`scripts/site-assets.py` adds a Content Security Policy before resources load in each HTML document.
Executable JavaScript is external; local scripts and Plausible are allowed. Network requests are limited
to GitHub's API and Plausible. Inline CSS remains allowed for the homepage's embedded styles and artwork.
Changes to external resources must update this policy and the browser checks together.

GitHub Pages does not support custom HTTP response headers. The HTML policy cannot set
`frame-ancestors`, HSTS, `X-Frame-Options` or `X-Content-Type-Options`, nor can it provide report-only CSP.
No CDN or DNS configuration is changed here. The `.app` domain is already covered by TLD HSTS preload.
`llms.txt` and `llms-full.txt` remain ordinary text resources, not HTML pages.

Assets have content-hashed URLs, so changes get new URLs. GitHub Pages still controls their cache lifetime:
fingerprinting alone does not enable long-lived `immutable` caching. Original asset aliases stay available
for social metadata and external links. Publishing downloads the previous deployment's asset manifest and
retains its verified hashed files, keeping cached pages working across deployments. Downloads are restricted
to HTTPS on the same host, checked against SHA-256 filenames and bounded by per-file and total size limits.
Only a missing manifest (404 on the first such deployment) is ignored; other errors stop publishing.

The retained archive is deliberately bounded at 2,000 files or 128 MiB. Reaching either limit requires a
retention review rather than silently breaking old URLs. If hosting later supports response headers, use
short HTML caching and long-lived immutable caching for `/immutable/`, and enforce framing restrictions
through HTTP headers. Do not claim those protections are active until live responses confirm them.

## Website localization

The English templates in `site/index.html`, `site/privacy/index.html` and `site/404.html` are shared by every
language. `scripts/site-localize.py` builds complete HTML pages before asset packaging. English stays at `/`;
other languages use their lower-case language code, for example `/fr/`, `/pt-br/` and `/zh-hant/`. Each has its own
privacy page and a translated `404.html`. GitHub Pages uses the root English `404.html` for unknown URLs; its
language links let readers switch explicitly.

A page has its own canonical URL, translated title, description, social metadata and structured data, plus reciprocal
`hreflang` links to every language and an English `x-default`. The FAQ's structured data reuses the visible answers.
The sitemap includes every homepage and privacy page, and `llms.txt` gains the same language links automatically.
Screenshots and assets are shared across languages. Their English demo files and working English search examples
remain intact; their descriptions and surrounding content are translated.

The native-language picker uses ordinary links and works without JavaScript. On the default homepage, browser language
preferences can suggest another language, without redirecting. An explicit URL always wins; a picker choice or a dismissed
suggestion is remembered locally. Detection uses language tags, including regional aliases for Chinese, Portuguese and
Norwegian, without IP geolocation or a translation service at runtime. This follows Google's guidance on
[multilingual URLs and language selection](https://developers.google.com/search/docs/specialty/international/managing-multi-regional-sites)
and [localized versions](https://developers.google.com/search/docs/specialty/international/localized-versions).

### Add a language

1. Copy `site/localization/en.json` to a file named for the new language, such as `fi.json`.
2. Set `code` to `fi`, `language` to its native name (`Suomi`), `slug` to the lower-case code (`fi`), and `ogLocale`
   to its Open Graph locale (`fi_FI`). Optional `aliases` list browser-language aliases; `direction` can be `rtl`.
3. Translate all values under `strings`, retaining the English keys, inline HTML, links, command examples, keycaps
   and `{placeholders}`. Keep `Strata Files` as a product name. Review terminology against the app catalog, along
   with regional vocabulary, register, punctuation, dates and keyboard-key names. Brazilian and European Portuguese,
   and Simplified and Traditional Chinese, have separate catalogs.
4. Run the checks below. The catalog automatically creates its routes, picker entries, language matching, SEO links,
   sitemap entries and machine-readable discovery links. No language arrays or page copies need editing.

```sh
python3 scripts/site-localize.py extract   # after editing English website text
python3 scripts/site-localize.py check
python3 -m unittest discover -s Tests -p 'test_site*.py'
scripts/site.sh
npm test --prefix Tests/site
```

Extraction updates only English. Complete the corresponding translations before committing changed copy; the build
rejects missing, obsolete or blank messages, malformed markup, altered commands/links/placeholders, draft markers and
changed product names. Every app language must have a website catalog. Website-only languages can also be added.
Translations are checked-in build inputs: the production build never requests translations from an external service.

Browser checks discover catalogs too. They cover each language at phone and desktop widths, translated downloads,
keyboard access to the picker, privacy/404 navigation, pages without JavaScript, browser-language aliases, remembered
choices, section anchors and CSP. Python checks verify catalog completeness, schema/visible-answer consistency,
reciprocal SEO links, sitemap coverage, and adding a language without changing application code.

## Website appearance

The website follows the system's light or dark appearance by default, including live changes. The header's
appearance picker offers System, Light and Dark in every language. Light and Dark overrides are remembered in
local storage and shared across pages, languages and open tabs; System clears the override. Blocked storage still
allows a choice for the current page. This setting is separate from the app's color themes.

`appearance.js` runs before styles paint, applying a saved choice without flashing the opposite appearance.
CSS `light-dark()` colors follow the system even without JavaScript; the picker stays hidden when it cannot work.
Older browsers without `light-dark()` retain the original dark palette. The same palette tokens cover the homepage,
privacy pages, 404 pages, navigation, menus, cards and demos. Existing app screenshots retain their actual colors.

Browser checks cover both appearances in every language at narrow and desktop widths, keyboard access, live system
changes, persistence, blocked storage, tab synchronization, no-JavaScript fallback and the fixed header.
