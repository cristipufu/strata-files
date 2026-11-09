const { test, expect } = require('@playwright/test');
const background = { light: 'rgb(250, 249, 253)', dark: 'rgb(7, 6, 13)' };
const key = 'strata-website-appearance';

async function prepare(page) {
  await page.route('https://api.github.com/**', r => r.fulfill({ json: {} }));
  await page.route('https://plausible.io/**', r => r.fulfill({ body: '', contentType: 'application/javascript' }));
}

async function choose(page, choice) {
  await page.locator('.appearance-picker summary').click();
  await page.locator(`[data-appearance-choice="${choice}"]`).click();
  await expect(page.locator('.appearance-picker summary')).toBeFocused();
  await expect(page.locator(`[data-appearance-choice="${choice}"]`)).toHaveAttribute('aria-pressed', 'true');
}

for (const colorScheme of ['light', 'dark']) {
  test(`${colorScheme} keeps text and primary buttons readable`, async ({ page }) => {
    await prepare(page);
    await page.emulateMedia({ colorScheme });
    await page.goto('/');
    const contrast = await page.evaluate(() => {
      const rgb = color => color.match(/[\d.]+/g).slice(0, 3).map(Number);
      const luminance = values => values.map(value => {
        const c = value / 255;
        return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
      }).reduce((sum, c, index) => sum + c * [0.2126, 0.7152, 0.0722][index], 0);
      const ratio = (first, second) => {
        const a = luminance(first), b = luminance(second);
        return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
      };
      const base = rgb(getComputedStyle(document.body).backgroundColor);
      return ['.hero__lede', '.hero__meta', '.eyebrow', '.developer-groups li', '.btn--primary'].map(selector => {
        const style = getComputedStyle(document.querySelector(selector));
        return ratio(rgb(style.color), selector === '.btn--primary' ? rgb(style.backgroundColor) : base);
      });
    });
    expect(contrast.every(value => value >= 4.5)).toBe(true);
    await page.locator('.hero .btn--primary').hover();
    await expect(page.locator('.hero .btn--primary')).toHaveCSS('transform', 'none');
  });

  test(`system ${colorScheme} applies to home, privacy and 404 and tracks live changes`, async ({ page }) => {
    await prepare(page);
    await page.emulateMedia({ colorScheme });
    for (const route of ['/', '/fr/privacy/', '/de/releases/', '/ro/404.html']) {
      await page.goto(route);
      await expect(page.locator('body')).toHaveCSS('background-color', background[colorScheme]);
      await expect(page.locator('html')).toHaveAttribute('data-appearance', 'system');
    }
    const changed = colorScheme === 'light' ? 'dark' : 'light';
    await page.emulateMedia({ colorScheme: changed });
    await expect(page.locator('body')).toHaveCSS('background-color', background[changed]);
    await expect(page.locator('meta[name="theme-color"]')).toHaveAttribute('content', background[changed]);
  });

  test(`without JavaScript the site still follows system ${colorScheme}`, async ({ browser }) => {
    const context = await browser.newContext({ javaScriptEnabled: false, colorScheme });
    const page = await context.newPage();
    for (const route of ['/', '/de/privacy/', '/uk/404.html']) {
      await page.goto(route);
      await expect(page.locator('body')).toHaveCSS('background-color', background[colorScheme]);
      await expect(page.locator('.appearance-picker')).toBeHidden();
      await expect(page.locator('h1')).toBeVisible();
    }
    await context.close();
  });
}

test('an explicit appearance survives reloads, languages and system changes; System restores automatic mode', async ({ page }) => {
  await prepare(page);
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.goto('/');
  await choose(page, 'light');
  expect(await page.evaluate(key => localStorage.getItem(key), key)).toBe('light');
  await expect(page.locator('body')).toHaveCSS('background-color', background.light);
  await page.goto('/ja/privacy/');
  await page.reload();
  await expect(page.locator('body')).toHaveCSS('background-color', background.light);
  await choose(page, 'dark');
  await page.emulateMedia({ colorScheme: 'light' });
  await expect(page.locator('body')).toHaveCSS('background-color', background.dark);
  await choose(page, 'system');
  await expect(page.locator('body')).toHaveCSS('background-color', background.light);
  expect(await page.evaluate(key => localStorage.getItem(key), key)).toBeNull();
  await page.emulateMedia({ colorScheme: 'dark' });
  await expect(page.locator('body')).toHaveCSS('background-color', background.dark);
});

test('keyboard access, Escape, outside clicks and mutually exclusive pickers work', async ({ page }) => {
  await prepare(page);
  await page.goto('/');
  const summary = page.locator('.appearance-picker summary');
  await summary.focus();
  await page.keyboard.press('Enter');
  await page.keyboard.press('Tab');
  await expect(page.locator('[data-appearance-choice="system"]')).toBeFocused();
  await page.keyboard.press('Tab');
  await page.keyboard.press('Enter');
  await expect(summary).toBeFocused();
  await expect(page.locator('[data-appearance-choice="light"]')).toHaveAttribute('aria-pressed', 'true');
  await summary.click();
  await page.locator('.language-picker summary').click();
  await expect(page.locator('.appearance-picker')).not.toHaveAttribute('open', '');
  await summary.click();
  await expect(page.locator('.language-picker')).not.toHaveAttribute('open', '');
  await page.keyboard.press('Escape');
  await expect(summary).toBeFocused();
  await expect(page.locator('.appearance-picker')).not.toHaveAttribute('open', '');
  await summary.click();
  await page.locator('h1').click();
  await expect(page.locator('.appearance-picker')).not.toHaveAttribute('open', '');
});

test('unavailable storage keeps the system default and still permits a choice in this tab', async ({ page }) => {
  await prepare(page);
  await page.emulateMedia({ colorScheme: 'light' });
  await page.addInitScript(() => {
    Object.defineProperty(window, 'localStorage', { get() { throw new DOMException('Blocked', 'SecurityError'); } });
  });
  await page.goto('/');
  await expect(page.locator('body')).toHaveCSS('background-color', background.light);
  await choose(page, 'dark');
  await expect(page.locator('body')).toHaveCSS('background-color', background.dark);
});

test('appearance choices propagate to another open tab', async ({ context, page }) => {
  await prepare(page);
  await page.goto('/');
  const other = await context.newPage();
  await prepare(other);
  await other.goto('/fr/');
  await choose(page, 'dark');
  await expect(other.locator('body')).toHaveCSS('background-color', background.dark);
  await expect(other.locator('[data-appearance-choice="dark"]')).toHaveAttribute('aria-pressed', 'true');
  await choose(page, 'light');
  await expect(other.locator('body')).toHaveCSS('background-color', background.light);
});
