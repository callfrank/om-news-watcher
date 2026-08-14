const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { chromium } = require('playwright');

const ROOT = __dirname;
const SOURCES_FILE = path.join(ROOT, 'sources.json');
const STATE_FILE = path.join(ROOT, 'data', 'state.json');
const ITEMS_FILE = path.join(ROOT, 'data', 'items.json');
const FEED_FILE = path.join(ROOT, 'docs', 'feed.xml');

const VERSION = '0.6';
const MAX_SEEN_PER_SOURCE = 2500;
const MAX_FEED_ITEMS = 500;
const DEFAULT_SAMPLE_COUNT = 3;

/*
 * Wichtigste Änderung in v0.6:
 * Mehrere Quellen werden parallel geprüft.
 *
 * OM_CONCURRENCY kann im Workflow optional gesetzt werden.
 * Standard: 5 parallele Quellen.
 */
const SOURCE_CONCURRENCY = Math.max(
  1,
  Math.min(8, Number(process.env.OM_CONCURRENCY || 5))
);

/*
 * Einzelne problematische Seiten dürfen den gesamten Lauf
 * nicht mehr 60–90 Sekunden blockieren.
 *
 * Standard: 30 Sekunden
 * Obergrenze: 45 Sekunden
 */
const DEFAULT_TIMEOUT_MS = 30000;
const MAX_TIMEOUT_MS = Math.max(
  10000,
  Number(process.env.OM_MAX_TIMEOUT_MS || 45000)
);

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
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
      if (/^(utm_|fbclid$|gclid$|mc_|ref$|ref_|source$)/i.test(k)) {
        u.searchParams.delete(k);
      }
    }

    return u.href;
  } catch {
    return null;
  }
}

function idFor(link) {
  return crypto.createHash('sha256').update(link).digest('hex').slice(0, 24);
}

function safeRegex(pattern) {
  if (!pattern) return null;
  try {
    return new RegExp(pattern, 'i');
  } catch {
    return null;
  }
}

function effectiveTimeout(source) {
  const requested = Number(source.timeoutMs ?? DEFAULT_TIMEOUT_MS);
  if (!Number.isFinite(requested) || requested <= 0) return DEFAULT_TIMEOUT_MS;
  return Math.min(requested, MAX_TIMEOUT_MS);
}

function isInternalUrl(href, sourceUrl) {
  try {
    const u = new URL(href, sourceUrl);
    const src = new URL(sourceUrl);

    return (
      u.hostname === src.hostname ||
      u.hostname.endsWith('.' + src.hostname) ||
      src.hostname.endsWith('.' + u.hostname)
    );
  } catch {
    return false;
  }
}

function looksLikeArticle(text, href, sourceUrl) {
  if (!text || text.length < 10 || text.length > 260 || !href) return false;
  if (!isInternalUrl(href, sourceUrl)) return false;

  let u;
  try {
    u = new URL(href, sourceUrl);
  } catch {
    return false;
  }

  const hay = `${u.pathname} ${text}`.toLowerCase();

  const bad =
    /(impressum|privacy|datenschutz|cookie|karriere|career|jobs|kontakt|contact|login|newsletter|facebook|instagram|linkedin|youtube|twitter|x\.com|agb|terms|sitemap|warenkorb|cart|account)/i;

  if (bad.test(hay)) return false;

  const segments = u.pathname.split('/').filter(Boolean);
  const path = u.pathname.toLowerCase();

  const articleSignals =
    /(news|presse|press|media|meldung|article|story|stories|blog|insight|report|study|studie|publication|release|event|webinar|202[4-9])/i;

  const dateSignal =
    /\/(20\d{2})[\/-](0?[1-9]|1[0-2])(?:[\/-](0?[1-9]|[12]\d|3[01]))?\//i;

  if (articleSignals.test(path) || dateSignal.test(path)) return true;
  if (segments.length >= 3 && text.length >= 18) return true;
  if (segments.length >= 2 && text.length >= 35) return true;

  return false;
}

function matchesConfiguredRules(item, source) {
  const includeRegex = safeRegex(source.includeRegex);
  const excludeRegex = safeRegex(source.excludeRegex);
  const includeTitleRegex = safeRegex(source.includeTitleRegex);
  const excludeTitleRegex = safeRegex(source.excludeTitleRegex);

  if (includeRegex && !includeRegex.test(item.link)) return false;
  if (excludeRegex && excludeRegex.test(item.link)) return false;
  if (includeTitleRegex && !includeTitleRegex.test(item.title)) return false;
  if (excludeTitleRegex && excludeTitleRegex.test(item.title)) return false;

  return true;
}

