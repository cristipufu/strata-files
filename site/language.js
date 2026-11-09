// Language links work without JavaScript. Browser preferences offer a switch; they never override a URL.
(() => {
  const locale = window.strataLocale;
  if (!locale) return;
  const key = 'strata-website-language';
  const route = (language) => {
    const page = /\/privacy\/$/.test(location.pathname) ? 'privacy/' : /\/releases\/$/.test(location.pathname) ? 'releases/' : /404\.html$/.test(location.pathname) ? '404.html' : '';
    return `/${language.slug ? `${language.slug}/` : ''}${page}${location.hash}`;
  };
  const remember = (code) => {
    try { localStorage.setItem(key, code); } catch { /* Language links still work without storage. */ }
  };
  document.querySelectorAll('[data-language]').forEach((link) => {
    link.addEventListener('click', () => { remember(link.dataset.language); link.hash = location.hash; });
  });
  document.querySelectorAll('.language-picker').forEach((picker) => {
    document.addEventListener('click', (event) => { if (!picker.contains(event.target)) picker.open = false; });
    picker.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') {
        picker.open = false;
        picker.querySelector('summary').focus();
      }
    });
  });
  let saved;
  try { saved = localStorage.getItem(key); } catch { /* Browser language can still be suggested. */ }
  // An explicit page or picker choice always wins. Only suggest a browser language on the default homepage.
  if (saved || location.pathname !== '/') return;
  const match = (preference) => {
    let code = preference.toLowerCase();
    while (code) {
      const found = locale.locales.find((candidate) => [candidate.code, ...candidate.aliases].some((alias) => alias.toLowerCase() === code));
      if (found) return found;
      code = code.includes('-') ? code.slice(0, code.lastIndexOf('-')) : '';
    }
    return null;
  };
  const preferred = (navigator.languages || [navigator.language]).map(match).find(Boolean);
  if (!preferred || preferred.code === locale.code) return;
  const notice = document.createElement('aside');
  notice.className = 'language-suggestion';
  notice.lang = preferred.code;
  notice.dir = 'auto';
  notice.setAttribute('aria-label', preferred.suggestion);
  const text = Object.assign(document.createElement('p'), { textContent: preferred.suggestion });
  const link = Object.assign(document.createElement('a'), { className: 'btn btn--primary', textContent: preferred.continue, href: route(preferred) });
  link.hreflang = preferred.code;
  link.addEventListener('click', () => remember(preferred.code));
  const dismiss = Object.assign(document.createElement('button'), { className: 'language-suggestion__dismiss', textContent: '×', type: 'button' });
  dismiss.setAttribute('aria-label', preferred.dismiss);
  dismiss.addEventListener('click', () => { remember(locale.code); notice.remove(); });
  notice.append(text, link, dismiss);
  document.body.append(notice);
})();
