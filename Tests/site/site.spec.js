const { test, expect } = require('@playwright/test');
test.use({ colorScheme: 'dark' });

async function prepare(page) {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.addInitScript(() => {
    window.policyViolations = [];
    document.addEventListener('securitypolicyviolation', event => {
      window.policyViolations.push({ directive: event.violatedDirective, blocked: event.blockedURI });
    });
  });
  await page.route('https://api.github.com/repos/cristipufu/strata-files**', route => route.fulfill({
    json: route.request().url().endsWith('/releases/latest')
      ? { tag_name: 'v0.6.4', assets: [{ name: 'Strata.dmg', size: 9000000,
          browser_download_url: 'https://github.com/cristipufu/strata-files/releases/download/v0.6.4/Strata.dmg' }] }
      : { stargazers_count: 1234 },
  }));
  await page.route('https://plausible.io/js/**', route => route.fulfill({
    contentType: 'application/javascript',
    body: 'window.analyticsLoaded = true; fetch("https://plausible.io/api/event", {method: "POST", body: "test"});',
  }));
  await page.route('https://plausible.io/api/event', route => route.fulfill({ status: 202, body: 'ok' }));
  return errors;
}

for (const width of [320, 390, 768, 1440]) {
  test(`homepage controls, layout and CSP at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    const errors = await prepare(page);
    await page.goto('/');
    expect(await page.locator('header.nav').evaluate(el => el.getBoundingClientRect().top)).toBe(0);
    await expect(page.locator('[data-download]').first()).toHaveAttribute('href', /\/v0\.6\.4\/Strata\.dmg$/);
    await expect.poll(() => page.evaluate(() => window.analyticsLoaded)).toBe(true);
    const viewTabs = page.getByRole('tablist', { name: 'Views', exact: true }).getByRole('tab');
    await expect(viewTabs).toHaveText(['Icons ⌘1', 'List ⌘2', 'Columns ⌘3', 'Gallery ⌘4', 'Disk Usage ⌘5', 'Dual Pane ⌘\\']);
    for (const root of await page.locator('[data-tabs]').all()) {
      const tabs = root.getByRole('tab');
      for (const tab of await tabs.all()) {
        await tab.click();
        await expect(tab).toHaveAttribute('aria-selected', 'true');
        const panel = page.locator('#' + await tab.getAttribute('aria-controls'));
        await expect(panel).toBeVisible();
        await panel.scrollIntoViewIfNeeded();
        await expect.poll(() => panel.locator('img').evaluateAll(images =>
          images.length > 0 && images.every(image => image.complete && image.naturalWidth > 0))).toBe(true);
      }
      await tabs.first().focus();
      await page.keyboard.press('ArrowRight');
      await expect(tabs.nth(1)).toBeFocused();
      await expect(tabs.nth(1)).toHaveAttribute('aria-selected', 'true');
    }
    const targets = await page.locator('.nav a, .footer__links a, .tabs__list button, .pill, .privacy-policy-link').evaluateAll(elements =>
      elements.filter(el => el.getClientRects().length).map(el => ({
        text: el.textContent.trim(), width: el.getBoundingClientRect().width, height: el.getBoundingClientRect().height,
      })));
    expect(targets.filter(target => target.height < 43.99 || target.width < 43.99)).toEqual([]);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    expect(await page.locator('header.nav').evaluate(el => el.getBoundingClientRect().top)).toBe(0);
    expect(await page.evaluate(() => window.policyViolations)).toEqual([]);
    expect(errors).toEqual([]);
    await expect(page.locator('#themes .lede')).toHaveText(
      'Follow the system or choose Light or Dark. Keep native Mac colors, or pick one of seventeen themes.');
    for (const image of await page.locator('img:visible').all()) {
      await image.scrollIntoViewIfNeeded();
      await expect.poll(() => image.evaluate(el => el.complete && el.naturalWidth > 0)).toBe(true);
    }
  });
}

for (const path of ['/privacy/', '/404.html']) {
  test(`${path} keeps its styles and links under CSP`, async ({ page }) => {
    const errors = await prepare(page);
    await page.goto(path);
    await expect(page.locator('h1')).toBeVisible();
    expect(await page.locator('body').evaluate(el => getComputedStyle(el).backgroundColor)).toBe('rgb(7, 6, 13)');
    expect(await page.evaluate(() => window.policyViolations)).toEqual([]);
    expect(errors).toEqual([]);
  });
}

test('CSP refuses injected inline scripts and unexpected external connections', async ({ page }) => {
  await prepare(page);
  await page.goto('/');
  await page.evaluate(() => {
    const script = document.createElement('script');
    script.textContent = 'window.unexpectedInlineExecution = true';
    document.head.append(script);
    fetch('https://example.invalid/unexpected').catch(() => {});
  });
  await expect.poll(() => page.evaluate(() => window.policyViolations.length)).toBeGreaterThanOrEqual(2);
  expect(await page.evaluate(() => window.unexpectedInlineExecution)).toBeUndefined();
  const blocked = await page.evaluate(() => window.policyViolations.map(v => v.blocked));
  expect(blocked).toContain('inline');
  expect(blocked).toContain('https://example.invalid/unexpected');
});