async function dismissCookies(page) {
  const labels = [
    /alle akzeptieren/i,
    /akzeptieren/i,
    /zustimmen/i,
    /accept all/i,
    /^accept$/i,
    /agree/i,
    /allow all/i
  ];

  for (const rx of labels) {
    try {
      const btn = page.getByRole('button', { name: rx }).first();
      if (await btn.isVisible({ timeout: 250 })) {
        await btn.click({ timeout: 1200 });
        await page.waitForTimeout(200);
        return;
      }
    } catch {}
  }
}

async function autoScroll(page, steps = 0) {
  const count = Math.min(5, Number(steps || 0));
  if (!count) return;

  for (let i = 0; i < count; i++) {
    await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
    await page.waitForTimeout(500);
  }

  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(150);
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
  const custom = source.candidateSelector;

  const specificSelectors = custom
    ? [custom]
    : [
        'main article a[href]',
        'main [class*="teaser" i] a[href]',
        'main [class*="card" i] a[href]',
        'main [class*="news" i] a[href]',
        'main [class*="press" i] a[href]'
      ];

  let selector = null;

  for (const candidate of specificSelectors) {
    try {
      const count = await page.locator(candidate).count();
      if (count >= 3) {
        selector = candidate;
        break;
      }
    } catch {}
  }

  if (!selector) {
    selector = (await page.locator('main').count()) > 0 ? 'main a[href]' : 'a[href]';
  }

  return await page.locator(selector).evaluateAll(nodes =>
    nodes.map(a => ({
      title: (a.textContent || a.getAttribute('aria-label') || '')
        .replace(/\s+/g, ' ')
        .trim(),
      href: a.href || a.getAttribute('href') || '',
      date: ''
    }))
  );
}

function normalizeAndFilter(rows, source) {
  const map = new Map();

  for (const r of rows || []) {
    const link = canonicalUrl(r.href, source.url);
    const title = (r.title || '').replace(/\s+/g, ' ').trim();
    const date = (r.date || '').trim();

    if (!link || !title) continue;
    if (!looksLikeArticle(title, link, source.url)) continue;

    const item = { title, link, date };
    if (!matchesConfiguredRules(item, source)) continue;

    if (!map.has(link)) map.set(link, item);
  }

  let result = [...map.values()];

  if (source.maxDetectedItems && Number(source.maxDetectedItems) > 0) {
    result = result.slice(0, Number(source.maxDetectedItems));
  }

  return result;
}

function suspiciousSpike(knownCount, freshCount, source) {
  if (source.spikeGuard === false) return false;
  if (knownCount < 10) return false;

  const minNew = Number(source.spikeMinNew ?? 10);
  const ratio = Number(source.spikeRatio ?? 0.5);

  return freshCount >= minNew && freshCount / Math.max(knownCount, 1) >= ratio;
}

function pruneStoredItems(items, sources) {
  const sourceMap = new Map(sources.map(s => [s.name, s]));
  let removed = 0;

  const kept = items.filter(item => {
    const source = sourceMap.get(item.source);
    if (!source) return true;

    const candidate = {
      title: item.title || '',
      link: item.link || ''
    };

    if (!matchesConfiguredRules(candidate, source)) {
      removed++;
      return false;
    }

    return true;
  });

  if (removed) {
    console.log(`Bereinigung: ${removed} bereits gespeicherte Feed-Einträge durch neue Filter entfernt.`);
  }

  return kept;
}

function makeFeed(items) {
  const now = new Date().toUTCString();

  const body = items
    .map(
      item => `
    <item>
      <title>${escXml(item.title)}</title>
      <link>${escXml(item.link)}</link>
      <guid isPermaLink="false">${escXml(item.guid)}</guid>
      <pubDate>${escXml(new Date(item.detectedAt).toUTCString())}</pubDate>
      <description>${escXml('Quelle: ' + item.source)}</description>
      <source>${escXml(item.source)}</source>
    </item>`
    )
    .join('');

  return `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>OM News Watcher</title>
    <link>https://github.com/</link>
    <description>Neue Meldungen aus beobachteten Websites für onlinemarktplatz.de</description>
    <language>de-de</language>
    <lastBuildDate>${now}</lastBuildDate>
    ${body}
  </channel>
</rss>
`;
}

