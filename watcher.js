const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { chromium } = require('playwright');

const ROOT = __dirname;
const SOURCES_FILE = path.join(ROOT, 'sources.json');
const STATE_FILE = path.join(ROOT, 'data', 'state.json');
const ITEMS_FILE = path.join(ROOT, 'data', 'items.json');
const FEED_FILE = path.join(ROOT, 'docs', 'feed.xml');

const VERSION = '0.14';

const MAX_SEEN_PER_SOURCE = 2500;
const MAX_FEED_ITEMS = 500;
const DEFAULT_SAMPLE_COUNT = 3;

/*
 * v0.14: Stabilitäts-Update
 * - globale v0.13-Qualitätsfilter zurückgenommen
 * - gezielte Profile für bekannte schwierige Quellen
 * - Publikationsdatum als Metadatum
 * - keine neue globale Baseline
 *
 * v0.10: Clean-Baseline + Multi-Source-Version
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

/*
 * Einmalige Bereinigung nach der Testphase.
 * Beim ersten Lauf von v0.10 wird nur data/items.json geleert.
 * Der bekannte Seitenbestand in state.json bleibt erhalten.
 */
const FEED_RESET_TOKEN = 'clean-baseline-v11';
const GLOBAL_BASELINE_TOKEN = 'global-baseline-v11';

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

function isAllowedUrl(href, source) {
  try {
    const u = new URL(href, source.url);

    if (!/^https?:$/i.test(u.protocol)) {
      return false;
    }

    if (source.allowExternal === true) {
      return true;
    }

    const src = new URL(source.url);

    return (
      u.hostname === src.hostname ||
      u.hostname.endsWith('.' + src.hostname) ||
      src.hostname.endsWith('.' + u.hostname)
    );
  } catch {
    return false;
  }
}

function syntheticTitleUrl(source, title) {
  const token = crypto
    .createHash('sha256')
    .update(`${source.name}|${title}`)
    .digest('hex')
    .slice(0, 16);

  const u = new URL(source.url);
  u.searchParams.set('om_item', token);
  return u.href;
}


const STABILITY_MONTHS = {
  januar: 1, january: 1,
  februar: 2, february: 2,
  märz: 3, maerz: 3, march: 3,
  april: 4,
  mai: 5, may: 5,
  juni: 6, june: 6,
  juli: 7, july: 7,
  august: 8,
  september: 9,
  oktober: 10, october: 10,
  november: 11,
  dezember: 12, december: 12
};

function validStabilityDate(year, month, day) {
  const y = Number(year);
  const m = Number(month);
  const d = Number(day);

  if (
    y < 2000 || y > 2100 ||
    m < 1 || m > 12 ||
    d < 1 || d > 31
  ) {
    return null;
  }

  const date = new Date(Date.UTC(y, m - 1, d));

  if (
    date.getUTCFullYear() !== y ||
    date.getUTCMonth() !== m - 1 ||
    date.getUTCDate() !== d
  ) {
    return null;
  }

  return [
    String(y).padStart(4, '0'),
    String(m).padStart(2, '0'),
    String(d).padStart(2, '0')
  ].join('-');
}

function normalizePageDateV14(raw = '', link = '') {
  const value = String(raw || '')
    .replace(/\s+/g, ' ')
    .trim();

  let m = value.match(/\b(20\d{2})-(\d{1,2})-(\d{1,2})\b/);
  if (m) {
    const iso = validStabilityDate(m[1], m[2], m[3]);
    if (iso) return iso;
  }

  m = value.match(/\b(\d{1,2})[.\/-](\d{1,2})[.\/-](20\d{2})\b/);
  if (m) {
    const iso = validStabilityDate(m[3], m[2], m[1]);
    if (iso) return iso;
  }

  m = value.match(
    /\b(\d{1,2})\.?\s+(Januar|January|Februar|February|März|Maerz|March|April|Mai|May|Juni|June|Juli|July|August|September|Oktober|October|November|Dezember|December)\s+(20\d{2})\b/i
  );

  if (m) {
    const month =
      STABILITY_MONTHS[m[2].toLowerCase()];

    const iso =
      validStabilityDate(m[3], month, m[1]);

    if (iso) return iso;
  }

  try {
    const u = new URL(link);
    m = u.pathname.match(
      /\/(20\d{2})\/(\d{1,2})\/(\d{1,2})(?:\/|$)/
    );

    if (m) {
      const iso =
        validStabilityDate(m[1], m[2], m[3]);

      if (iso) return iso;
    }
  } catch {}

  return null;
}

