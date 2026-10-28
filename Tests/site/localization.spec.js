const { test, expect } = require('@playwright/test');
const fs = require('node:fs');
const path = require('node:path');
const locales = fs.readdirSync(path.join(__dirname, '../../site/localization')).filter(name => name.endsWith('.json'))
  .map(name => JSON.parse(fs.readFileSync(path.join(__dirname, '../../site/localization', name), 'utf8')));
const route = (locale, page = '') => `/${locale.slug ? `${locale.slug}/` : ''}${page}`;

async function prepare(page) {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.addInitScript(() => {
    window.policyViolations = [];
    document.addEventListener('securitypolicyviolation', event => window.policyViolations.push(event.violatedDirective));
  });
  await page.route('https://api.github.com/**', r => r.fulfill({ json: r.request().url().endsWith('/releases/latest')
    ? { tag_name: 'v0.7.1', assets: [{ name: 'Strata.dmg', size: 9000000, browser_download_url: 'https://github.com/cristipufu/strata-files/releases/download/v0.7.1/Strata.dmg' }] }
    : { stargazers_count: 1234 } }));
  await page.route('https://plausible.io/**', r => r.fulfill({ body: '', contentType: 'application/javascript' }));
  return errors;
}

for (const locale of locales) {
  test(`${locale.code}: translated home, picker, privacy and 404 remain usable`, async ({ page }) => {
    const errors = await prepare(page);
    for (const [width, colorScheme] of [[320, 'light'], [1440, 'light'], [320, 'dark'], [1440, 'dark']]) {
      await page.emulateMedia({ colorScheme });
      await page.setViewportSize({ width, height: 900 });
      await page.goto(route(locale));
      await expect(page.locator('html')).toHaveAttribute('lang', locale.code);
      await expect(page.locator('body')).toHaveCSS('background-color', colorScheme === 'light' ? 'rgb(250, 249, 253)' : 'rgb(7, 6, 13)');
      await page.locator('.appearance-picker summary').click();
      await expect(page.locator('[data-appearance-choice]')).toHaveText(
        ['System', 'Light', 'Dark'].map(key => locale.strings[key]));
      const appearanceBounds = await page.locator('.appearance-picker__options').boundingBox();
      expect(appearanceBounds.x).toBeGreaterThanOrEqual(0);
      expect(appearanceBounds.x + appearanceBounds.width).toBeLessThanOrEqual(width);
      await page.keyboard.press('Escape');
      const groups = page.locator('.developer-groups article');
      await expect(groups).toHaveCount(3);
      for (const [index, heading] of ['Repositories', 'Servers', 'Containers'].entries()) {
        await expect(groups.nth(index).locator('h3')).toHaveText(locale.strings[heading]);
        await expect(groups.nth(index).locator('li')).toHaveCount(3);
      }
      await expect(page.locator('#themes .lede')).toHaveText(locale.strings[
        'Follow the system or choose Light or Dark. Keep native Mac colors, or pick one of seventeen themes.']);
      await expect.poll(() => page.evaluate(() => window.strataLocale?.code)).toBe(locale.code);
      await expect(page.locator('[data-version]').first()).toContainText('0.7.1');
      const version = locale.strings['Version {version} · {size} · Free'].split('{size}')[1];
      await expect(page.locator('[data-version]').first()).toContainText(version.trim());
      await page.locator('.language-picker summary').click();
      await expect(page.locator('.language-picker [data-language]')).toHaveCount(locales.length);
      await expect(page.locator('.language-picker [aria-current]')).toHaveText(locale.language);
      const bounds = await page.locator('.language-picker__options').boundingBox();
      expect(bounds.x).toBeGreaterThanOrEqual(0);
      expect(bounds.x + bounds.width).toBeLessThanOrEqual(width);
      await page.keyboard.press('Escape');
      await expect(page.locator('.language-picker')).not.toHaveAttribute('open', '');
      const nav = await page.locator('.nav__actions').boundingBox();
      expect(nav.x + nav.width).toBeLessThanOrEqual(width);
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      expect(await page.locator('h1, h2, h3').evaluateAll(elements => elements.filter(el => el.scrollWidth > el.clientWidth + 1).map(el => el.textContent))).toEqual([]);
      await expect(page.locator('.privacy-policy-link')).toHaveAttribute('href', route(locale, 'privacy/'));
    }
    for (const suffix of ['privacy/', '404.html']) {
      await page.setViewportSize({ width: 320, height: 900 });
      await page.goto(route(locale, suffix));
      await expect(page.locator('html')).toHaveAttribute('lang', locale.code);
      await expect(page.locator('h1')).toBeVisible();
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      expect(await page.locator('h1, h2, h3').evaluateAll(elements => elements.filter(el => el.scrollWidth > el.clientWidth + 1).map(el => el.textContent))).toEqual([]);
      await page.locator('.language-picker summary').click();
      const french = locales.find(l => l.code === 'fr');
      await expect(page.locator('[data-language="fr"]')).toHaveAttribute('href', route(french, suffix));
    }
    expect(errors).toEqual([]);
    expect(await page.evaluate(() => window.policyViolations)).toEqual([]);
  });
}

test('translated HTML, SEO and language links work without JavaScript', async ({ browser }) => {
  const context = await browser.newContext({ javaScriptEnabled: false });
  const page = await context.newPage();
  for (const locale of locales) {
    await page.goto(route(locale));
    await expect(page.locator('h1')).toBeVisible();
    await expect(page.locator('link[rel="canonical"]')).toHaveAttribute('href', 'https://stratafiles.app' + route(locale));
    await expect(page.locator('link[hreflang]')).toHaveCount(locales.length + 1);
    const schema = JSON.parse(await page.locator('script[type="application/ld+json"]').textContent());
    expect(schema['@graph'][0].inLanguage).toBe(locale.code);
    await page.locator('.language-picker summary').click();
    await expect(page.locator('[data-language="en"]')).toHaveAttribute('href', '/');
  }
  await context.close();
});

for (const [browserLanguage, expected] of [['fr-CA', 'fr'], ['pt-PT', 'pt-PT'], ['pt-BR', 'pt-BR'], ['zh-TW', 'zh-Hant'], ['zh-CN', 'zh-Hans'], ['no-NO', 'nb']]) {
  test(`browser ${browserLanguage} offers ${expected} without redirecting`, async ({ browser }) => {
    const context = await browser.newContext({ locale: browserLanguage });
    const page = await context.newPage();
    await prepare(page);
    await page.goto('/');
    const target = locales.find(l => l.code === expected);
    await expect(page).toHaveURL(/\/$/);
    await expect(page.locator('html')).toHaveAttribute('lang', 'en');
    await expect(page.locator('.language-suggestion')).toHaveAttribute('lang', expected);
    await page.locator('.language-suggestion a').click();
    await expect(page).toHaveURL(new RegExp(target.slug + '/$'));
    await page.goto('/');
    await expect(page.locator('.language-suggestion')).toHaveCount(0);
    await context.close();
  });
}

test('an explicit URL wins over browser language and links keep the current section', async ({ browser }) => {
  const context = await browser.newContext({ locale: 'ru-RU' });
  const page = await context.newPage();
  await prepare(page);
  await page.goto('/fr/#quick-look');
  await expect(page.locator('html')).toHaveAttribute('lang', 'fr');
  await expect(page.locator('.language-suggestion')).toHaveCount(0);
  await page.locator('.language-picker summary').click();
  await page.locator('[data-language="de"]').click();
  await expect(page).toHaveURL(/\/de\/#quick-look$/);
  await context.close();
});
