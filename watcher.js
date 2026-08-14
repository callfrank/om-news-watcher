const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { chromium } = require('playwright');

const ROOT = __dirname;
const SOURCES_FILE = path.join(ROOT, 'sources.json');
const STATE_FILE = path.join(ROOT, 'data', 'state.json');
const ITEMS_FILE = path.join(ROOT, 'data', 'items.json');
const FEED_FILE = path.join(ROOT, 'docs', 'feed.xml');

const MAX_SEEN_PER_SOURCE = 2000;
const MAX_FEED_ITEMS = 500;

function readJson(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch { return fallback; }
}

function saveJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n');
}

function escXml(s = '') {
  return String(s)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
}

function canonicalUrl(raw, base) {
  try {
    const u = new URL(raw, base);
    u.hash = '';
    for (const k of [...u.searchParams.keys()]) {
      if (/^(utm_|fbclid$|gclid$|mc_)/i.test(k)) u.searchParams.delete(k);
    }
    return u.href;
  } catch {
    return null;
  }
}

function idFor(link) {
  return crypto.createHash('sha256').update(link).digest('hex').slice(0, 24);
}

function looksLikeArticle(text, href, sourceUrl) {
  if (!text || text.length < 12 || text.length > 240 || !href) return false;
  let u, src;
  try { u = new URL(href); src = new URL(sourceUrl); } catch { return false; }

  const hostOk = u.hostname === src.hostname || u.hostname.endsWith('.' + src.hostname) || src.hostname.endsWith('.' + u.hostname);
  if (!hostOk) return false;

  const hay = (u.pathname + ' ' + text).toLowerCase();
  const bad = /(impressum|privacy|datenschutz|cookie|karriere|career|jobs|kontakt|contact|login|newsletter|facebook|instagram|linkedin|youtube|x\.com|twitter)/i;
  if (bad.test(hay)) return false;

  const path = u.pathname.toLowerCase();
  const strong = /(news|presse|press|media|meldung|article|story|blog|insight|publication|202[4-9])/.test(path);
  const depth = path.split('/').filter(Boolean).length >= 2;
  return strong || depth;
}

async function dismissCookies(page) {
  const labels = [
    /alle akzeptieren/i, /akzeptieren/i, /zustimmen/i,
    /accept all/i, /^accept$/i, /agree/i, /allow all/i
  ];
  for (const rx of labels) {
    try {
      const btn = page.getByRole('button', { name: rx }).first();
      if (await btn.isVisible({ timeout: 250 })) {
        await btn.click({ timeout: 1000 });
        await page.waitForTimeout(250);
        return;
      }
    } catch {}
  }
}

async function extractConfigured(page, source) {
  const sel = source.selectors || {};
  if (!sel.item) return null;

  return await page.locator(sel.item).evaluateAll((nodes, cfg) => {
    const textOf = (root, selector) => {
      const el = selector ? root.querySelector(selector) : root;
      return el ? (el.textContent || '').replace(/\s+/g, ' ').trim() : '';
    };
    const hrefOf = (root, selector) => {
      const el = selector ? root.querySelector(selector) : root.querySelector('a[href]');
      return el ? el.getAttribute('href') : '';
    };
    return nodes.map(n => ({
      title: textOf(n, cfg.title),
      href: hrefOf(n, cfg.link),
      date: cfg.date ? textOf(n, cfg.date) : ''
    }));
  }, sel);
}