function formatGermanDateV14(iso) {
  const m =
    String(iso || '').match(
      /^(20\d{2})-(\d{2})-(\d{2})$/
    );

  return m
    ? `${m[3]}.${m[2]}.${m[1]}`
    : null;
}

function formatDetectedAtV14(value) {
  try {
    return new Intl.DateTimeFormat(
      'de-DE',
      {
        timeZone: 'Europe/Berlin',
        day: '2-digit',
        month: '2-digit',
        year: 'numeric',
        hour: '2-digit',
        minute: '2-digit'
      }
    ).format(new Date(value));
  } catch {
    return '';
  }
}

function stabilityProfile(source) {
  const name =
    String(source?.name || '')
      .toLowerCase();

  const profile = {
    key: '',
    selector: null,
    allowExternal: false,
    titleOnly: false,
    expectedMax: 80
  };

  if (name.includes('visa newsroom')) {
    return {
      ...profile,
      key: 'visa',
      selector:
        'main a[href*="/uber-visa/newsroom/press-releases."]',
      expectedMax: 260
    };
  }

  if (name.includes('shein newsroom')) {
    return {
      ...profile,
      key: 'shein',
      selector:
        'main a[href*="/newsroom/"]',
      expectedMax: 260
    };
  }

  if (name.includes('hellofresh press releases')) {
    return {
      ...profile,
      key: 'hellofresh',
      expectedMax: 220
    };
  }

  if (name.includes('zalando newsroom')) {
    return {
      ...profile,
      key: 'zalando',
      selector:
        'main a[href*="/de/newsroom/news-stories"]',
      expectedMax: 100
    };
  }

  if (name.includes('ecdb reports')) {
    return {
      ...profile,
      key: 'ecdb',
      selector:
        'main a[href*="/reports/"]',
      expectedMax: 120
    };
  }

  if (name.includes('mediamarktsaturn')) {
    return {
      ...profile,
      key: 'mms',
      selector:
        'main a[href*="/de/news-presse/pressemitteilungen/"]',
      expectedMax: 120
    };
  }

  if (name.includes('tencent news')) {
    return {
      ...profile,
      key: 'tencent',
      selector:
        'main h2 a[href], main h3 a[href], article h2 a[href], article h3 a[href]',
      expectedMax: 120
    };
  }

  if (name.includes('google ads & commerce')) {
    return {
      ...profile,
      key: 'google-ads',
      selector:
        'main a[href*="/products/ads-commerce/"]',
      expectedMax: 120
    };
  }

  if (name.includes('jd corporate news')) {
    return {
      ...profile,
      key: 'jd-news',
      selector:
        'main article a[href], article a[href]',
      expectedMax: 120
    };
  }

  if (name.includes('amazon freight events')) {
    return {
      ...profile,
      key: 'amazon-freight',
      selector:
        'main a[href*="freight-amazon.com"]',
      allowExternal: true,
      expectedMax: 80
    };
  }

  if (name.includes('yougov corporate news')) {
    return {
      ...profile,
      key: 'yougov',
      selector:
        'main a[href$=".pdf"], a[href$=".pdf"]',
      expectedMax: 120
    };
  }

  if (name.includes('galaxus medienmitteilungen')) {
    return {
      ...profile,
      key: 'galaxus',
      selector:
        'main a[href*="/de/page/"]',
      expectedMax: 120
    };
  }

  if (name.includes('mordor intelligence case studies')) {
    return {
      ...profile,
      key: 'mordor-case',
      selector:
        'main a[href*="/signal/case-studies/"]',
      expectedMax: 80
    };
  }

  if (name.includes('mordor intelligence insights')) {
    return {
      ...profile,
      key: 'mordor-insights',
      selector:
        'main a[href*="/signal/insights/"]',
      expectedMax: 100
    };
  }

  if (name.includes('omt e-commerce events')) {
    return {
      ...profile,
      key: 'omt',
      selector:
        'main a[href*="/events/"]',
      expectedMax: 100
    };
  }

  if (name.includes('experte.de e-commerce events')) {
    return {
      ...profile,
      key: 'experte-events',
      titleOnly: true,
      allowExternal: true,
      expectedMax: 100
    };
  }

  return null;
}