async function createContext(browser) {
  return await browser.newContext({
    locale: 'de-DE',
    timezoneId: 'Europe/Berlin',
    userAgent:
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ' +
      'AppleWebKit/537.36 Chrome/140 Safari/537.36 OM-News-Watcher/' + VERSION
  });
}

async function prepareLoadedPage(defaultContext, source, notes) {
  const timeoutMs = effectiveTimeout(source);
  let page = await defaultContext.newPage();

  try {
    await page.goto(source.url, {
      waitUntil: 'domcontentloaded',
      timeout: timeoutMs
    });

    return {
      page,
      cleanup: async () => {
        try { await page.close(); } catch {}
      }
    };
  } catch (err) {
    const message = err.message || '';
    const http2Error = /ERR_HTTP2_PROTOCOL_ERROR/i.test(message);
    const timeoutError = /Timeout\s+\d+ms\s+exceeded/i.test(message);

    if (timeoutError) {
      try {
        const currentUrl = page.url();
        const bodyExists = await page.locator('body').count();

        if (currentUrl && currentUrl !== 'about:blank' && bodyExists) {
          notes.push(
            `Lade-Timeout nach ${Math.round(timeoutMs / 1000)} s, aber DOM vorhanden – vorhandene Seite ausgewertet.`
          );

          return {
            page,
            cleanup: async () => {
              try { await page.close(); } catch {}
            }
          };
        }
      } catch {}
    }

    try { await page.close(); } catch {}

    if (http2Error && source.http2Fallback !== false) {
      notes.push('HTTP/2-Fehler – zweiter Versuch ohne HTTP/2.');

      const fallbackBrowser = await chromium.launch({
        headless: true,
        args: ['--disable-http2']
      });

      const fallbackContext = await createContext(fallbackBrowser);
      page = await fallbackContext.newPage();

      try {
        await page.goto(source.url, {
          waitUntil: 'domcontentloaded',
          timeout: timeoutMs
        });
      } catch (fallbackErr) {
        const fallbackMessage = fallbackErr.message || '';
        const fallbackTimeout = /Timeout\s+\d+ms\s+exceeded/i.test(fallbackMessage);

        if (fallbackTimeout) {
          try {
            const currentUrl = page.url();
            const bodyExists = await page.locator('body').count();

            if (currentUrl && currentUrl !== 'about:blank' && bodyExists) {
              notes.push('Fallback langsam, aber DOM vorhanden – vorhandene Seite ausgewertet.');

              return {
                page,
                cleanup: async () => {
                  try { await fallbackBrowser.close(); } catch {}
                }
              };
            }
          } catch {}
        }

        try { await fallbackBrowser.close(); } catch {}
        throw fallbackErr;
      }

      return {
        page,
        cleanup: async () => {
          try { await fallbackBrowser.close(); } catch {}
        }
      };
    }

    throw err;
  }
}

async function inspectSource(context, source, index, total) {
  const started = Date.now();
  const notes = [];
  let loaded = null;

  console.log(`[${index + 1}/${total}] Start: ${source.name}`);

  try {
    loaded = await prepareLoadedPage(context, source, notes);
    const page = loaded.page;

    await dismissCookies(page);

    if (source.waitFor) {
      await page.locator(source.waitFor).first().waitFor({
        state: 'attached',
        timeout: Math.min(effectiveTimeout(source), 12000)
      });
    }

    const waitMs = Math.min(Number(source.waitMs ?? 2500), 8000);
    await page.waitForTimeout(waitMs);
    await autoScroll(page, source.autoScroll || 0);

    let rows = await extractConfigured(page, source);
    if (!rows || !rows.length) rows = await extractAutomatic(page, source);

    rows = normalizeAndFilter(rows, source);

    return {
      source,
      rows,
      notes,
      durationMs: Date.now() - started,
      error: null
    };
  } catch (err) {
    return {
      source,
      rows: [],
      notes,
      durationMs: Date.now() - started,
      error: err
    };
  } finally {
    if (loaded) await loaded.cleanup();
  }
}