async function extractAutomatic(page, source) {
  const rows = await page.locator('a[href]').evaluateAll(nodes => nodes.map(a => ({
    title: (a.textContent || a.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim(),
    href: a.href || a.getAttribute('href') || '',
    date: ''
  })));
  return rows.filter(r => looksLikeArticle(r.title, r.href, source.url));
}

function dedupe(rows, source) {
  const map = new Map();
  for (const r of rows) {
    const link = canonicalUrl(r.href, source.url);
    const title = (r.title || '').replace(/\s+/g, ' ').trim();
    if (!link || !title) continue;
    if (!map.has(link)) map.set(link, { title, link, date: (r.date || '').trim() });
  }
  return [...map.values()];
}

function makeFeed(items) {
  const now = new Date().toUTCString();
  const body = items.map(item => `\n    <item>\n      <title>${escXml(item.title)}</title>\n      <link>${escXml(item.link)}</link>\n      <guid isPermaLink="false">${escXml(item.guid)}</guid>\n      <pubDate>${escXml(new Date(item.detectedAt).toUTCString())}</pubDate>\n      <description>${escXml('Quelle: ' + item.source)}</description>\n      <source>${escXml(item.source)}</source>\n    </item>`).join('');

  return `<?xml version="1.0" encoding="UTF-8"?>\n<rss version="2.0">\n  <channel>\n    <title>OM News Watcher</title>\n    <link>https://github.com/</link>\n    <description>Neue Meldungen aus beobachteten Websites für onlinemarktplatz.de</description>\n    <language>de-de</language>\n    <lastBuildDate>${now}</lastBuildDate>${body}\n  </channel>\n</rss>\n`;
}

(async () => {
  const sources = readJson(SOURCES_FILE, []).filter(s => s.enabled !== false);
  const state = readJson(STATE_FILE, { seenBySource: {} });
  let items = readJson(ITEMS_FILE, []);

  if (!sources.length) {
    console.log('Keine Quellen aktiviert. Bitte sources.json bearbeiten.');
    fs.mkdirSync(path.dirname(FEED_FILE), { recursive: true });
    fs.writeFileSync(FEED_FILE, makeFeed(items));
    process.exit(0);
  }

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    locale: 'de-DE',
    timezoneId: 'Europe/Berlin',
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140 Safari/537.36 OM-News-Watcher/0.1'
  });

  for (const source of sources) {
    const page = await context.newPage();
    console.log(`Prüfe: ${source.name} — ${source.url}`);
    try {
      await page.goto(source.url, { waitUntil: 'domcontentloaded', timeout: source.timeoutMs || 45000 });
      await dismissCookies(page);
      if (source.waitFor) {
        await page.locator(source.waitFor).first().waitFor({ state: 'attached', timeout: source.timeoutMs || 15000 });
      }
      await page.waitForTimeout(source.waitMs ?? 2500);

      let rows = await extractConfigured(page, source);
      if (!rows || !rows.length) rows = await extractAutomatic(page, source);
      rows = dedupe(rows, source);

      const key = source.name;
      const known = new Set(state.seenBySource[key] || []);
      const firstRun = known.size === 0;
      const fresh = rows.filter(r => !known.has(r.link));

      if (firstRun) {
        console.log(`  Erster Lauf: ${rows.length} bestehende Links als bekannt gespeichert, keine Altmeldungen ausgegeben.`);
      } else {
        console.log(`  ${rows.length} Artikel erkannt, ${fresh.length} neu.`);
        for (const r of fresh) {
          items.unshift({
            guid: idFor(r.link),
            source: source.name,
            title: r.title,
            link: r.link,
            pageDate: r.date || null,
            detectedAt: new Date().toISOString()
          });
        }
      }

      const merged = [...rows.map(r => r.link), ...known];
      state.seenBySource[key] = [...new Set(merged)].slice(0, MAX_SEEN_PER_SOURCE);
    } catch (err) {
      console.error(`  FEHLER: ${err.message}`);
    } finally {
      await page.close();
    }
  }

  await browser.close();

  const seenGuid = new Set();
  items = items.filter(x => x && x.guid && !seenGuid.has(x.guid) && seenGuid.add(x.guid));
  items = items.slice(0, MAX_FEED_ITEMS);

  saveJson(STATE_FILE, state);
  saveJson(ITEMS_FILE, items);
  fs.mkdirSync(path.dirname(FEED_FILE), { recursive: true });
  fs.writeFileSync(FEED_FILE, makeFeed(items));
  console.log(`RSS geschrieben: ${FEED_FILE} (${items.length} Einträge)`);
})().catch(err => {
  console.error(err);
  process.exit(1);
});