function applyStabilityProfile(source) {
  const profile =
    stabilityProfile(source);

  if (!profile) {
    return source;
  }

  const copy = {
    ...source,
    selectors: {
      ...(source.selectors || {})
    },
    _stabilityProfile:
      profile
  };

  if (profile.selector) {
    copy.candidateSelector =
      profile.selector;
  }

  if (profile.allowExternal) {
    copy.allowExternal =
      true;
  }

  if (profile.titleOnly) {
    copy.allowTitleOnly =
      true;
  }

  return copy;
}

function stabilityAccepts(title, link, source) {
  const profile =
    source._stabilityProfile;

  if (!profile) {
    return true;
  }

  const lowerTitle =
    String(title || '')
      .replace(/\s+/g, ' ')
      .trim()
      .toLowerCase();

  const generic = new Set([
    'mehr erfahren',
    'read more',
    'learn more',
    'weiterlesen',
    'link öffnet in neuem tab',
    'opens in a new tab',
    'download for free',
    'download',
    'webinar ansehen',
    'zur konferenz',
    'mehr'
  ]);

  if (generic.has(lowerTitle)) {
    return false;
  }

  if (
    profile.titleOnly &&
    String(link || '').includes('om_item=')
  ) {
    return String(title || '').trim().length >= 5;
  }

  let target;
  let base;

  try {
    target = new URL(link, source.url);
    base = new URL(source.url);
  } catch {
    return false;
  }

  const path =
    target.pathname.toLowerCase();

  const basePath =
    base.pathname.toLowerCase();

  switch (profile.key) {
    case 'visa':
      return path.includes(
        '/uber-visa/newsroom/press-releases.'
      );

    case 'shein':
      return (
        path.includes('/newsroom/') &&
        path !== '/newsroom/' &&
        title.length >= 18
      );

    case 'zalando':
      return (
        path.startsWith(
          '/de/newsroom/news-stories/'
        ) &&
        path !== basePath
      );

    case 'ecdb':
      return (
        path.startsWith('/reports/') &&
        path !== '/reports/'
      );

    case 'mms':
      return path.startsWith(
        '/de/news-presse/pressemitteilungen/'
      );

    case 'tencent':
      return (
        target.hostname.includes('tencent.com') &&
        path !== '/newsroom/all-news/' &&
        path !== '/en-us/media/news.html' &&
        title.length >= 18
      );

    case 'google-ads':
      return (
        path.startsWith(
          '/products/ads-commerce/'
        ) &&
        path !== '/products/ads-commerce/'
      );

    case 'jd-news':
      return (
        target.hostname.includes(
          'jdcorporateblog.com'
        ) &&
        path !== '/' &&
        title.length >= 18
      );

    case 'amazon-freight':
      return (
        target.hostname.includes(
          'freight-amazon.com'
        ) &&
        title.length >= 12
      );

    case 'yougov':
      return (
        path.endsWith('.pdf') &&
        !lowerTitle.startsWith('pdf')
      );

    case 'galaxus':
      return (
        path.startsWith('/de/page/') &&
        path !== basePath &&
        !path.includes('/producttype/') &&
        title.length >= 12
      );

    case 'mordor-case':
      return (
        path.startsWith(
          '/signal/case-studies/'
        ) &&
        path !== '/signal/case-studies'
      );

    case 'mordor-insights':
      return (
        path.startsWith(
          '/signal/insights/'
        ) &&
        path !== '/signal/insights'
      );

    case 'omt':
      return (
        path.startsWith('/events/') &&
        path !== '/events/' &&
        path !==
          '/events/e-commerce-konferenzen/'
      );

    default:
      return true;
  }
}

