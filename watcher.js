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
      if (/^(utm_|fbclid$|gclid$|mc_)/i.test(k)) {
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

function looksLikeArticle(text, href, sourceUrl) {
  if (!text || text.length < 12 || text.length > 240 || !href) {
    return false;
  }

  let u;
  let src;

  try {
    u = new URL(href);
    src = new URL(sourceUrl);
  } catch {
    return false;
  }

  const hostOk =
    u.hostname === src.hostname ||
    u.hostname.endsWith('.' + src.hostname) ||
    src.hostname.endsWith('.' + u.hostname);

  if (!hostOk) return false;

  const hay = (u.pathname + ' ' + text).toLowerCase();

  const bad =
    /(impressum|privacy|datenschutz|cookie|karriere|career|jobs|kontakt|contact|login|newsletter|facebook|instagram|linkedin|youtube|x\.com|twitter)/i;

  if (bad.test(hay)) return false;

  const articleSignals =
    /(news|presse|press|media|meldung|article|story|blog|insight|publication|202[4-9])/i;

  const path = u.pathname.toLowerCase();

  const strong = articleSignals.test(path);
  const depth = path.split('/').filter(Boolean).length >= 2;

  return strong || depth;
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
      const el = selector
        ? root.querySelector(selector)
        : root;

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

      return el
        ? el.getAttribute('href')
        : '';
    };

    return nodes.map(n => ({
      title: textOf(n, cfg.title),
      href: hrefOf(n, cfg.link),
      date: cfg.date ? textOf(n, cfg.date) : ''
    }));
  }, sel);
}

