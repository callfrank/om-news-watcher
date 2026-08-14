const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { chromium } = require('playwright');

const ROOT = __dirname;
const SOURCES_FILE = path.join(ROOT, 'sources.json');
const STATE_FILE = path.join(ROOT, 'data', 'state.json');
const ITEMS_FILE = path.join(ROOT, 'data', 'items.json');
const FEED_FILE = path.join(ROOT, 'docs', 'feed.xml');

const VERSION = '0.8';

const MAX_SEEN_PER_SOURCE = 2500;
const MAX_FEED_ITEMS = 500;
const DEFAULT_SAMPLE_COUNT = 3;

/*
 * v0.8: Hard-Timeout-Version
 *
 * - 8 Quellen parallel
 * - normale Navigation max. 15 s
 * - HTTP/2-Fallback max. 7 s
 * - JS-Wartezeit max. 2,5 s
 * - Auto-Scroll max. 2 Schritte
 * - jede Quelle insgesamt max. 25 s
 * - page.close() darf nicht mehr unbegrenzt hängen
 *
 * Selbst defekte Webseiten sollen den Gesamtlauf
 * nicht mehr blockieren können.
 */

const SOURCE_CONCURRENCY = Math.max(
  1,
  Math.min(10, Number(process.env.OM_CONCURRENCY || 8))
);

const NAV_TIMEOUT_MS = Math.max(
  5000,
  Math.min(20000, Number(process.env.OM_NAV_TIMEOUT_MS || 15000))
);

const FALLBACK_TIMEOUT_MS = Math.max(
  4000,
  Math.min(12000, Number(process.env.OM_FALLBACK_TIMEOUT_MS || 7000))
);

const MAX_WAIT_MS = Math.max(
  500,
  Math.min(5000, Number(process.env.OM_MAX_WAIT_MS || 2500))
);

/*
 * v0.8: echter Gesamt-Timeout pro Quelle.
 *
 * Dieser Timeout umfasst ALLES:
 * Navigation, Cookiebanner, waitFor, JavaScript-Wartezeit,
 * Scrollen, DOM-Auswertung und das Schließen der Seite.
 */
const HARD_SOURCE_TIMEOUT_MS = Math.max(
  12000,
  Math.min(35000, Number(process.env.OM_HARD_SOURCE_TIMEOUT_MS || 25000))
);

const PAGE_CLOSE_TIMEOUT_MS = 1200;

function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function closePageFast(page) {
  if (!page) return;

  try {
    await Promise.race([
      page.close({ runBeforeUnload: false }).catch(() => {}),
      delay(PAGE_CLOSE_TIMEOUT_MS)
    ]);
  } catch {}
}

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
  return crypto
    .createHash('sha256')
    .update(link)
    .digest('hex')
    .slice(0, 24);
}

function safeRegex(pattern) {
  if (!pattern) return null;

  try {
    return new RegExp(pattern, 'i');
  } catch {
    return null;
  }
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
  if (!text || text.length < 10 || text.length > 260 || !href) {
    return false;
  }

  if (!isInternalUrl(href, sourceUrl)) {
    return false;
  }

  let u;

  try {
    u = new URL(href, sourceUrl);
  } catch {
    return false;
  }

  const hay = `${u.pathname} ${text}`.toLowerCase();

  const bad =
    /(impressum|privacy|datenschutz|cookie|karriere|career|jobs|kontakt|contact|login|newsletter|facebook|instagram|linkedin|youtube|twitter|x\.com|agb|terms|sitemap|warenkorb|cart|account)/i;

  if (bad.test(hay)) {
    return false;
  }

  const segments = u.pathname.split('/').filter(Boolean);
  const path = u.pathname.toLowerCase();

  const articleSignals =
    /(news|presse|press|media|meldung|article|story|stories|blog|insight|report|study|studie|publication|release|event|webinar|202[4-9])/i;

  const dateSignal =
    /\/(20\d{2})[\/-](0?[1-9]|1[0-2])(?:[\/-](0?[1-9]|[12]\d|3[01]))?\//i;

  if (articleSignals.test(path) || dateSignal.test(path)) {
    return true;
  }

  if (segments.length >= 3 && text.length >= 18) {
    return true;
  }

  if (segments.length >= 2 && text.length >= 35) {
    return true;
  }

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

      if (await btn.isVisible({ timeout: 150 })) {
        await btn.click({ timeout: 700 });
        return;
      }
    } catch {}
  }
}