function looksLikeArticle(text, href, source) {
  if (!text || text.length < 6 || text.length > 320 || !href) {
    return false;
  }

  if (!isAllowedUrl(href, source)) {
    return false;
  }

  let u;

  try {
    u = new URL(href, source.url);
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


async function extractProfiled(page, source) {
  const profile =
    source._stabilityProfile;

  if (!profile) {
    return null;
  }

  if (profile.key === 'experte-events') {
    return await page.locator('body').evaluate(() => {
      const clean = value =>
        (value || '')
          .replace(/\s+/g, ' ')
          .trim();

      const lines =
        (document.body?.innerText || '')
          .split('\n')
          .map(clean)
          .filter(Boolean);

      const dateRx =
        /^(?:\d{1,2}\.\s*-\s*\d{1,2}\.\s+|\d{1,2}\.\s+)(?:Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember)\s+20\d{2}$/i;

      const rows = [];

      for (let i = 0; i < lines.length - 1; i++) {
        const title = lines[i];
        const date = lines[i + 1];

        if (
          dateRx.test(date) &&
          title.length >= 4 &&
          title.length <= 120 &&
          !/^(Business|Marketing|Technologie|Städte|Ticketpreis|Vergangene Events)$/i.test(title)
        ) {
          rows.push({
            title,
            href: '',
            date
          });
        }
      }

      return rows;
    });
  }

  const selector =
    profile.selector;

  if (!selector) {
    return null;
  }

  return await page.locator(selector).evaluateAll(
    (nodes, profileKey) => {
      const clean = value =>
        (value || '')
          .replace(/\s+/g, ' ')
          .trim();

      const genericCTA = value =>
        new Set([
          'mehr erfahren',
          'read more',
          'learn more',
          'weiterlesen',
          'link öffnet in neuem tab',
          'opens in a new tab',
          'download for free',
          'download',
          'webinar ansehen',
          'zur konferenz',
          'mehr'
        ])
        .has(
          clean(value).toLowerCase()
        );

      const cardFor = node =>
        node?.closest?.(
          'article,li,tr,section,' +
          '[class*="card" i],' +
          '[class*="teaser" i],' +
          '[class*="news" i],' +
          '[class*="press" i],' +
          '[class*="event" i],' +
          '[class*="story" i],' +
          '[class*="result" i],' +
          '[class*="item" i],' +
          '[class*="report" i]'
        ) || null;

      const headingFrom = root => {
        if (!root?.querySelector) {
          return '';
        }

        const selectors = [
          'h1','h2','h3','h4','h5','h6',
          '[class*="headline" i]',
          '[class*="heading" i]',
          '[class*="title" i]'
        ];

        for (const selector of selectors) {
          const el =
            root.querySelector(selector);

          const value =
            clean(
              el?.textContent ||
              el?.getAttribute?.('aria-label') ||
              ''
            );

          if (
            value &&
            !genericCTA(value)
          ) {
            return value;
          }
        }

        return '';
      };

      const dateFrom = root => {
        if (!root?.querySelector) {
          return '';
        }

        const selectors = [
          'time[datetime]',
          'time',
          '[class*="date" i]',
          '[class*="datum" i]',
          '[class*="published" i]'
        ];

        for (const selector of selectors) {
          const el =
            root.querySelector(selector);

          const value =
            clean(
              el?.getAttribute?.('datetime') ||
              el?.textContent ||
              ''
            );

          if (
            /\b20\d{2}-\d{1,2}-\d{1,2}\b/.test(value) ||
            /\b\d{1,2}[.\/-]\d{1,2}[.\/-]20\d{2}\b/.test(value) ||
            /\b\d{1,2}\.?\s+(?:Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember|January|February|March|May|June|July|October|December)\s+20\d{2}\b/i.test(value)
          ) {
            return value;
          }
        }

        return '';
      };

      return nodes.map(a => {
        const card =
          cardFor(a);

        const own =
          clean(
            a.textContent ||
            a.getAttribute('aria-label') ||
            a.title ||
            ''
          );

        let title = own;

        if (
          genericCTA(own) ||
          !own ||
          profileKey === 'yougov'
        ) {
          const heading =
            headingFrom(card);

          if (heading) {
            title = heading;
          } else if (
            profileKey === 'yougov' &&
            card
          ) {
            const text =
              clean(card.textContent);

            const withoutPdf =
              text
                .replace(
                  /\bPDF\b.*$/i,
                  ''
                )
                .trim();

            const dateStripped =
              withoutPdf
                .replace(
                  /\b\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+20\d{2}\b/i,
                  ''
                )
                .trim();

            if (dateStripped) {
              title =
                dateStripped;
            }
          }
        }

        return {
          title,
          href:
            a.href ||
            a.getAttribute('href') ||
            '',
          date:
            dateFrom(card)
        };
      });
    },
    profile.key
  );
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
    const title = (r.title || '')
      .replace(/\s+/g, ' ')
      .trim();

    const date = (r.date || '')
      .trim();

    if (!title) continue;

    if (
      source.minTitleLength &&
      title.length < Number(source.minTitleLength)
    ) {
      continue;
    }

    const rawHref =
      r.href ||
      (source.allowTitleOnly === true
        ? syntheticTitleUrl(source, title)
        : '');

    const link = canonicalUrl(rawHref, source.url);

    if (!link) continue;

    /*
     * Titel-only-Quellen haben synthetische URLs zur
     * Wiedererkennung. Sie müssen nicht wie normale
     * Artikel-URLs aussehen.
     */
    if (
      source.allowTitleOnly !== true &&
      !looksLikeArticle(title, link, source)
    ) {
      continue;
    }

    if (
      source.allowTitleOnly === true &&
      !source.minTitleLength &&
      title.length < 12
    ) {
      continue;
    }

    if (
      !stabilityAccepts(
        title,
        link,
        source
      )
    ) {
      continue;
    }

    const item = {
      title,
      link,
      date:
        normalizePageDateV14(
          date,
          link
        )
    };

    if (!matchesConfiguredRules(item, source)) {
      continue;
    }

    if (!map.has(link)) {
      map.set(link, item);
    }
  }

  let result = [...map.values()];

  if (source.reverseDetected === true) {
    result.reverse();
  }

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

function compactSourceName(value = '') {
  let result = String(value || '').trim();

  const suffixPatterns = [
    /\s+News\s*&\s*Presse$/i,
    /\s+News\s*&\s*Events$/i,
    /\s+News\s*&\s*Resources$/i,
    /\s+Press\s+Newsroom$/i,
    /\s+Press\s+Releases$/i,
    /\s+News\s+Releases$/i,
    /\s+Aktuelle\s+Mitteilungen$/i,
    /\s+Corporate\s+News$/i,
    /\s+Medieninformationen$/i,
    /\s+Medienmitteilungen$/i,
    /\s+Pressemitteilungen$/i,
    /\s+Newsroom\s+DE$/i,
    /\s+Newsroom$/i,
    /\s+Presse$/i,
    /\s+Papers$/i,
    /\s+Reports$/i,
    /\s+Blog$/i,
    /\s+Events$/i
  ];

  for (const pattern of suffixPatterns) {
    result = result
      .replace(pattern, '')
      .trim();
  }

  return result || String(value || '').trim() || 'Quelle';
}

function sourceFeedLabel(source) {
  const explicit =
    String(source?.shortName || '')
      .trim();

  if (explicit) {
    return explicit;
  }

  return compactSourceName(
    source?.name || ''
  );
}

function makeFeed(items, sources = []) {
  const now = new Date().toUTCString();

  const sourceMap = new Map(
    sources.map(source => [
      source.name,
      source
    ])
  );

  const body = items.map(item => {
    const configuredSource =
      sourceMap.get(item.source);

    const label =
      configuredSource
        ? sourceFeedLabel(configuredSource)
        : (
            item.sourceLabel ||
            compactSourceName(item.source)
          );

    const feedTitle =
      `${label} · ${item.title}`;

    const meta = [
      `Quelle: ${label}`
    ];

    const published =
      formatGermanDateV14(
        normalizePageDateV14(
          item.pageDate || '',
          item.link || ''
        )
      );

    if (published) {
      meta.push(
        `Veröffentlicht: ${published}`
      );
    }

    const detected =
      formatDetectedAtV14(
        item.detectedAt
      );

    if (detected) {
      meta.push(
        `Erkannt: ${detected}`
      );
    }

    return `
    <item>
      <title>${escXml(feedTitle)}</title>
      <link>${escXml(item.link)}</link>
      <guid isPermaLink="false">${escXml(item.guid)}</guid>
      <pubDate>${escXml(new Date(item.detectedAt).toUTCString())}</pubDate>
      <description>${escXml(meta.join(' · '))}</description>
      <source>${escXml(label)}</source>
    </item>`;
  }).join('');

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


function decodeHtmlEntities(text = '') {
  return String(text)
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&#(\d+);/g, (_, n) => {
      try { return String.fromCodePoint(Number(n)); } catch { return ''; }
    })
    .replace(/&#x([0-9a-f]+);/gi, (_, n) => {
      try { return String.fromCodePoint(parseInt(n, 16)); } catch { return ''; }
    });
}