async function extractAutomatic(page, source) {
  /*
   * Wenn die Website einen <main>-Bereich besitzt,
   * betrachten wir nur Links im eigentlichen Seiteninhalt.
   *
   * Dadurch werden Navigation, Footer, Social Media,
   * Investor Relations usw. deutlich besser ausgefiltert.
   */

  const hasMain = await page.locator('main').count() > 0;

  const linkSelector = hasMain
    ? 'main a[href]'
    : 'a[href]';

  const rows = await page
    .locator(linkSelector)
    .evaluateAll(nodes =>
      nodes.map(a => ({
        title:
          (
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

  return rows.filter(r => {
    if (!looksLikeArticle(r.title, r.href, source.url)) {
      return false;
    }

    try {
      const u = new URL(r.href, source.url);
      const sourceUrl = new URL(source.url);

      /*
       * Die Übersichtsseite selbst nicht als Artikel erfassen.
       */

      const cleanPath = p =>
        p.replace(/\/+$/, '') || '/';

      if (
        cleanPath(u.pathname) ===
        cleanPath(sourceUrl.pathname)
      ) {
        return false;
      }

      /*
       * Links mit Such-, Filter- oder Trackingparametern
       * ignorieren.
       */

      if (u.search) {
        return false;
      }

      /*
       * Optional kann in sources.json ein bestimmter
       * Artikelpfad angegeben werden.
       *
       * Beispiel:
       *
       * "includePath": "/de/newsroom/"
       */

      if (
        source.includePath &&
        !u.pathname.startsWith(source.includePath)
      ) {
        return false;
      }

      return true;
    } catch {
      return false;
    }
  });
}

function dedupe(rows, source) {
  const map = new Map();

  for (const r of rows) {
    const link = canonicalUrl(r.href, source.url);

    const title = (r.title || '')
      .replace(/\s+/g, ' ')
      .trim();

    if (!link || !title) continue;

    if (!map.has(link)) {
      map.set(link, {
        title,
        link,
        date: (r.date || '').trim()
      });
    }
  }

  return [...map.values()];
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
      <pubDate>${escXml(
        new Date(item.detectedAt).toUTCString()
      )}</pubDate>
      <description>${escXml(
        'Quelle: ' + item.source
      )}</description>
      <source>${escXml(item.source)}</source>
    </item>`
    )
    .join('');

  return `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>OM News Watcher</title>

    <link>https://github.com/</link>

    <description>
      Neue Meldungen aus beobachteten Websites für onlinemarktplatz.de
    </description>

    <language>de-de</language>

    <lastBuildDate>${now}</lastBuildDate>

    ${body}

  </channel>
</rss>
`;
}

(async () => {
  const sources = readJson(
    SOURCES_FILE,
    []
  ).filter(s => s.enabled !== false);

  const state = readJson(
    STATE_FILE,
    {
      seenBySource: {}
    }
  );

  let items = readJson(
    ITEMS_FILE,
    []
  );

  if (!sources.length) {
    console.log(
      'Keine Quellen aktiviert. Bitte sources.json bearbeiten.'
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

  const browser = await chromium.launch({
    headless: true
  });

  const context = await browser.newContext({
    locale: 'de-DE',

    timezoneId: 'Europe/Berlin',

    userAgent:
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ' +
      'AppleWebKit/537.36 Chrome/140 Safari/537.36 ' +
      'OM-News-Watcher/0.1'
  });

  for (const source of sources) {
    const page = await context.newPage();

    console.log(
      `Prüfe: ${source.name} — ${source.url}`
    );

    try {
      await page.goto(source.url, {
        waitUntil: 'domcontentloaded',
        timeout: source.timeoutMs || 45000
      });

      await dismissCookies(page);

      /*
       * Optional auf ein bestimmtes Element warten,
       * wenn eine Seite ihre Inhalte später lädt.
       */

      if (source.waitFor) {
        await page
          .locator(source.waitFor)
          .first()
          .waitFor({
            state: 'attached',
            timeout:
              source.timeoutMs ||
              15000
          });
      }

      /*
       * JavaScript etwas Zeit geben.
       */

      await page.waitForTimeout(
        source.waitMs ?? 2500
      );

      let rows =
        await extractConfigured(
          page,
          source
        );

      if (!rows || !rows.length) {
        rows =
          await extractAutomatic(
            page,
            source
          );
      }

      rows =
        dedupe(
          rows,
          source
        );

      const key =
        source.name;

      const known =
        new Set(
          state.seenBySource[key] ||
          []
        );

      const firstRun =
        known.size === 0;

      const fresh =
        rows.filter(
          r =>
            !known.has(r.link)
        );

      /*
       * Beim ersten Lauf wird bewusst nichts
       * als "neu" ausgegeben.
       *
       * Wir speichern zunächst nur den
       * vorhandenen Bestand.
       */

      if (firstRun) {
        console.log(
          `  Erster Lauf: ${rows.length} bestehende Links als bekannt gespeichert, keine Altmeldungen ausgegeben.`
        );
      } else {
        console.log(
          `  ${rows.length} Artikel erkannt, ${fresh.length} neu.`
        );

        /*
         * Neue Artikel in den RSS-Feed aufnehmen.
         */

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
              r.date || null,

            detectedAt:
              new Date().toISOString()
          });
        }
      }

      /*
       * Alle aktuell gefundenen Links
       * als bekannt speichern.
       */

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

    } catch (err) {
      console.error(
        `  FEHLER: ${err.message}`
      );
    } finally {
      await page.close();
    }
  }

  await browser.close();

  /*
   * Doppelte Feed-Einträge verhindern.
   */

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

  /*
   * Feed begrenzen.
   */

  items =
    items.slice(
      0,
      MAX_FEED_ITEMS
    );

  /*
   * Zustand speichern.
   */

  saveJson(
    STATE_FILE,
    state
  );

  saveJson(
    ITEMS_FILE,
    items
  );

  /*
   * RSS-Datei erzeugen.
   */

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
    `RSS geschrieben: ${FEED_FILE} (${items.length} Einträge)`
  );

})().catch(err => {
  console.error(err);

  process.exit(1);
});
