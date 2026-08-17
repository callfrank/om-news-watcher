const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { chromium } = require('playwright');

const ROOT = __dirname;
const SOURCES_FILE = path.join(ROOT, 'sources.json');
const STATE_FILE = path.join(ROOT, 'data', 'state.json');
const ITEMS_FILE = path.join(ROOT, 'data', 'items.json');
const FEED_FILE = path.join(ROOT, 'docs', 'feed.xml');

const VERSION = '0.17';

const MAX_SEEN_PER_SOURCE = 2500;
const MAX_FEED_ITEMS = 500;
const DEFAULT_SAMPLE_COUNT = 3;

/*
 * v0.15: stabiler v0.12-Kern + visuell eingelernten Selektoren + Datumsmetadaten
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


function normalizeTitle(value = '') {
  let result = String(value || '')
    .replace(/\s+/g, ' ')
    .trim();

  result = result.replace(
    /\s*(?:mehr erfahren|mehr anzeigen|weiterlesen|read article|read more|learn more|download(?: for free)?|zur konferenz)\s*[›>…\.]*\s*$/i,
    ''
  );

  for (let i = 0; i < 3; i++) {
    const next = result.replace(
      /^(?:presseinformation|pressemitteilung|press release|company updates?|presse)\s*[:\-–—]?\s*/i,
      ''
    );
    if (next === result) break;
    result = next;
  }

  result = result.replace(
    /^\d{1,2}\.?\s+(?:jan(?:uar)?|feb(?:ruar)?|mär(?:z)?|mrz|apr(?:il)?|mai|jun(?:i)?|jul(?:i)?|aug(?:ust)?|sep(?:tember)?|okt(?:ober)?|nov(?:ember)?|dez(?:ember)?|january|february|march|april|may|june|july|august|september|october|november|december)\.?\s+20\d{2}\s*[:\-–—]?\s*/i,
    ''
  );

  result = result.replace(
    /^20\d{2}-\d{2}-\d{2}(?:T[^\s]+)?\s*[:\-–—]?\s*/,
    ''
  );

  return result
    .replace(/^[\-–—:|·\s]+|[\-–—:|·\s]+$/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function genericTitle(value = '') {
  const lower = String(value || '').replace(/\s+/g, ' ').trim().toLowerCase();
  if (!lower) return true;

  const exact = new Set([
    'home','startseite','kontakt','contact','about','über uns','impressum',
    'datenschutz','privacy','login','jobs','karriere','services','service',
    'governance','media','stories','publications','news','presse','press',
    'menu','navigation','newsroom','press releases','pressemitteilungen',
    'events','media & resources','news & resources','unternehmensnews',
    'unternehmensmitteilungen','company news','company updates'
  ]);
  if (exact.has(lower)) return true;

  if (/^(mehr erfahren|read more|read article|learn more|weiterlesen|download(?: for free)?|details|more|zur konferenz)/i.test(lower)) return true;
  if (/^pdf\s*[-–—:]?\s*\d+(?:[.,]\d+)?\s*(kb|mb)?$/i.test(lower)) return true;
  return false;
}

function samePage(candidate, sourceUrl) {
  try {
    const a = new URL(candidate, sourceUrl);
    const b = new URL(sourceUrl);
    const norm = p => p.length > 1 && p.endsWith('/') ? p.slice(0, -1) : (p || '/');
    return a.hostname.toLowerCase() === b.hostname.toLowerCase() &&
      norm(a.pathname) === norm(b.pathname) &&
      !a.search && !b.search;
  } catch {
    return false;
  }
}

function visualSampleShapeAllows(link, source) {
  const raw = Array.isArray(source.visualSampleURLs) ? source.visualSampleURLs : [];
  if (raw.length < 2) return true;

  let samples, candidate;
  try {
    samples = raw.map(value => new URL(value, source.url));
    candidate = new URL(link, source.url);
  } catch {
    return true;
  }

  const hosts = new Set(samples.map(u => u.hostname.toLowerCase()));
  if (hosts.size === 1) {
    const host = [...hosts][0];
    const ch = candidate.hostname.toLowerCase();
    if (!(ch === host || ch.endsWith('.' + host) || host.endsWith('.' + ch))) return false;
  }

  if (samples.every(u => !u.search) && candidate.search) return false;

  const exts = new Set(samples.map(u => (u.pathname.match(/\.([a-z0-9]{1,6})$/i)?.[1] || '').toLowerCase()));
  if (exts.size === 1) {
    const ext = [...exts][0];
    const candidateExt = (candidate.pathname.match(/\.([a-z0-9]{1,6})$/i)?.[1] || '').toLowerCase();
    if (!ext && /^(pdf|docx?|xlsx?|zip)$/i.test(candidateExt)) return false;
    if (ext && candidateExt !== ext) return false;
  }

  const parts = samples.map(u => u.pathname.split('/').filter(Boolean));
  const depths = parts.map(v => v.length);
  const minDepth = Math.min(...depths), maxDepth = Math.max(...depths);
  const candidateParts = candidate.pathname.split('/').filter(Boolean);
  if (maxDepth - minDepth <= 1 && (candidateParts.length < minDepth || candidateParts.length > maxDepth)) return false;

  const leafLengths = parts.map(v => (v.at(-1) || '').length);
  const shortest = Math.min(...leafLengths);
  const threshold = Math.max(10, Math.min(40, Math.floor(shortest * 0.45)));
  if ((candidateParts.at(-1) || '').length < threshold) return false;

  const minParts = Math.min(...parts.map(v => v.length));
  const common = [];
  for (let i = 0; i < Math.max(0, minParts - 1); i++) {
    const value = parts[0][i];
    if (parts.every(list => list[i] === value)) common.push(value); else break;
  }
  if (common.length && common.some((value, index) => candidateParts[index] !== value)) return false;

  return true;
}

function semanticSourcePrefix(source) {
  try {
    const u = new URL(source.url);
    const parts = u.pathname.split('/').filter(Boolean);
    const last = (parts.at(-1) || '').toLowerCase();
    const semantic = new Set(['newsroom','news','presse','press','press-releases','pressemitteilungen','stories','reports','events']);
    if (!semantic.has(last)) return '';
    return u.pathname.endsWith('/') ? u.pathname : u.pathname + '/';
  } catch {
    return '';
  }
}

function normalizePageDate(value = '') {
  const text = String(value || '').replace(/\s+/g, ' ').trim();
  if (!text) return '';

  const iso = new Date(text);
  if (!Number.isNaN(iso.getTime()) && /^20\d{2}-\d{2}-\d{2}/.test(text)) {
    return new Intl.DateTimeFormat('de-DE', {
      timeZone: 'Europe/Berlin', day: '2-digit', month: '2-digit', year: 'numeric'
    }).format(iso);
  }

  const m = text.match(/\b(\d{1,2})\.?\s+(Jan(?:uar)?|Feb(?:ruar)?|Mär(?:z)?|Mrz|Apr(?:il)?|Mai|Jun(?:i)?|Jul(?:i)?|Aug(?:ust)?|Sep(?:tember)?|Okt(?:ober)?|Nov(?:ember)?|Dez(?:ember)?)\.?\s+(20\d{2})\b/i);
  if (m) {
    const map = {jan:1,januar:1,feb:2,februar:2,mär:3,märz:3,mrz:3,apr:4,april:4,mai:5,jun:6,juni:6,jul:7,juli:7,aug:8,august:8,sep:9,september:9,okt:10,oktober:10,nov:11,november:11,dez:12,dezember:12};
    const month = map[m[2].toLowerCase()];
    if (month) return `${String(Number(m[1])).padStart(2,'0')}.${String(month).padStart(2,'0')}.${m[3]}`;
  }

  return text;
}

function looksLikeArticle(text, href, source) {
  if (!text || text.length < 6 || text.length > 320 || !href) {
    return false;
  }

  if (genericTitle(text)) {
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

async function extractConfigured(page, source) {
  const sel = source.selectors || {};
  if (!sel.item) return null;

  return await page.locator(sel.item).evaluateAll((nodes, cfg) => {
    const clean = value => (value || '').replace(/\s+/g, ' ').trim();
    const clickableSelector = 'a[href],[data-href],[data-url],[data-link],[role="link"],button[onclick]';
    const generic = value => {
      const lower = clean(value).toLowerCase();
      return !lower || /^(mehr erfahren|read more|read article|learn more|weiterlesen|download(?: for free)?|details|more|zur konferenz)/i.test(lower) || /^pdf\s*[-–—:]?\s*\d+(?:[.,]\d+)?\s*(kb|mb)?$/i.test(lower);
    };
    const pick = (root, selector) => {
      if (!root || !selector) return null;
      try { return root.matches?.(selector) ? root : root.querySelector?.(selector); } catch { return null; }
    };
    const hrefFrom = (el, root) => {
      const nodes = [el, el?.closest?.('a[href]'), root];
      for (const node of nodes) {
        if (!node?.getAttribute) continue;
        const raw = node.href || node.getAttribute('href') || node.getAttribute('data-href') || node.getAttribute('data-url') || node.getAttribute('data-link') || '';
        if (raw) return raw;
        const onclick = node.getAttribute('onclick') || '';
        const m = onclick.match(/(?:location(?:\.href)?\s*=|window\.open\s*\()\s*['"]([^'"]+)['"]/i);
        if (m?.[1]) return m[1];
      }
      const link = root?.querySelector?.('a[href]');
      return link?.href || link?.getAttribute?.('href') || '';
    };
    const smartTitle = (el, root) => {
      const selectors = 'h1,h2,h3,h4,h5,h6,[class*="headline" i],[class*="heading" i],[class*="title" i],[data-testid*="title" i],strong';
      for (const node of Array.from(root?.querySelectorAll?.(selectors) || [])) {
        const value = clean(node.textContent || node.getAttribute?.('aria-label') || '');
        if (value.length >= 5 && value.length <= 320 && !generic(value)) return value;
      }
      const own = clean(el?.textContent || el?.getAttribute?.('aria-label') || el?.title || '');
      if (own && own.length <= 320 && !generic(own)) return own;
      const alt = clean(root?.querySelector?.('img[alt]')?.getAttribute?.('alt') || '');
      return alt.length >= 8 ? alt : own;
    };
    const dateOf = root => {
      const el = root?.querySelector?.('time[datetime],time,[class*="date" i],[class*="datum" i],[class*="published" i],[class*="time" i]');
      return clean(el?.getAttribute?.('datetime') || el?.textContent || '');
    };

    return nodes.map(root => {
      let linkEl = cfg.link ? pick(root, cfg.link) : null;
      linkEl = linkEl || (root.matches?.(clickableSelector) ? root : root.querySelector?.(clickableSelector));
      let titleEl = cfg.title ? pick(root, cfg.title) : null;
      let title = clean(titleEl?.textContent || titleEl?.getAttribute?.('aria-label') || '');
      if (!title || generic(title)) title = smartTitle(linkEl || root, root);
      let date = '';
      if (cfg.date) {
        const dateEl = pick(root, cfg.date);
        date = clean(dateEl?.getAttribute?.('datetime') || dateEl?.textContent || '');
      }
      if (!date) date = dateOf(root);
      return { title, href: hrefFrom(linkEl || root, root), date };
    });
  }, sel);
}

async function extractAutomatic(page, source) {
  const custom = source.candidateSelector;
  const selector = custom || 'a[href],[data-href],[data-url],[data-link],[role="link"],button[onclick]';

  return await page.locator(selector).evaluateAll(nodes => {
    const clean = value => (value || '').replace(/\s+/g, ' ').trim();
    const cardSelector = 'article,li,tr,section,[class*="card" i],[class*="teaser" i],[class*="news" i],[class*="press" i],[class*="event" i],[class*="story" i],[class*="result" i],[class*="item" i],[class*="report" i],[class*="post" i]';
    const generic = value => {
      const lower = clean(value).toLowerCase();
      return !lower || /^(mehr erfahren|read more|read article|learn more|weiterlesen|download(?: for free)?|details|more|zur konferenz)/i.test(lower) || /^pdf\s*[-–—:]?\s*\d+(?:[.,]\d+)?\s*(kb|mb)?$/i.test(lower);
    };
    const hrefFrom = (el, card) => {
      const nodes2 = [el, el?.closest?.('a[href]'), card];
      for (const node of nodes2) {
        if (!node?.getAttribute) continue;
        const raw = node.href || node.getAttribute('href') || node.getAttribute('data-href') || node.getAttribute('data-url') || node.getAttribute('data-link') || '';
        if (raw) return raw;
        const onclick = node.getAttribute('onclick') || '';
        const m = onclick.match(/(?:location(?:\.href)?\s*=|window\.open\s*\()\s*['"]([^'"]+)['"]/i);
        if (m?.[1]) return m[1];
      }
      const link = card?.querySelector?.('a[href]');
      return link?.href || link?.getAttribute?.('href') || '';
    };
    const titleFor = (el, card) => {
      const selectors = 'h1,h2,h3,h4,h5,h6,[class*="headline" i],[class*="heading" i],[class*="title" i],[data-testid*="title" i],strong';
      for (const node of Array.from(card?.querySelectorAll?.(selectors) || [])) {
        const value = clean(node.textContent || node.getAttribute?.('aria-label') || '');
        if (value.length >= 5 && value.length <= 320 && !generic(value)) return value;
      }
      const own = clean(el?.textContent || el?.getAttribute?.('aria-label') || el?.title || '');
      if (own && own.length <= 320 && !generic(own)) return own;
      const alt = clean(card?.querySelector?.('img[alt]')?.getAttribute?.('alt') || '');
      return alt.length >= 8 ? alt : own;
    };
    const dateFor = card => {
      const el = card?.querySelector?.('time[datetime],time,[class*="date" i],[class*="datum" i],[class*="published" i],[class*="time" i]');
      return clean(el?.getAttribute?.('datetime') || el?.textContent || '');
    };

    return nodes.map(el => {
      const card = el.closest?.(cardSelector) || el.parentElement || el;
      return { title: titleFor(el, card), href: hrefFrom(el, card), date: dateFor(card) };
    });
  });
}

function normalizeAndFilter(rows, source) {
  const map = new Map();

  for (const r of rows || []) {
    const title = normalizeTitle(r.title || '');

    const date = normalizePageDate(r.date || '');

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
    if (source.allowTitleOnly !== true && samePage(link, source.url)) continue;
    if (genericTitle(title)) continue;
    if (source.visualLearned === true && !visualSampleShapeAllows(link, source)) continue;

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

  const semanticPrefix = semanticSourcePrefix(source);
  if (semanticPrefix && result.length >= 8) {
    const scoped = result.filter(item => {
      try {
        const u = new URL(item.link);
        return u.pathname.startsWith(semanticPrefix) && !samePage(item.link, source.url);
      } catch { return false; }
    });
    if (scoped.length >= 5 && scoped.length / result.length >= 0.35) {
      result = scoped;
    }
  }

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

    const pageDate =
      String(item.pageDate || '')
        .replace(/\s+/g, ' ')
        .trim();

    if (pageDate) {
      meta.push(`Veröffentlicht: ${pageDate}`);
    }

    try {
      const detected = new Intl.DateTimeFormat(
        'de-DE',
        {
          timeZone: 'Europe/Berlin',
          day: '2-digit',
          month: '2-digit',
          year: 'numeric',
          hour: '2-digit',
          minute: '2-digit'
        }
      ).format(new Date(item.detectedAt));

      if (detected) {
        meta.push(`Erkannt: ${detected}`);
      }
    } catch {}

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