function stripHtml(html = '') {
  return decodeHtmlEntities(
    String(html)
      .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, ' ')
      .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, ' ')
      .replace(/<[^>]+>/g, ' ')
      .replace(/\s+/g, ' ')
      .trim()
  );
}

function anchorsFromHtml(html = '') {
  const rows = [];
  const re = /<a\b([^>]*?)href\s*=\s*["']([^"']+)["']([^>]*)>([\s\S]*?)<\/a>/gi;
  let m;

  while ((m = re.exec(html))) {
    const title = stripHtml(m[4]);
    const href = decodeHtmlEntities(m[2] || '');

    if (title && href) {
      rows.push({
        title,
        href,
        date: ''
      });
    }
  }

  return rows;
}

async function inspectSourceViaHttp(source, index, total) {
  const started = Date.now();
  const timeoutMs = Math.min(
    Number(source.httpTimeoutMs || 12000),
    20000
  );

  console.log(
    `[${index + 1}/${total}] Start HTTP: ${source.name}`
  );

  const controller = new AbortController();
  const timer = setTimeout(
    () => controller.abort(),
    timeoutMs
  );

  try {
    const response = await fetch(source.url, {
      redirect: 'follow',
      signal: controller.signal,
      headers: {
        'user-agent':
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ' +
          `AppleWebKit/537.36 Chrome/140 Safari/537.36 OM-News-Watcher/${VERSION}`,
        'accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'accept-language':
          'de-DE,de;q=0.9,en;q=0.7'
      }
    });

    if (!response.ok) {
      throw new Error(
        `HTTP ${response.status} ${response.statusText}`
      );
    }

    const html = await response.text();
    const rows = normalizeAndFilter(
      anchorsFromHtml(html),
      source
    );

    return {
      source,
      rows,
      notes: [
        `Direkter HTML-Abruf: ${Math.round(html.length / 1024)} KB`
      ],
      durationMs: Date.now() - started,
      error: null
    };
  } catch (err) {
    return {
      source,
      rows: [],
      notes: [],
      durationMs: Date.now() - started,
      error: err
    };
  } finally {
    clearTimeout(timer);
    console.log(
      `[${index + 1}/${total}] Ende HTTP: ${source.name} (${((Date.now() - started) / 1000).toFixed(1)}s)`
    );
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

    if (source.skipCookieDismiss !== true) {
      await dismissCookies(page);
    }

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

    let rows =
      await extractProfiled(
        page,
        source
      );

    if (!rows || !rows.length) {
      rows = await extractConfigured(
        page,
        source
      );
    }

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

  const configuredSources = readJson(
    SOURCES_FILE,
    []
  ).filter(
    s => s.enabled !== false
  );

  const sources =
    configuredSources.map(
      applyStabilityProfile
    );

  const state = readJson(
    STATE_FILE,
    {
      seenBySource: {},
      initializedBySource: {},
      configVersionBySource: {},
      globalBaselineBySource: {},
      feedResetToken: null
    }
  );

  state.seenBySource =
    state.seenBySource || {};

  state.initializedBySource =
    state.initializedBySource || {};

  state.configVersionBySource =
    state.configVersionBySource || {};

  state.globalBaselineBySource =
    state.globalBaselineBySource || {};

  let items = readJson(
    ITEMS_FILE,
    []
  );

  if (state.feedResetToken !== FEED_RESET_TOKEN) {
    console.log(
      `Einmalige Feed-Bereinigung (${FEED_RESET_TOKEN}): ${items.length} alte Testeinträge entfernt.`
    );

    items = [];
    state.feedResetToken = FEED_RESET_TOKEN;
  }

  items = pruneStoredItems(
    items,
    configuredSources
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
      makeFeed(items, sources)
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
      source.fetchMode === 'html'
        ? inspectSourceViaHttp(
            source,
            index,
            sources.length
          )
        : inspectSourceWithHardTimeout(
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
      console.log(
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

    const requestedBaseline =
      String(source.baselineVersion || '');

    const storedBaseline =
      String(state.configVersionBySource[key] || '');

    const configChanged =
      requestedBaseline &&
      requestedBaseline !== storedBaseline;

    const needsGlobalBaseline =
      state.globalBaselineBySource[key] !==
      GLOBAL_BASELINE_TOKEN;

    const firstRun =
      needsGlobalBaseline ||
      configChanged ||
      (
        state.initializedBySource[key] !== true &&
        !hadPriorState
      );

    const known =
      new Set(
        (needsGlobalBaseline || configChanged)
          ? []
          : (state.seenBySource[key] || [])
      );

    if (needsGlobalBaseline) {
      console.log(
        `  ↻ Sauberer Gesamt-Ausgangspunkt (${GLOBAL_BASELINE_TOKEN}) – Quelle wird einmalig neu baseline-gesetzt.`
      );
    }

    if (configChanged) {
      console.log(
        `  ↻ Neue Erkennungsregel (${requestedBaseline}) – Quelle wird einmalig neu baseline-gesetzt.`
      );
    }

    if (rows.length === 0) {
      console.log(
        '  ⚠ KEINE ARTIKEL ERKANNT – Quelle prüfen.'
      );

      state.initializedBySource[key] =
        true;

      if (!hadPriorState || configChanged) {
        state.seenBySource[key] =
          [];
      }

      if (requestedBaseline) {
        state.configVersionBySource[key] = requestedBaseline;
      }

      state.globalBaselineBySource[key] =
        GLOBAL_BASELINE_TOKEN;

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

          sourceLabel:
            sourceFeedLabel(source),

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

    if (requestedBaseline) {
      state.configVersionBySource[key] = requestedBaseline;
    }

    state.globalBaselineBySource[key] =
      GLOBAL_BASELINE_TOKEN;
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
    makeFeed(items, sources)
  );

  console.log(
    `\nRSS geschrieben: ${FEED_FILE} (${items.length} Einträge)`
  );

})().catch(err => {
  console.error(err);
  process.exit(1);
});