async function autoScroll(page, steps = 0) {
  const count = Math.min(2, Number(steps || 0));

  for (let i = 0; i < count; i++) {
    try {
      await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
      await page.waitForTimeout(300);
    } catch {
      break;
    }
  }
}

async function extractConfigured(page, source) {
  const sel = source.selectors || {};

  if (!sel.item) {
    return null;
  }

  return await page.locator(sel.item).evaluateAll((nodes, cfg) => {
    const textOf = (root, selector) => {
      const el = selector ? root.querySelector(selector) : root;

      return el
        ? (el.textContent || '')
            .replace(/\s+/g, ' ')
            .trim()
        : '';
    };

    const hrefOf = (root, selector) => {
      const el = selector
        ? root.querySelector(selector)
        : root.querySelector('a[href]');

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

  const candidates = custom
    ? [custom]
    : [
        'main article a[href]',
        'main [class*="teaser" i] a[href]',
        'main [class*="card" i] a[href]',
        'main [class*="news" i] a[href]',
        'main [class*="press" i] a[href]'
      ];

  let selector = null;

  for (const candidate of candidates) {
    try {
      if (await page.locator(candidate).count() >= 3) {
        selector = candidate;
        break;
      }
    } catch {}
  }

  if (!selector) {
    selector = (await page.locator('main').count()) > 0
      ? 'main a[href]'
      : 'a[href]';
  }

  return await page.locator(selector).evaluateAll(nodes =>
    nodes.map(a => ({
      title: (
        a.textContent ||
        a.getAttribute('aria-label') ||
        ''
      )
        .replace(/\s+/g, ' ')
        .trim(),

      href:
        a.href ||
        a.getAttribute('href') ||
        '',

      date: ''
    }))
  );
}

function normalizeAndFilter(rows, source) {
  const map = new Map();

  for (const r of rows || []) {
    const link = canonicalUrl(r.href, source.url);

    const title = (r.title || '')
      .replace(/\s+/g, ' ')
      .trim();

    const date = (r.date || '')
      .trim();

    if (!link || !title) continue;

    if (!looksLikeArticle(title, link, source.url)) {
      continue;
    }

    const item = {
      title,
      link,
      date
    };

    if (!matchesConfiguredRules(item, source)) {
      continue;
    }

    if (!map.has(link)) {
      map.set(link, item);
    }
  }

  let result = [...map.values()];

  if (
    source.maxDetectedItems &&
    Number(source.maxDetectedItems) > 0
  ) {
    result = result.slice(
      0,
      Number(source.maxDetectedItems)
    );
  }

  return result;
}

function suspiciousSpike(knownCount, freshCount, source) {
  if (source.spikeGuard === false) {
    return false;
  }

  if (knownCount < 10) {
    return false;
  }

  const minNew = Number(source.spikeMinNew ?? 10);
  const ratio = Number(source.spikeRatio ?? 0.5);

  return (
    freshCount >= minNew &&
    freshCount / Math.max(knownCount, 1) >= ratio
  );
}

function pruneStoredItems(items, sources) {
  const sourceMap = new Map(
    sources.map(s => [s.name, s])
  );

  let removed = 0;

  const kept = items.filter(item => {
    const source = sourceMap.get(item.source);

    if (!source) {
      return true;
    }

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
    console.log(
      `Bereinigung: ${removed} gespeicherte Feed-Einträge durch Filter entfernt.`
    );
  }

  return kept;
}

function makeFeed(items) {
  const now = new Date().toUTCString();

  const body = items.map(item => `
    <item>
      <title>${escXml(item.title)}</title>
      <link>${escXml(item.link)}</link>
      <guid isPermaLink="false">${escXml(item.guid)}</guid>
      <pubDate>${escXml(new Date(item.detectedAt).toUTCString())}</pubDate>
      <description>${escXml('Quelle: ' + item.source)}</description>
      <source>${escXml(item.source)}</source>
    </item>`
  ).join('');

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
      'AppleWebKit/537.36 Chrome/140 Safari/537.36 ' +
      `OM-News-Watcher/${VERSION}`
  });
}

async function usePartiallyLoadedDom(page) {
  try {
    const currentUrl = page.url();
    const bodyCount = await page.locator('body').count();

    return Boolean(
      currentUrl &&
      currentUrl !== 'about:blank' &&
      bodyCount > 0
    );
  } catch {
    return false;
  }
}

async function loadPage(context, fallbackContext, source, notes) {
  let page = await context.newPage();
  page.setDefaultTimeout(5000);
  page.setDefaultNavigationTimeout(NAV_TIMEOUT_MS);

  try {
    await page.goto(source.url, {
      waitUntil: 'domcontentloaded',
      timeout: NAV_TIMEOUT_MS
    });

    return {
      page,
      cleanup: async () => {
        await closePageFast(page);
      }
    };

  } catch (err) {
    const message = err.message || '';

    if (
      /Timeout/i.test(message) &&
      await usePartiallyLoadedDom(page)
    ) {
      notes.push(
        `Navigation nach ${NAV_TIMEOUT_MS / 1000}s beendet; vorhandenes DOM wird ausgewertet.`
      );

      return {
        page,
        cleanup: async () => {
          await closePageFast(page);
        }
      };
    }

    const isHttp2 =
      /ERR_HTTP2_PROTOCOL_ERROR/i.test(message);

    await closePageFast(page);

    if (
      isHttp2 &&
      source.http2Fallback !== false
    ) {
      notes.push(
        `HTTP/2-Fehler – schneller Fallback ohne HTTP/2 (${FALLBACK_TIMEOUT_MS / 1000}s).`
      );

      page = await fallbackContext.newPage();
      page.setDefaultTimeout(5000);
      page.setDefaultNavigationTimeout(FALLBACK_TIMEOUT_MS);

      try {
        await page.goto(source.url, {
          waitUntil: 'domcontentloaded',
          timeout: FALLBACK_TIMEOUT_MS
        });

        return {
          page,
          cleanup: async () => {
            await closePageFast(page);
          }
        };

      } catch (fallbackErr) {
        if (
          /Timeout/i.test(fallbackErr.message || '') &&
          await usePartiallyLoadedDom(page)
        ) {
          notes.push(
            'Fallback-Timeout, aber DOM vorhanden – vorhandene Seite wird ausgewertet.'
          );

          return {
            page,
            cleanup: async () => {
              try {
                await page.close();
              } catch {}
            }
          };
        }

        await closePageFast(page);

        throw fallbackErr;
      }
    }

    throw err;
  }
}

async function inspectSource(context, fallbackContext, source, index, total) {
  const started = Date.now();
  const notes = [];
  let loaded = null;

  console.log(
    `[${index + 1}/${total}] Start: ${source.name}`
  );

  try {
    loaded = await loadPage(
      context,
      fallbackContext,
      source,
      notes
    );

    const page = loaded.page;

    await dismissCookies(page);

    if (source.waitFor) {
      try {
        await page
          .locator(source.waitFor)
          .first()
          .waitFor({
            state: 'attached',
            timeout: 4000
          });
      } catch {
        notes.push(
          `waitFor "${source.waitFor}" nach 4s nicht gefunden – trotzdem ausgewertet.`
        );
      }
    }

    const waitMs = Math.min(
      Math.max(0, Number(source.waitMs ?? 1500)),
      MAX_WAIT_MS
    );

    if (waitMs) {
      await page.waitForTimeout(waitMs);
    }

    await autoScroll(
      page,
      source.autoScroll || 0
    );

    let rows = await extractConfigured(
      page,
      source
    );

    if (!rows || !rows.length) {
      rows = await extractAutomatic(
        page,
        source
      );
    }

    rows = normalizeAndFilter(
      rows,
      source
    );

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
    if (loaded) {
      await loaded.cleanup();
    }
  }
}


async function inspectSourceWithHardTimeout(
  context,
  fallbackContext,
  source,
  index,
  total
) {
  const started = Date.now();
  let timer = null;

  const work = inspectSource(
    context,
    fallbackContext,
    source,
    index,
    total
  );

  const timeout = new Promise(resolve => {
    timer = setTimeout(() => {
      resolve({
        source,
        rows: [],
        notes: [
          `HARD TIMEOUT: Quelle nach ${HARD_SOURCE_TIMEOUT_MS / 1000}s zwangsweise beendet.`
        ],
        durationMs: Date.now() - started,
        error: new Error(
          `HARD TIMEOUT nach ${HARD_SOURCE_TIMEOUT_MS / 1000}s`
        ),
        hardTimeout: true
      });
    }, HARD_SOURCE_TIMEOUT_MS);
  });

  const result = await Promise.race([
    work,
    timeout
  ]);

  if (timer) {
    clearTimeout(timer);
  }

  const seconds = (
    (Date.now() - started) / 1000
  ).toFixed(1);

  console.log(
    `[${index + 1}/${total}] Ende: ${source.name} (${seconds}s)` +
    (result.hardTimeout ? ' [HARD TIMEOUT]' : '')
  );

  return result;
}

async function mapWithConcurrency(items, limit, worker) {
  const results = new Array(items.length);
  let nextIndex = 0;

  async function runner() {
    while (true) {
      const index = nextIndex++;

      if (index >= items.length) {
        return;
      }

      results[index] = await worker(
        items[index],
        index
      );
    }
  }

  const workers = Array.from(
    {
      length: Math.min(
        limit,
        items.length
      )
    },
    () => runner()
  );

  await Promise.all(workers);

  return results;
}

(async () => {
  console.log(`OM News Watcher v${VERSION}`);
  console.log(
    `Parallelität: ${SOURCE_CONCURRENCY} Quellen`
  );
  console.log(
    `Navigation: max. ${NAV_TIMEOUT_MS / 1000}s; HTTP/2-Fallback: max. ${FALLBACK_TIMEOUT_MS / 1000}s; JS-Wartezeit: max. ${MAX_WAIT_MS / 1000}s`
  );
  console.log(
    `HARD TIMEOUT pro Quelle: ${HARD_SOURCE_TIMEOUT_MS / 1000}s`
  );

  const sources = readJson(
    SOURCES_FILE,
    []
  ).filter(
    s => s.enabled !== false
  );

  const state = readJson(
    STATE_FILE,
    {
      seenBySource: {},
      initializedBySource: {}
    }
  );

  state.seenBySource =
    state.seenBySource || {};

  state.initializedBySource =
    state.initializedBySource || {};

  let items = readJson(
    ITEMS_FILE,
    []
  );

  items = pruneStoredItems(
    items,
    sources
  );

  if (!sources.length) {
    console.log(
      'Keine Quellen aktiviert.'
    );

    fs.mkdirSync(
      path.dirname(FEED_FILE),
      {
        recursive: true
      }
    );

    fs.writeFileSync(
      FEED_FILE,
      makeFeed(items)
    );

    process.exit(0);
  }

  /*
   * Zwei Browser werden einmal gestartet:
   *
   * 1. normaler Chromium
   * 2. Chromium ohne HTTP/2 für problematische CDNs
   *
   * Dadurch muss der Fallback-Browser nicht für jede
   * Problemseite neu gestartet werden.
   */

  const browser = await chromium.launch({
    headless: true
  });

  const fallbackBrowser = await chromium.launch({
    headless: true,
    args: ['--disable-http2']
  });

  const context = await createContext(
    browser
  );

  const fallbackContext = await createContext(
    fallbackBrowser
  );

  const results = await mapWithConcurrency(
    sources,
    SOURCE_CONCURRENCY,
    (source, index) =>
      inspectSourceWithHardTimeout(
        context,
        fallbackContext,
        source,
        index,
        sources.length
      )
  );

  await context.close();
  await fallbackContext.close();

  await browser.close();
  await fallbackBrowser.close();

  console.log(
    '\n===== AUSWERTUNG ====='
  );

  for (const result of results) {
    const source =
      result.source;

    const seconds =
      (result.durationMs / 1000)
        .toFixed(1);

    console.log(
      `Prüfe: ${source.name} — ${source.url}`
    );

    console.log(
      `  Dauer: ${seconds} s`
    );

    for (const note of result.notes) {
      console.log(
        `  ↻ ${note}`
      );
    }

    if (result.error) {
      console.error(
        `  FEHLER: ${result.error.message}`
      );

      continue;
    }

    const rows =
      result.rows;

    const key =
      source.name;

    const hadPriorState =
      Object.prototype.hasOwnProperty.call(
        state.seenBySource,
        key
      );

    const firstRun =
      state.initializedBySource[key] !== true &&
      !hadPriorState;

    const known =
      new Set(
        state.seenBySource[key] ||
        []
      );

    if (rows.length === 0) {
      console.log(
        '  ⚠ KEINE ARTIKEL ERKANNT – Quelle prüfen.'
      );

      state.initializedBySource[key] =
        true;

      if (!hadPriorState) {
        state.seenBySource[key] =
          [];
      }

      continue;
    }

    const sampleCount =
      Number(
        source.sampleCount ??
        DEFAULT_SAMPLE_COUNT
      );

    const samples =
      rows.slice(
        0,
        Math.max(
          0,
          sampleCount
        )
      );

    if (samples.length) {
      console.log(
        '  Beispiele:'
      );

      for (const row of samples) {
        console.log(
          `    - ${row.title}`
        );

        console.log(
          `      ${row.link}`
        );
      }
    }

    const fresh =
      rows.filter(
        r =>
          !known.has(r.link)
      );

    if (firstRun) {
      console.log(
        `  Erster Lauf: ${rows.length} bestehende Links als bekannt gespeichert, keine Altmeldungen ausgegeben.`
      );

    } else if (
      suspiciousSpike(
        known.size,
        fresh.length,
        source
      )
    ) {
      console.log(
        `  ⚠ VERDÄCHTIGER SPRUNG: ${rows.length} Artikel erkannt, ${fresh.length} neu. ` +
        'Neue Links werden vorsichtshalber NICHT in den Feed übernommen.'
      );

      continue;

    } else {
      console.log(
        `  ${rows.length} Artikel erkannt, ${fresh.length} neu.`
      );

      for (const r of fresh) {
        items.unshift({
          guid:
            idFor(r.link),

          source:
            source.name,

          title:
            r.title,

          link:
            r.link,

          pageDate:
            r.date ||
            null,

          detectedAt:
            new Date()
              .toISOString()
        });
      }
    }

    const merged = [
      ...rows.map(
        r => r.link
      ),
      ...known
    ];

    state.seenBySource[key] = [
      ...new Set(merged)
    ].slice(
      0,
      MAX_SEEN_PER_SOURCE
    );

    state.initializedBySource[key] =
      true;
  }

  const seenGuid =
    new Set();

  items =
    items.filter(
      x =>
        x &&
        x.guid &&
        !seenGuid.has(x.guid) &&
        seenGuid.add(x.guid)
    );

  items =
    items.slice(
      0,
      MAX_FEED_ITEMS
    );

  saveJson(
    STATE_FILE,
    state
  );

  saveJson(
    ITEMS_FILE,
    items
  );

  fs.mkdirSync(
    path.dirname(FEED_FILE),
    {
      recursive: true
    }
  );

  fs.writeFileSync(
    FEED_FILE,
    makeFeed(items)
  );

  console.log(
    `\nRSS geschrieben: ${FEED_FILE} (${items.length} Einträge)`
  );

})().catch(err => {
  console.error(err);
  process.exit(1);
});