async function mapWithConcurrency(items, limit, worker) {
  const results = new Array(items.length);
  let nextIndex = 0;

  async function runWorker() {
    while (true) {
      const index = nextIndex++;
      if (index >= items.length) return;

      results[index] = await worker(items[index], index);
    }
  }

  const workers = Array.from(
    { length: Math.min(limit, items.length) },
    () => runWorker()
  );

  await Promise.all(workers);
  return results;
}

(async () => {
  console.log(`OM News Watcher v${VERSION}`);
  console.log(`Parallelität: ${SOURCE_CONCURRENCY} Quellen`);
  console.log(`Max. Seiten-Timeout: ${Math.round(MAX_TIMEOUT_MS / 1000)} Sekunden`);

  const sources = readJson(SOURCES_FILE, []).filter(s => s.enabled !== false);

  const state = readJson(STATE_FILE, {
    seenBySource: {},
    initializedBySource: {}
  });

  state.seenBySource = state.seenBySource || {};
  state.initializedBySource = state.initializedBySource || {};

  let items = readJson(ITEMS_FILE, []);
  items = pruneStoredItems(items, sources);

  if (!sources.length) {
    console.log('Keine Quellen aktiviert. Bitte sources.json bearbeiten.');
    fs.mkdirSync(path.dirname(FEED_FILE), { recursive: true });
    fs.writeFileSync(FEED_FILE, makeFeed(items));
    process.exit(0);
  }

  const browser = await chromium.launch({ headless: true });
  const context = await createContext(browser);

  const results = await mapWithConcurrency(
    sources,
    SOURCE_CONCURRENCY,
    (source, index) => inspectSource(context, source, index, sources.length)
  );

  await browser.close();

  console.log('\n===== AUSWERTUNG =====');

  for (const result of results) {
    const source = result.source;
    const seconds = (result.durationMs / 1000).toFixed(1);

    console.log(`Prüfe: ${source.name} — ${source.url}`);
    console.log(`  Dauer: ${seconds} s`);

    for (const note of result.notes) {
      console.log(`  ↻ ${note}`);
    }

    if (result.error) {
      console.error(`  FEHLER: ${result.error.message}`);
      continue;
    }

    const rows = result.rows;
    const key = source.name;
    const hadPriorState = Object.prototype.hasOwnProperty.call(state.seenBySource, key);
    const firstRun = state.initializedBySource[key] !== true && !hadPriorState;
    const known = new Set(state.seenBySource[key] || []);

    if (rows.length === 0) {
      console.log('  ⚠ KEINE ARTIKEL ERKANNT – Quelle prüfen.');
      state.initializedBySource[key] = true;
      if (!hadPriorState) state.seenBySource[key] = [];
      continue;
    }

    const sampleCount = Number(source.sampleCount ?? DEFAULT_SAMPLE_COUNT);
    const samples = rows.slice(0, Math.max(0, sampleCount));

    if (samples.length) {
      console.log('  Beispiele:');
      for (const row of samples) {
        console.log(`    - ${row.title}`);
        console.log(`      ${row.link}`);
      }
    }

    const fresh = rows.filter(r => !known.has(r.link));

    if (firstRun) {
      console.log(
        `  Erster Lauf: ${rows.length} bestehende Links als bekannt gespeichert, keine Altmeldungen ausgegeben.`
      );
    } else if (suspiciousSpike(known.size, fresh.length, source)) {
      console.log(
        `  ⚠ VERDÄCHTIGER SPRUNG: ${rows.length} Artikel erkannt, ${fresh.length} neu. ` +
        'Neue Links werden vorsichtshalber NICHT in den Feed übernommen und NICHT als bekannt markiert.'
      );
      continue;
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
    state.initializedBySource[key] = true;
  }

  const seenGuid = new Set();
  items = items.filter(x => x && x.guid && !seenGuid.has(x.guid) && seenGuid.add(x.guid));
  items = items.slice(0, MAX_FEED_ITEMS);

  saveJson(STATE_FILE, state);
  saveJson(ITEMS_FILE, items);

  fs.mkdirSync(path.dirname(FEED_FILE), { recursive: true });
  fs.writeFileSync(FEED_FILE, makeFeed(items));

  console.log(`\nRSS geschrieben: ${FEED_FILE} (${items.length} Einträge)`);
})().catch(err => {
  console.error(err);
  process.exit(1);
});
