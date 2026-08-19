const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { chromium } = require('playwright');

const ROOT = __dirname;
const SOURCES_FILE = path.join(ROOT, 'sources.json');
const STATE_FILE = path.join(ROOT, 'data', 'state.json');
const ITEMS_FILE = path.join(ROOT, 'data', 'items.json');
const FEED_FILE = path.join(ROOT, 'docs', 'feed.xml');
const GROUP_FEED_DIR = path.join(ROOT, 'docs', 'feeds');
const GROUP_FEED_INDEX = path.join(GROUP_FEED_DIR, 'index.json');
const HEALTH_FILE = path.join(ROOT, 'data', 'health.json');

const VERSION = '0.29';

const MAX_SEEN_PER_SOURCE = 2500;
const MAX_DELIVERED_PER_SOURCE = 2500;
const MAX_BASELINE_SUPPRESSED_PER_SOURCE = 2500;
const MAX_FEED_ITEMS = 500;
const DEFAULT_SAMPLE_COUNT = 3;
const SELF_HEAL_WINDOW_HOURS = 48;
const HISTORICAL_BACKFILL_HOURS = 72;
const DELIVERY_FRESH_HOURS = 48;
const TRACKING_SCHEMA_VERSION = 3;

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
      if (
        /^(utm_|fbclid$|gclid$|mc_|ref$|ref_|source$)/i.test(k) ||
        /^_?omw_fresh$/i.test(k) ||
        /^cache_?bust$/i.test(k)
      ) {
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
    'unternehmensmitteilungen','company news','company updates',
    'main menu','who we are','find us','find us on',
    'dokumentation zur fehlerbehebung','aktualisieren sie diese seite',
    'update this page','all publications','alle publikationen',
    'broschüren und infomaterial','broschueren und infomaterial',
    'brochures and information material'
  ]);
  if (exact.has(lower)) return true;

  // CSS-/SVG-Artefakte dürfen niemals als Titel gespeichert werden.
  if (/\.[a-z0-9_-]+\s*\{[^}]{0,400}(?:fill|stroke|color|font|display)\s*:/i.test(lower)) return true;
  if (/[{};]/.test(lower) && /(?:stroke-width|stroke-linecap|stroke-linejoin|fill|stroke)\s*:/i.test(lower)) return true;

  if (/^(?:seite|page)\s*\d+$/i.test(lower)) return true;
  if (/^(?:aktuelle\s+seite|current\s+page)\s*\d+$/i.test(lower)) return true;
  if (/^(mehr erfahren|read more|read article|learn more|weiterlesen|download(?: for free)?|details|more|zur konferenz)/i.test(lower)) return true;
  if (/^pdf\s*[-–—:]?\s*\d+(?:[.,]\d+)?\s*(kb|mb)?$/i.test(lower)) return true;
  return false;
}

function highConfidenceStaticPath(link, source) {
  try {
    const u = new URL(link, source.url);
    const path = u.pathname.toLowerCase();
    const strongNewsPath =
      /\/(news|newsroom|presse|press|press-releases|pressemitteilungen|media\/news|stories|reports|insights|articles?)\//i.test(path);

    if (strongNewsPath) return false;

    return /\/(?:privacy|privacy-policy|cookies?|terms|legal|impressum|contact|kontakt|careers?|jobs?|who-we-are|find-us|pricing|prices|developer(?:s|-portal)?|products?|solutions?|partners?)(?:\/|$)/i.test(path);
  } catch {
    return false;
  }
}

function highConfidenceDocumentPath(link) {
  try {
    const path = new URL(link).pathname.toLowerCase();

    // Behörden-Publikationen, Broschüren und Ratgeber sind dauerhafte
    // Dokumentseiten, keine neu eingestellten Nachrichten. Gesetzgebungs-
    // verfahren bleiben dagegen zulässig und werden über das Datum geprüft.
    if (/\/shareddocs\/publikationen\//i.test(path)) return true;
    if (/\/(?:broschueren|broschuren|brochures|ratgeber|guides)\//i.test(path)) return true;

    return false;
  } catch {
    return false;
  }
}


function highConfidenceSectionLanding(title, link) {
  const lowerTitle =
    normalizeTitle(title || '').toLowerCase();

  const exactTitles = new Set([
    'publikationen',
    'publications',
    'financial reports and presentations',
    'finanzberichte und präsentationen',
    'finanzberichte und praesentation',
    'nichtfinanzieller konzernbericht',
    'non-financial report',
    'non-financial report for the group',
    'diversity & inclusion',
    'diversity and inclusion',
    'ipo mitteilungen',
    'ipo news',
    'wertpapierprospekt',
    'prospectus',
    'investor relations',
    'investor information'
  ]);

  if (exactTitles.has(lowerTitle)) {
    return true;
  }

  try {
    const u = new URL(link);

    // Kaputte Linkauflösung wie
    // /de/https://www.example.com/... darf nie als Artikel gelten.
    if (/\/https?:\/\//i.test(u.pathname)) {
      return true;
    }

    const path = u.pathname.toLowerCase();

    return (
      /\/(?:financial-reports-and-presentations|non-financial-report(?:-for-the-group)?|diversity-inclusion|publications?|publikationen)(?:\/|$)/i.test(path) ||
      /\/ipo\/(?:ipo-news|prospectus)?\/?$/i.test(path) ||
      /\/(?:prospectus|wertpapierprospekt)\/?$/i.test(path)
    );
  } catch {
    return true;
  }
}

function undatedCandidateLooksArticleLike(row, source) {
  const title =
    normalizeTitle(row?.title || '');

  const link =
    canonicalUrl(
      row?.link || row?.href || '',
      source.url
    );

  if (!title || !link) {
    return false;
  }

  if (highConfidenceSectionLanding(title, link)) {
    return false;
  }

  try {
    const u = new URL(link);
    const parts =
      u.pathname
        .split('/')
        .filter(Boolean);

    const leaf =
      (parts.at(-1) || '').toLowerCase();

    const semanticArticlePath =
      /\/(?:newsroom|news|nachrichten|presse|press|press-releases|pressemitteilungen|stories|story|article|articles|blog)\//i.test(
        u.pathname
      );

    const datedPath =
      /\/20\d{2}\//.test(u.pathname);

    const slugLike =
      leaf.length >= 18 &&
      (
        (leaf.match(/-/g) || []).length >= 2 ||
        leaf.length >= 30
      );

    // Visuell validierte Regeln dürfen auch auf Seiten ohne sichtbares
    // Veröffentlichungsdatum funktionieren, sofern die URL klar
    // artikelartig ist.
    if (
      source.visualLearned === true &&
      visualSampleShapeAllows(link, source) &&
      slugLike
    ) {
      return true;
    }

    if (semanticArticlePath && slugLike) {
      return true;
    }

    if (datedPath && slugLike) {
      return true;
    }

    return (
      parts.length >= 3 &&
      title.length >= 28 &&
      slugLike
    );
  } catch {
    return false;
  }
}

function passesQualityGate(item, source) {
  const title = normalizeTitle(item?.title || '');
  const link = canonicalUrl(item?.link || item?.href || '', source.url);
  const date = normalizePageDate(item?.date || item?.pageDate || '');

  if (!title || !link) return false;
  if (genericTitle(title)) return false;
  if (samePage(link, source.url)) return false;
  if (highConfidenceDocumentPath(link)) return false;
  if (highConfidenceSectionLanding(title, link)) return false;

  // Statische Navigations-/Produktbereiche ohne Veröffentlichungsdatum sind
  // keine News. Ein explizites Datum oder ein echter Newsroom-Pfad gewinnt.
  if (!date && highConfidenceStaticPath(link, source)) return false;

  return true;
}

function deliveryEligibility(row, source, checkedAt) {
  if (!passesQualityGate(row, source)) {
    return { eligible: false, reason: 'quality-gate' };
  }

  const rowTime = pageDateTimestamp(row?.date || '');

  // Sobald ein belastbares Veröffentlichungsdatum vorhanden ist, darf ein
  // alter Artikel NIE nur deshalb als neu gelten, weil seine URL erstmals
  // gesehen wurde. Das ist die zentrale Trennung zwischen Erkennung und News.
  if (Number.isFinite(rowTime)) {
    if (!rowIsRecent(row, checkedAt, DELIVERY_FRESH_HOURS)) {
      return { eligible: false, reason: 'published-outside-current-window' };
    }

    return { eligible: true, reason: 'current-publication-date' };
  }

  // Kein Datum mehr = nicht automatisch aktuell.
  // Nur eindeutig artikelartige URLs dürfen ohne Datum passieren.
  if (!undatedCandidateLooksArticleLike(row, source)) {
    return { eligible: false, reason: 'undated-section-or-weak-article-signal' };
  }

  return { eligible: true, reason: 'undated-but-article-like' };
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


function pageDateTimestamp(value = '') {
  const text = String(value || '').replace(/\s+/g, ' ').trim();
  if (!text) return NaN;

  let match = text.match(/^(\d{1,2})\.(\d{1,2})\.(20\d{2})$/);
  if (match) {
    return Date.UTC(
      Number(match[3]),
      Number(match[2]) - 1,
      Number(match[1]),
      12, 0, 0
    );
  }

  match = text.match(/^(20\d{2})-(\d{2})-(\d{2})(?:T.*)?$/);
  if (match) {
    return Date.UTC(
      Number(match[1]),
      Number(match[2]) - 1,
      Number(match[3]),
      12, 0, 0
    );
  }

  match = text.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](20\d{2})$/);
  if (match) {
    return Date.UTC(
      Number(match[3]),
      Number(match[2]) - 1,
      Number(match[1]),
      12, 0, 0
    );
  }

  // Browser-/CMS-Daten wie "Aug. 18, 2026" oder "August 18, 2026".
  const parsed = Date.parse(text.replace(/\bSept\./i, 'Sep'));
  return Number.isFinite(parsed) ? parsed : NaN;
}

function publicationISOFromPageDate(value = '') {
  const timestamp = pageDateTimestamp(value);
  if (!Number.isFinite(timestamp)) return null;
  return new Date(timestamp).toISOString();
}

function itemPublishedTimestamp(item) {
  const published = Date.parse(String(item?.publishedAt || ''));
  if (Number.isFinite(published)) return published;
  return pageDateTimestamp(item?.pageDate || '');
}

function isHistoricalBackfill(item, hours = HISTORICAL_BACKFILL_HOURS) {
  const published = itemPublishedTimestamp(item);
  const delivered = Date.parse(
    String(item?.deliveredAt || item?.detectedAt || '')
  );

  if (!Number.isFinite(published) || !Number.isFinite(delivered)) {
    return item?.historicalBackfill === true;
  }

  return delivered - published > hours * 60 * 60 * 1000;
}

function rowIsRecent(row, checkedAt, hours = SELF_HEAL_WINDOW_HOURS) {
  const rowTime = pageDateTimestamp(row?.date || '');
  const checkedTime = Date.parse(checkedAt || '');

  if (!Number.isFinite(rowTime) || !Number.isFinite(checkedTime)) {
    return false;
  }

  const age = checkedTime - rowTime;

  // Ein reines Veröffentlichungsdatum wird auf 12 Uhr UTC normalisiert.
  // Deshalb etwas Zukunftstoleranz zulassen.
  return (
    age >= -(24 * 60 * 60 * 1000) &&
    age <= hours * 60 * 60 * 1000
  );
}

function compactAuditRow(row) {
  if (!row) return null;

  return {
    title: row.title || '',
    link: row.link || '',
    pageDate: row.date || null,
    publishedAt: publicationISOFromPageDate(row.date || '')
  };
}

function appendUniqueLimited(existing, values, limit) {
  return [
    ...new Set([
      ...(values || []).filter(Boolean),
      ...(existing || []).filter(Boolean)
    ])
  ].slice(0, limit);
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

  const lowerTitle = String(item.title || '').toLowerCase();
  const includeKeywords = Array.isArray(source.includeKeywords) ? source.includeKeywords.filter(Boolean) : [];
  const excludeKeywords = Array.isArray(source.excludeKeywords) ? source.excludeKeywords.filter(Boolean) : [];
  if (includeKeywords.length && !includeKeywords.some(k => lowerTitle.includes(String(k).toLowerCase()))) return false;
  if (excludeKeywords.some(k => lowerTitle.includes(String(k).toLowerCase()))) return false;

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
    const clickableSelector = 'a[href],[data-href],[data-url],[data-link],[role="link"],button[onclick],[onclick]';
    const generic = value => {
      const lower = clean(value).toLowerCase();
      return !lower || /^(mehr erfahren|read more|read article|learn more|weiterlesen|download(?: for free)?|details|more|zur konferenz)/i.test(lower) || /^pdf\s*[-–—:]?\s*\d+(?:[.,]\d+)?\s*(kb|mb)?$/i.test(lower);
    };
    const pick = (root, selector) => {
      if (!root || !selector) return null;
      try { return root.matches?.(selector) ? root : root.querySelector?.(selector); } catch { return null; }
    };
    const hrefFrom = (el, root) => {
      const nodes = [el, el?.closest?.('a[href],[data-href],[data-url],[data-link],[role="link"],[onclick]'), root];
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
    const dateFromText = value => {
      const text = clean(value);
      if (!text) return '';

      const patterns = [
        /\b\d{1,2}\.\d{1,2}\.20\d{2}\b/,
        /\b20\d{2}-\d{2}-\d{2}\b/,
        /\b\d{1,2}\.?\s+(?:Jan(?:uar)?|Feb(?:ruar)?|Mär(?:z)?|Mrz|Apr(?:il)?|Mai|Jun(?:i)?|Jul(?:i)?|Aug(?:ust)?|Sep(?:tember)?|Okt(?:ober)?|Nov(?:ember)?|Dez(?:ember)?|January|February|March|April|May|June|July|August|September|October|November|December)\.?\s+20\d{2}\b/i,
        /\b(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+\d{1,2},\s+20\d{2}\b/i
      ];

      for (const pattern of patterns) {
        const match = text.match(pattern);
        if (match?.[0]) return match[0];
      }

      return '';
    };

    const dateOf = root => {
      const el = root?.querySelector?.('time[datetime],time,[class*="date" i],[class*="datum" i],[class*="published" i],[class*="time" i]');
      const explicit = clean(el?.getAttribute?.('datetime') || el?.textContent || '');
      return explicit || dateFromText(root?.textContent || '');
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
  const selector = custom || 'a[href],[data-href],[data-url],[data-link],[role="link"],button[onclick],[onclick]';

  return await page.locator(selector).evaluateAll(nodes => {
    const clean = value => (value || '').replace(/\s+/g, ' ').trim();
    const cardSelector = 'article,li,tr,section,[class*="card" i],[class*="teaser" i],[class*="news" i],[class*="press" i],[class*="event" i],[class*="story" i],[class*="result" i],[class*="item" i],[class*="report" i],[class*="post" i]';
    const generic = value => {
      const lower = clean(value).toLowerCase();
      return !lower || /^(mehr erfahren|read more|read article|learn more|weiterlesen|download(?: for free)?|details|more|zur konferenz)/i.test(lower) || /^pdf\s*[-–—:]?\s*\d+(?:[.,]\d+)?\s*(kb|mb)?$/i.test(lower);
    };
    const hrefFrom = (el, card) => {
      const nodes2 = [el, el?.closest?.('a[href],[data-href],[data-url],[data-link],[role="link"],[onclick]'), card];
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
    const dateFromText = value => {
      const text = clean(value);
      if (!text) return '';

      const patterns = [
        /\b\d{1,2}\.\d{1,2}\.20\d{2}\b/,
        /\b20\d{2}-\d{2}-\d{2}\b/,
        /\b\d{1,2}\.?\s+(?:Jan(?:uar)?|Feb(?:ruar)?|Mär(?:z)?|Mrz|Apr(?:il)?|Mai|Jun(?:i)?|Jul(?:i)?|Aug(?:ust)?|Sep(?:tember)?|Okt(?:ober)?|Nov(?:ember)?|Dez(?:ember)?|January|February|March|April|May|June|July|August|September|October|November|December)\.?\s+20\d{2}\b/i,
        /\b(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+\d{1,2},\s+20\d{2}\b/i
      ];

      for (const pattern of patterns) {
        const match = text.match(pattern);
        if (match?.[0]) return match[0];
      }

      return '';
    };

    const dateFor = card => {
      const el = card?.querySelector?.('time[datetime],time,[class*="date" i],[class*="datum" i],[class*="published" i],[class*="time" i]');
      const explicit = clean(el?.getAttribute?.('datetime') || el?.textContent || '');
      return explicit || dateFromText(card?.textContent || '');
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

    if (!passesQualityGate(item, source)) {
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
  let canonicalized = 0;
  let deduped = 0;
  const kept = [];
  const seenGuids = new Set();
  const seenSourceTitles = new Set();

  const sorted = [...(items || [])].sort(
    (a, b) => Date.parse(b.detectedAt || 0) - Date.parse(a.detectedAt || 0)
  );

  for (const original of sorted) {
    const source = sourceMap.get(original.source);

    if (!source) {
      kept.push(original);
      continue;
    }

    const link = canonicalUrl(original.link || '', source.url);
    const candidate = {
      title: original.title || '',
      link,
      pageDate: original.pageDate || '',
      date: original.pageDate || ''
    };

    if (!link || !matchesConfiguredRules(candidate, source) || !passesQualityGate(candidate, source)) {
      removed++;
      continue;
    }

    const guid = idFor(link);
    if (link !== original.link || guid !== original.guid) {
      canonicalized++;
    }

    const titleKey =
      String(original.source || '').toLowerCase() + '|' +
      normalizeTitle(original.title || '').toLowerCase();

    if (seenGuids.has(guid) || seenSourceTitles.has(titleKey)) {
      deduped++;
      continue;
    }

    seenGuids.add(guid);
    seenSourceTitles.add(titleKey);

    kept.push({
      ...original,
      link,
      guid
    });
  }

  if (removed || canonicalized || deduped) {
    console.log(
      `Quality Gate: ${removed} ungeeignete Einträge entfernt, ` +
      `${canonicalized} URLs kanonisiert, ${deduped} Duplikate zusammengeführt.`
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

function makeFeed(items, sources = [], options = {}) {
  const now = new Date().toUTCString();

  const sourceByNameForQuality = new Map(
    sources.map(source => [source.name, source])
  );

  items = items.filter(item => {
    if (item.historicalBackfill === true) return false;
    const source = sourceByNameForQuality.get(item.source);
    if (!source) return true;
    return passesQualityGate(
      {
        title: item.title,
        link: item.link,
        pageDate: item.pageDate,
        date: item.pageDate
      },
      source
    );
  });
  const channelTitle = options.title || 'OM News Watcher';
  const channelDescription = options.description || 'Neue Meldungen aus beobachteten Websites für onlinemarktplatz.de';

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

    const itemGroups = Array.isArray(item.groups) ? item.groups : [];
    const itemTags = Array.isArray(item.tags) ? item.tags : [];
    if (itemGroups.length) meta.push(`Thema: ${itemGroups.join(', ')}`);
    if (itemTags.length) meta.push(`Tags: ${itemTags.join(', ')}`);
    if (Number(item.priority || 0) > 0) meta.push(`Relevanz: ${'★'.repeat(Math.max(1, Math.min(3, Number(item.priority))))}`);
    if (Array.isArray(item.duplicateSources) && item.duplicateSources.length) meta.push(`Auch gefunden bei: ${item.duplicateSources.join(', ')}`);

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
      <pubDate>${escXml(
        new Date(
          item.publishedAt ||
          publicationISOFromPageDate(item.pageDate || '') ||
          item.detectedAt
        ).toUTCString()
      )}</pubDate>
      <description>${escXml(meta.join(' · '))}</description>
      <source>${escXml(label)}</source>
    </item>`;
  }).join('');

  return `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>${escXml(channelTitle)}</title>
    <link>https://github.com/</link>
    <description>${escXml(channelDescription)}</description>
    <language>de-de</language>
    <lastBuildDate>${now}</lastBuildDate>
    ${body}
  </channel>
</rss>
`;
}


function cacheBustedUrl(rawUrl, source = {}) {
  if (source.cacheBust === false) return rawUrl;

  try {
    const url = new URL(rawUrl);
    url.searchParams.set(
      '_omw_fresh',
      `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
    );
    return url.toString();
  } catch {
    return rawUrl;
  }
}

function isRootPage(rawUrl) {
  try {
    const url = new URL(rawUrl);
    return !url.pathname || url.pathname === '/';
  } catch {
    return false;
  }
}

async function fetchTextFresh(rawUrl, options = {}) {
  const controller = new AbortController();
  const timeoutMs = Math.max(2000, Number(options.timeoutMs || 10000));
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetch(
      options.cacheBust === false
        ? rawUrl
        : cacheBustedUrl(rawUrl, { cacheBust: true }),
      {
        redirect: 'follow',
        signal: controller.signal,
        headers: {
          'user-agent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ' +
            `AppleWebKit/537.36 Chrome/140 Safari/537.36 OM-News-Watcher/${VERSION}`,
          'accept':
            options.accept ||
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'accept-language':
            'de-DE,de;q=0.9,en;q=0.7',
          'cache-control':
            'no-cache, no-store, max-age=0',
          'pragma':
            'no-cache'
        }
      }
    );

    if (!response.ok) {
      throw new Error(`HTTP ${response.status} ${response.statusText}`);
    }

    return {
      text: await response.text(),
      finalUrl: response.url,
      contentType: response.headers.get('content-type') || ''
    };
  } finally {
    clearTimeout(timer);
  }
}

async function discoverFeedUrls(page, source) {
  const candidates = [];

  try {
    const discovered = await page.locator(
      'link[rel="alternate"][type*="rss"], ' +
      'link[rel="alternate"][type*="atom"], ' +
      'link[rel="alternate"][type*="xml"]'
    ).evaluateAll(nodes =>
      nodes
        .map(node => node.href || '')
        .filter(Boolean)
    );

    candidates.push(...discovered);
  } catch {}

  // Bei Startseiten zusätzlich den verbreiteten WordPress-Endpunkt testen.
  if (isRootPage(source.url)) {
    try {
      const base = new URL(source.url);
      candidates.push(
        new URL('/feed/', base.origin).toString()
      );
    } catch {}
  }

  return [...new Set(candidates)].slice(0, 4);
}

async function fetchDiscoveredFeedRows(page, source, notes) {
  const allowed =
    source.discoverFeed !== false &&
    (
      source.discoverFeed === true ||
      isRootPage(source.url)
    );

  if (!allowed) return [];

  const urls = await discoverFeedUrls(page, source);

  for (const feedUrl of urls) {
    try {
      const result = await fetchTextFresh(feedUrl, {
        timeoutMs: 9000,
        accept:
          'application/rss+xml,application/atom+xml,application/xml,text/xml,*/*'
      });

      if (!/<(?:rss|feed|rdf:RDF)\b/i.test(result.text || '')) {
        continue;
      }

      const rows = normalizeAndFilter(
        feedRowsFromXml(result.text),
        source
      );

      if (rows.length) {
        notes.push(
          `RSS/Atom-Zweitkanal: ${rows.length} Einträge über ${feedUrl}`
        );
        return rows;
      }
    } catch {
      // Zweitkanal ist optional und darf die Hauptprüfung nie stoppen.
    }
  }

  return [];
}

async function createContext(browser) {
  return await browser.newContext({
    locale: 'de-DE',
    timezoneId: 'Europe/Berlin',
    serviceWorkers: 'block',

    extraHTTPHeaders: {
      'Cache-Control': 'no-cache, no-store, max-age=0',
      'Pragma': 'no-cache'
    },

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
    const navigationUrl =
      cacheBustedUrl(source.url, source);

    if (navigationUrl !== source.url) {
      notes.push('Frischer Abruf mit Cache-Busting.');
    }

    await page.goto(navigationUrl, {
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
        await page.goto(
          cacheBustedUrl(source.url, source),
          {
            waitUntil: 'domcontentloaded',
            timeout: FALLBACK_TIMEOUT_MS
          }
        );

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

function feedRowsFromXml(xml = '') {
  const rows = [];
  const blocks = String(xml).match(/<(?:item|entry)\b[^>]*>[\s\S]*?<\/(?:item|entry)>/gi) || [];
  const pick = (block, re) => decodeHtmlEntities((block.match(re)?.[1] || '').replace(/<!\[CDATA\[|\]\]>/g, '')).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
  for (const block of blocks) {
    const title = pick(block, /<title\b[^>]*>([\s\S]*?)<\/title>/i);
    let href = block.match(/<link\b[^>]*href=["']([^"']+)["'][^>]*\/?\s*>/i)?.[1] || '';
    if (!href) href = pick(block, /<link\b[^>]*>([\s\S]*?)<\/link>/i);
    const date = pick(block, /<(?:pubDate|published|updated)\b[^>]*>([\s\S]*?)<\/(?:pubDate|published|updated)>/i);
    if (title && href) rows.push({ title, href, date });
  }
  return rows;
}

async function inspectSourceViaFeed(source, index, total) {
  const started = Date.now();
  console.log(`[${index + 1}/${total}] Start FEED: ${source.name}`);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15000);
  try {
    const fresh = await fetchTextFresh(source.url, {
      timeoutMs: 15000,
      accept:
        'application/rss+xml,application/atom+xml,application/xml,text/xml,*/*'
    });
    const xml = fresh.text;
    const rows = normalizeAndFilter(feedRowsFromXml(xml), { ...source, includeRegex: source.includeRegex || null });
    return { source, rows, notes: [`Direkter RSS/Atom-Abruf: ${rows.length} Einträge`], durationMs: Date.now() - started, error: null };
  } catch (err) {
    return { source, rows: [], notes: [], durationMs: Date.now() - started, error: err };
  } finally {
    clearTimeout(timer);
    console.log(`[${index + 1}/${total}] Ende FEED: ${source.name} (${((Date.now() - started) / 1000).toFixed(1)}s)`);
  }
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
    const fresh = await fetchTextFresh(source.url, {
      timeoutMs,
      accept:
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    });

    const html = fresh.text;
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

    // Bei Startseiten zusätzlich einen unabhängigen RSS-/Atom-Kanal nutzen.
    // Feed-Treffer stehen bewusst zuerst, weil sie häufig aktueller sind
    // als eine gecachte gerenderte Homepage.
    const feedRows =
      await fetchDiscoveredFeedRows(
        page,
        source,
        notes
      );

    if (feedRows.length) {
      const byLink = new Map();

      for (const row of [...feedRows, ...rows]) {
        if (!row?.link) continue;
        if (!byLink.has(row.link)) {
          byLink.set(row.link, row);
        }
      }

      rows = [...byLink.values()];
    }

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

function intervalMinutesFor(source) {
  const raw = Number(source.checkIntervalMinutes ?? 30);
  if (!Number.isFinite(raw)) return 30;
  return Math.max(30, Math.min(10080, Math.round(raw)));
}

function berlinWeekday(date = new Date()) {
  return new Intl.DateTimeFormat('en-US', {
    timeZone: 'Europe/Berlin',
    weekday: 'short'
  }).format(date);
}

function scheduledRunIsDue(source, state, now = new Date()) {
  // "Jetzt prüfen" / manueller workflow_dispatch ignoriert absichtlich Intervalle.
  if (process.env.GITHUB_EVENT_NAME === 'workflow_dispatch') {
    return true;
  }

  if (source.weekdaysOnly === true) {
    const weekday = berlinWeekday(now);
    if (weekday === 'Sat' || weekday === 'Sun') {
      return false;
    }
  }

  const lastRaw = state.lastCheckedAtBySource?.[source.name];
  if (!lastRaw) return true;

  const last = Date.parse(lastRaw);
  if (!Number.isFinite(last)) return true;

  const elapsedMinutes = (now.getTime() - last) / 60000;
  return elapsedMinutes >= intervalMinutesFor(source) - 1;
}

function nextCheckAtFor(source, state, now = new Date()) {
  if (source.enabled === false) return null;

  const minutes = intervalMinutesFor(source);
  const lastRaw = state.lastCheckedAtBySource?.[source.name];
  const parsed = Date.parse(lastRaw || '');
  const base = Number.isFinite(parsed)
    ? new Date(parsed)
    : now;

  let next = new Date(base.getTime() + minutes * 60000);

  if (source.weekdaysOnly === true) {
    for (let guard = 0; guard < 8; guard++) {
      const weekday = berlinWeekday(next);
      if (weekday !== 'Sat' && weekday !== 'Sun') break;
      next = new Date(next.getTime() + 24 * 60 * 60000);
    }
  }

  return next.toISOString();
}

function median(values) {
  const prepared = values
    .map(Number)
    .filter(Number.isFinite)
    .sort((a, b) => a - b);

  if (!prepared.length) return 0;

  const middle = Math.floor(prepared.length / 2);
  return prepared.length % 2
    ? prepared[middle]
    : (prepared[middle - 1] + prepared[middle]) / 2;
}

function berlinDateKey(date = new Date()) {
  try {
    return new Intl.DateTimeFormat(
      'sv-SE',
      {
        timeZone: 'Europe/Berlin',
        year: 'numeric',
        month: '2-digit',
        day: '2-digit'
      }
    ).format(date);
  } catch {
    return date.toISOString().slice(0, 10);
  }
}

function hitCountAnomaly(current, previous) {
  const history = (previous || [])
    .map(Number)
    .filter(Number.isFinite)
    .slice(0, 12);

  if (history.length < 3) return null;

  const normal = median(history);
  if (normal <= 0) return null;

  if (current === 0) {
    return `0 Treffer; zuletzt typischerweise ${Math.round(normal)}`;
  }

  if (current >= Math.max(20, normal * 2.5)) {
    return `${current} Treffer; deutlich über dem üblichen Niveau ${Math.round(normal)}`;
  }

  if (normal >= 8 && current <= normal * 0.2) {
    return `${current} Treffer; deutlich unter dem üblichen Niveau ${Math.round(normal)}`;
  }

  return null;
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
  );

  const enabledSources = configuredSources.filter(
    s => s.enabled !== false
  );

  const state = readJson(
    STATE_FILE,
    {
      seenBySource: {},
      initializedBySource: {},
      configVersionBySource: {},
      globalBaselineBySource: {},
      feedResetToken: null,
      lastCheckedAtBySource: {},
      lastSuccessAtBySource: {},
      lastNewAtBySource: {},
      lastHitCountBySource: {},
      recentHitCountsBySource: {},
      lastDurationMsBySource: {},
      lastMessageBySource: {},
      anomalyBySource: {},
      deliveredBySource: {},
      baselineSuppressedBySource: {},
      explicitBaselineVersionBySource: {},
      lastDetectedBySource: {},
      lastStoredBySource: {},
      trackingWarningBySource: {},
      healedCountBySource: {},
      healedTodayBySource: {},
      lastEligibleHitCountBySource: {},
      lastRejectedHitCountBySource: {},
      suppressedByBaselineCountBySource: {},
      baselineSuppressedAtBySource: {},
      trackingSchemaVersion: 0
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

  state.lastCheckedAtBySource =
    state.lastCheckedAtBySource || {};

  state.lastSuccessAtBySource =
    state.lastSuccessAtBySource || {};

  state.lastNewAtBySource =
    state.lastNewAtBySource || {};

  state.lastHitCountBySource =
    state.lastHitCountBySource || {};

  state.recentHitCountsBySource =
    state.recentHitCountsBySource || {};

  state.lastDurationMsBySource =
    state.lastDurationMsBySource || {};

  state.lastMessageBySource =
    state.lastMessageBySource || {};

  state.anomalyBySource =
    state.anomalyBySource || {};

  state.deliveredBySource =
    state.deliveredBySource || {};

  state.baselineSuppressedBySource =
    state.baselineSuppressedBySource || {};

  state.explicitBaselineVersionBySource =
    state.explicitBaselineVersionBySource || {};

  state.lastDetectedBySource =
    state.lastDetectedBySource || {};

  state.lastStoredBySource =
    state.lastStoredBySource || {};

  state.trackingWarningBySource =
    state.trackingWarningBySource || {};

  state.healedCountBySource =
    state.healedCountBySource || {};

  state.healedTodayBySource =
    state.healedTodayBySource || {};

  state.lastEligibleHitCountBySource =
    state.lastEligibleHitCountBySource || {};

  state.lastRejectedHitCountBySource =
    state.lastRejectedHitCountBySource || {};

  state.suppressedByBaselineCountBySource =
    state.suppressedByBaselineCountBySource || {};

  state.baselineSuppressedAtBySource =
    state.baselineSuppressedAtBySource || {};

  const trackingMigrationMode =
    Number(state.trackingSchemaVersion || 0) < TRACKING_SCHEMA_VERSION;

  const runStartedAt = new Date();

  const sources = enabledSources.filter(
    source => scheduledRunIsDue(source, state, runStartedAt)
  );

  const intervalSkippedSources = enabledSources.filter(
    source => !sources.includes(source)
  );

  console.log(
    `Prüfplan: ${sources.length} fällig · ${intervalSkippedSources.length} intervallbedingt übersprungen · ${configuredSources.length - enabledSources.length} pausiert`
  );

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
    enabledSources
  );

  // v0.23: Publikations- und Auslieferungszeit strikt trennen.
  // Bereits durch v0.22 fälschlich als "neu" eingespielte Altartikel
  // bleiben für "Alle Meldungen" nachvollziehbar, werden aber als
  // historischer Backfill markiert und nicht mehr als aktuelle Meldung
  // behandelt.
  items = items.map(item => {
    const publishedAt =
      item.publishedAt ||
      publicationISOFromPageDate(item.pageDate || '');

    const deliveredAt =
      item.deliveredAt ||
      item.detectedAt ||
      null;

    const normalized = {
      ...item,
      publishedAt,
      deliveredAt
    };

    return {
      ...normalized,
      historicalBackfill:
        isHistoricalBackfill(normalized)
    };
  });

  // Migration v0.22:
  // "gesehen" und "ausgeliefert" sind ab jetzt getrennte Zustände.
  // Bereits gespeicherte Reader-Meldungen gelten selbstverständlich als
  // ausgeliefert und werden in deliveredBySource nachgezogen.
  const storedLinksBySource = new Map();

  // Audit-Felder ausschließlich aus dem bereinigten items.json neu aufbauen.
  // So verschwinden alte CSS-/Navigations-Artefakte auch aus "Neuester
  // gespeicherter Artikel" im Gesundheitsdashboard.
  state.lastStoredBySource = {};

  for (const item of items) {
    if (!item?.source || !item?.link) continue;

    state.deliveredBySource[item.source] =
      appendUniqueLimited(
        state.deliveredBySource[item.source] || [],
        [item.link],
        MAX_DELIVERED_PER_SOURCE
      );

    if (!storedLinksBySource.has(item.source)) {
      storedLinksBySource.set(item.source, new Set());
    }
    storedLinksBySource.get(item.source).add(item.link);

    for (const duplicateSource of item.duplicateSources || []) {
      if (!storedLinksBySource.has(duplicateSource)) {
        storedLinksBySource.set(duplicateSource, new Set());
      }
      storedLinksBySource.get(duplicateSource).add(item.link);
    }

    const existingStored = state.lastStoredBySource[item.source];
    const existingTime = Date.parse(
      String(existingStored?.deliveredAt || existingStored?.detectedAt || '')
    );
    const itemTime = Date.parse(
      String(item.deliveredAt || item.detectedAt || '')
    );

    if (
      !existingStored ||
      !Number.isFinite(existingTime) ||
      (Number.isFinite(itemTime) && itemTime > existingTime)
    ) {
      state.lastStoredBySource[item.source] = {
        title: item.title || '',
        link: item.link || '',
        pageDate: item.pageDate || null,
        publishedAt: item.publishedAt || null,
        detectedAt: item.detectedAt || null,
        deliveredAt: item.deliveredAt || item.detectedAt || null,
        recovered: item.recovered === true
      };
    }
  }

  let results = [];

  if (!sources.length) {
    console.log(
      enabledSources.length
        ? 'Aktuell ist wegen der Prüfintervalle keine Quelle fällig.'
        : 'Keine Quellen aktiviert.'
    );
  } else {
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

    results = await mapWithConcurrency(
      sources,
      SOURCE_CONCURRENCY,
      (source, index) =>
        source.fetchMode === 'feed'
          ? inspectSourceViaFeed(source, index, sources.length)
          : source.fetchMode === 'html'
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
  }

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

    const healthKey = source.name;
    const checkedAt = new Date().toISOString();
    state.lastCheckedAtBySource[healthKey] = checkedAt;
    state.lastDurationMsBySource[healthKey] = Math.round(result.durationMs || 0);

    if (result.error) {
      state.lastMessageBySource[healthKey] = result.error.message;
      state.anomalyBySource[healthKey] =
        `Abruf fehlgeschlagen: ${result.error.message}`;
      console.log(
        `  FEHLER: ${result.error.message}`
      );

      continue;
    }

    const rows =
      result.rows;

    const key =
      source.name;

    const previousHitCounts =
      state.recentHitCountsBySource[key] || [];

    state.lastHitCountBySource[key] = rows.length;
    state.recentHitCountsBySource[key] = [
      rows.length,
      ...previousHitCounts
    ].slice(0, 12);

    const eligibleHealthRows =
      rows.filter(
        row =>
          deliveryEligibility(
            row,
            source,
            checkedAt
          ).eligible
      );

    state.lastEligibleHitCountBySource[key] =
      eligibleHealthRows.length;

    state.lastRejectedHitCountBySource[key] =
      Math.max(
        0,
        rows.length - eligibleHealthRows.length
      );

    state.lastMessageBySource[key] =
      rows.length > 0
        ? `${rows.length} technisch erkannt · ${eligibleHealthRows.length} Reader-fähig`
        : 'Technischer Abruf erfolgreich · keine passenden Artikel';

    const anomaly = hitCountAnomaly(
      rows.length,
      previousHitCounts
    );

    if (anomaly) {
      state.anomalyBySource[key] = anomaly;
    } else {
      delete state.anomalyBySource[key];
    }

    // "Letzter Erfolg" bedeutet ab v0.27: Quelle konnte erfolgreich
    // geladen und ausgewertet werden – auch wenn aktuell keine Meldung
    // Reader-fähig ist.
    state.lastSuccessAtBySource[key] = checkedAt;

    const hadPriorState =
      Object.prototype.hasOwnProperty.call(
        state.seenBySource,
        key
      );

    // baselineVersion bleibt die Versionskennung der Erkennungsregel,
    // löst aber ab v0.22 KEINEN automatischen Baseline-Reset mehr aus.
    const requestedBaseline =
      String(source.baselineVersion || '');

    const storedBaseline =
      String(state.configVersionBySource[key] || '');

    const configChanged =
      requestedBaseline &&
      requestedBaseline !== storedBaseline;

    // Ein neuer Baseline-Lauf darf künftig nur noch bewusst angefordert
    // werden. Neue Quellen benötigen weiterhin ihren unvermeidbaren
    // einmaligen Start-Baseline.
    const explicitBaselineRequest =
      String(source.baselineRequestedVersion || '');

    const storedExplicitBaseline =
      String(state.explicitBaselineVersionBySource[key] || '');

    const explicitBaselineChanged =
      explicitBaselineRequest &&
      explicitBaselineRequest !== storedExplicitBaseline;

    const needsGlobalBaseline =
      state.globalBaselineBySource[key] !==
      GLOBAL_BASELINE_TOKEN;

    const firstRun =
      needsGlobalBaseline ||
      explicitBaselineChanged ||
      (
        state.initializedBySource[key] !== true &&
        !hadPriorState
      );

    const known =
      new Set(
        firstRun
          ? []
          : (state.seenBySource[key] || [])
      );

    const delivered =
      new Set(
        state.deliveredBySource[key] || []
      );

    const baselineSuppressed =
      new Set(
        state.baselineSuppressedBySource[key] || []
      );

    const baselineSuppressedAt =
      state.baselineSuppressedAtBySource[key] || {};

    const storedLinks =
      storedLinksBySource.get(key) || new Set();

    const isExplicitCurrentBaselineSuppression = link =>
      Boolean(baselineSuppressedAt[link]);

    if (needsGlobalBaseline) {
      console.log(
        `  ↻ Sauberer Gesamt-Ausgangspunkt (${GLOBAL_BASELINE_TOKEN}) – Quelle wird einmalig neu baseline-gesetzt.`
      );
    }

    if (explicitBaselineChanged) {
      console.log(
        `  ↻ Explizit angeforderter Baseline-Lauf (${explicitBaselineRequest}).`
      );
    }

    if (configChanged && !firstRun) {
      console.log(
        `  ↻ Neue Erkennungsregel (${requestedBaseline}) – bestehender Tracking-Stand bleibt erhalten.`
      );
    }

    if (rows.length === 0) {
      console.log(
        state.anomalyBySource[key]
          ? `  ⚠ ${state.anomalyBySource[key]}`
          : '  ℹ Keine aktuell passenden Artikel – technischer Abruf war erfolgreich.'
      );

      state.initializedBySource[key] =
        true;

      if (!hadPriorState) {
        state.seenBySource[key] =
          [];
      }

      if (requestedBaseline) {
        state.configVersionBySource[key] = requestedBaseline;
      }

      if (explicitBaselineRequest) {
        state.explicitBaselineVersionBySource[key] =
          explicitBaselineRequest;
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

    state.lastDetectedBySource[key] =
      compactAuditRow(rows[0]);

    // items.json ist ab v0.23 die letzte Wahrheit:
    // Nur was dort tatsächlich gespeichert ist, gilt als ausgeliefert.
    const fresh =
      rows.filter(
        r =>
          !known.has(r.link) &&
          !storedLinks.has(r.link)
      );

    // Aktuelle Meldung auf der Website, aber NICHT in items.json:
    // unabhängig davon, ob alte seen/delivered-Zustände den Link bereits
    // fälschlich kennen. Genau damit wird der Wortfilter-Fall repariert.
    //
    // Nur eine Baseline-Unterdrückung, die ab v0.23 mit Zeitstempel
    // ausdrücklich protokolliert wurde, darf diese Heilung blockieren.
    // Alte/legacy baselineSuppressed-Listen gelten nicht mehr als Beweis,
    // dass eine aktuelle Meldung absichtlich unterdrückt werden sollte.
    const recoverable =
      firstRun
        ? []
        : rows.filter(
            r =>
              !storedLinks.has(r.link) &&
              deliveryEligibility(r, source, checkedAt).eligible &&
              Number.isFinite(pageDateTimestamp(r.date || '')) &&
              !isExplicitCurrentBaselineSuppression(r.link)
          );

    // Beim ersten v0.23-Migrationslauf oder direkt nach einem Regelwechsel
    // dürfen neu sichtbar gewordene Archivlinks nicht als aktuelle News
    // ausgespielt werden. Verlässlich aktuelle Publikationsdaten bleiben
    // dagegen zulässig.
    const conservativeFreshMode =
      trackingMigrationMode || configChanged;

    const firstPreviouslyKnownIndex =
      rows.findIndex(
        r => known.has(r.link) || storedLinks.has(r.link)
      );

    const freshEligibilityReason = new Map();

    const freshEligible =
      fresh.filter(r => {
        const decision =
          deliveryEligibility(r, source, checkedAt);

        if (!decision.eligible) {
          freshEligibilityReason.set(r.link, decision.reason);
          return false;
        }

        const hasReliableDate =
          Number.isFinite(pageDateTimestamp(r.date || ''));

        // Ein aktuelles belastbares Veröffentlichungsdatum ist unabhängig
        // von Migrationen/Regelwechseln ausreichend.
        if (hasReliableDate) return true;

        if (!conservativeFreshMode) return true;

        // Ohne Publikationsdatum nur Links akzeptieren, die auf einer
        // bereits bekannten chronologischen Liste VOR dem ersten bekannten
        // Artikel auftauchen. Das verhindert historische Archiv-Sweeps.
        const rowIndex =
          rows.findIndex(candidate => candidate.link === r.link);

        if (
          firstPreviouslyKnownIndex > 0 &&
          rowIndex >= 0 &&
          rowIndex < firstPreviouslyKnownIndex
        ) {
          return true;
        }

        freshEligibilityReason.set(
          r.link,
          'undated-not-proven-new-during-migration'
        );
        return false;
      });

    const suppressedFresh =
      fresh.filter(
        r => !freshEligible.some(candidate => candidate.link === r.link)
      );

    if (suppressedFresh.length) {
      const reasonCounts = {};
      for (const row of suppressedFresh) {
        const reason = freshEligibilityReason.get(row.link) || 'not-current';
        reasonCounts[reason] = Number(reasonCounts[reason] || 0) + 1;
      }
      console.log(
        '  News-Eligibility verworfen: ' +
        Object.entries(reasonCounts)
          .map(([reason, count]) => `${count}× ${reason}`)
          .join(', ')
      );
    }

    if (firstRun) {
      const suppressedLinks = rows.map(r => r.link);

      state.baselineSuppressedBySource[key] =
        appendUniqueLimited(
          state.baselineSuppressedBySource[key] || [],
          suppressedLinks,
          MAX_BASELINE_SUPPRESSED_PER_SOURCE
        );

      const suppressionTimes = {
        ...(state.baselineSuppressedAtBySource[key] || {})
      };
      for (const link of suppressedLinks) {
        suppressionTimes[link] = checkedAt;
      }
      state.baselineSuppressedAtBySource[key] = suppressionTimes;

      state.suppressedByBaselineCountBySource[key] =
        Number(state.suppressedByBaselineCountBySource[key] || 0) +
        suppressedLinks.length;

      state.trackingWarningBySource[key] = null;

      console.log(
        `  Erster/Baseline-Lauf: ${rows.length} bestehende Links als bekannt gespeichert, keine Altmeldungen ausgegeben.`
      );

    } else if (
      suspiciousSpike(
        known.size,
        freshEligible.length,
        source
      )
    ) {
      state.trackingWarningBySource[key] =
        `Verdächtiger Sprung: ${fresh.length} neue Links wurden noch nicht ausgeliefert`;

      console.log(
        `  ⚠ VERDÄCHTIGER SPRUNG: ${rows.length} Artikel erkannt, ${fresh.length} neu. ` +
        'Neue Links werden vorsichtshalber NICHT in den Feed übernommen.'
      );

      // Wichtig: diese neuen Links absichtlich NICHT in seenBySource
      // übernehmen. So werden sie beim nächsten Lauf erneut geprüft.
      continue;

    } else {
      const toDeliverMap = new Map();

      for (const r of freshEligible) {
        toDeliverMap.set(r.link, {
          row: r,
          recovered: false
        });
      }

      for (const r of recoverable) {
        if (!toDeliverMap.has(r.link)) {
          toDeliverMap.set(r.link, {
            row: r,
            recovered: true
          });
        }
      }

      const toDeliver = [...toDeliverMap.values()];
      const healedThisRun =
        toDeliver.filter(entry => entry.recovered).length;

      console.log(
        `  ${rows.length} Artikel erkannt, ${freshEligible.length} neu` +
        (suppressedFresh.length
          ? `, ${suppressedFresh.length} historische/unklare neue Links nicht als aktuell eingestuft`
          : '') +
        (healedThisRun
          ? `, ${healedThisRun} fehlende aktuelle Meldung(en) aus items.json nachgeholt.`
          : '.')
      );

      if (toDeliver.length > 0) {
        state.lastNewAtBySource[key] = checkedAt;
      }

      for (const entry of toDeliver) {
        const r = entry.row;

        const nowISO =
          new Date().toISOString();

        const publishedAt =
          publicationISOFromPageDate(r.date || '');

        const storedItem = {
          guid:
            idFor(r.link),

          source:
            source.name,

          sourceLabel:
            sourceFeedLabel(source),

          groups:
            Array.isArray(source.groups) ? source.groups : [],

          tags:
            Array.isArray(source.tags) ? source.tags : [],

          priority:
            Math.max(1, Math.min(3, Number(source.priority || 2))),

          title:
            r.title,

          link:
            r.link,

          pageDate:
            r.date ||
            null,

          publishedAt,

          // detectedAt = Zeitpunkt, zu dem dieser Watcher die Meldung
          // erstmals als auszuliefernden Artikel erkannt hat.
          detectedAt:
            nowISO,

          // deliveredAt wird getrennt geführt, damit spätere
          // Selbstheilungen nicht mit dem Veröffentlichungsdatum
          // verwechselt werden.
          deliveredAt:
            nowISO,

          recovered:
            entry.recovered === true,

          historicalBackfill:
            false,

          recoveryReason:
            entry.recovered
              ? 'seen-but-never-delivered-within-48h'
              : null
        };

        items.unshift(storedItem);
        delivered.add(r.link);
        storedLinks.add(r.link);

        if (!storedLinksBySource.has(key)) {
          storedLinksBySource.set(key, storedLinks);
        }

        state.lastStoredBySource[key] = {
          title: r.title || '',
          link: r.link || '',
          pageDate: r.date || null,
          publishedAt: storedItem.publishedAt || null,
          detectedAt: storedItem.detectedAt,
          deliveredAt: storedItem.deliveredAt,
          recovered: entry.recovered === true
        };
      }

      if (healedThisRun > 0) {
        state.healedCountBySource[key] =
          Number(state.healedCountBySource[key] || 0) +
          healedThisRun;

        const todayKey =
          berlinDateKey(new Date());

        const currentToday =
          state.healedTodayBySource[key] || {};

        state.healedTodayBySource[key] = {
          date: todayKey,
          count:
            currentToday.date === todayKey
              ? Number(currentToday.count || 0) + healedThisRun
              : healedThisRun
        };

        console.log(
          `  🩹 TRACKING-REPARATUR: ${healedThisRun} Meldung(en) waren gesehen, aber nie ausgeliefert.`
        );
      }

      state.deliveredBySource[key] =
        appendUniqueLimited(
          state.deliveredBySource[key] || [],
          [...delivered],
          MAX_DELIVERED_PER_SOURCE
        );
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

    // Tracking-Audit nach der Verarbeitung:
    // items.json / storedLinks ist die Wahrheit, NICHT deliveredBySource.
    const unresolvedRecent =
      firstRun
        ? []
        : rows.filter(
            r =>
              !storedLinks.has(r.link) &&
              rowIsRecent(r, checkedAt) &&
              !isExplicitCurrentBaselineSuppression(r.link)
          );

    if (unresolvedRecent.length > 0) {
      state.trackingWarningBySource[key] =
        `${unresolvedRecent.length} aktuelle Meldung(en) erkannt, aber nicht ausgeliefert`;
    } else {
      delete state.trackingWarningBySource[key];
    }

    state.initializedBySource[key] =
      true;

    if (requestedBaseline) {
      state.configVersionBySource[key] = requestedBaseline;
    }

    if (explicitBaselineRequest) {
      state.explicitBaselineVersionBySource[key] =
        explicitBaselineRequest;
    }

    state.globalBaselineBySource[key] =
      GLOBAL_BASELINE_TOKEN;
  }

  // Organisationsdaten alter Feed-Einträge an die aktuelle Quellenkonfiguration anpassen.
  const sourceByName = new Map(configuredSources.map(source => [source.name, source]));
  items = items.map(item => {
    const source = sourceByName.get(item.source);
    if (!source) return item;
    return {
      ...item,
      sourceLabel: sourceFeedLabel(source),
      groups: Array.isArray(source.groups) ? source.groups : [],
      tags: Array.isArray(source.tags) ? source.tags : [],
      priority: Math.max(1, Math.min(3, Number(source.priority || 2)))
    };
  });

  // Doppelte Meldungen aus mehreren Quellen im Feed zusammenführen.
  const deduped = [];
  const byGuid = new Map();
  const byTitle = new Map();
  const normalizedKey = value => String(value || '').toLowerCase().replace(/[^a-z0-9äöüß]+/gi, ' ').replace(/\s+/g, ' ').trim();

  const sortedItems = [...items].sort((a, b) => {
    const timeDiff = Date.parse(b.detectedAt || 0) - Date.parse(a.detectedAt || 0);
    if (timeDiff !== 0) return timeDiff;
    return Number(b.priority || 2) - Number(a.priority || 2);
  });

  for (const item of sortedItems) {
    if (!item?.guid) continue;
    const titleKey = normalizedKey(item.title);
    let existing = byGuid.get(item.guid);
    if (!existing && titleKey.length >= 25) existing = byTitle.get(titleKey);
    if (existing) {
      existing.duplicateSources = [...new Set([...(existing.duplicateSources || []), item.source].filter(x => x && x !== existing.source))];
      existing.groups = [...new Set([...(existing.groups || []), ...(item.groups || [])])];
      existing.tags = [...new Set([...(existing.tags || []), ...(item.tags || [])])];
      existing.priority = Math.max(Number(existing.priority || 2), Number(item.priority || 2));
      continue;
    }
    deduped.push(item);
    byGuid.set(item.guid, item);
    if (titleKey.length >= 25) byTitle.set(titleKey, item);
  }

  items = deduped.slice(0, MAX_FEED_ITEMS);

  const healthRows = configuredSources.map(source => {
    const key = source.name;
    const recent = state.recentHitCountsBySource[key] || [];

    const average = recent.length
      ? recent.reduce(
          (sum, value) => sum + Number(value || 0),
          0
        ) / recent.length
      : null;

    const isEnabled = source.enabled !== false;
    const skipped =
      isEnabled &&
      !sources.includes(source);

    const technicalHitCount =
      Object.prototype.hasOwnProperty.call(
        state.lastHitCountBySource,
        key
      )
        ? Number(state.lastHitCountBySource[key])
        : null;

    const eligibleHitCount =
      Object.prototype.hasOwnProperty.call(
        state.lastEligibleHitCountBySource,
        key
      )
        ? Number(state.lastEligibleHitCountBySource[key])
        : null;

    const rejectedHitCount =
      Object.prototype.hasOwnProperty.call(
        state.lastRejectedHitCountBySource,
        key
      )
        ? Number(state.lastRejectedHitCountBySource[key])
        : (
            technicalHitCount != null &&
            eligibleHitCount != null
              ? Math.max(
                  0,
                  technicalHitCount - eligibleHitCount
                )
              : null
          );

    const anomalyText =
      state.anomalyBySource[key] || null;

    const trackingWarning =
      state.trackingWarningBySource[key] || null;

    const technicalError =
      String(anomalyText || '').startsWith(
        'Abruf fehlgeschlagen:'
      );

    let healthStatus =
      'healthy';

    let healthSummary =
      'Quelle funktioniert';

    if (!isEnabled) {
      healthStatus = 'paused';
      healthSummary = 'Pausiert';
    } else if (skipped) {
      healthStatus = 'skipped';
      healthSummary = 'Intervallbedingt übersprungen';
    } else if (technicalError) {
      healthStatus = 'error';
      healthSummary =
        anomalyText || 'Technischer Fehler';
    } else if (trackingWarning) {
      healthStatus = 'anomaly';
      healthSummary = trackingWarning;
    } else if (anomalyText) {
      healthStatus = 'anomaly';
      healthSummary = anomalyText;
    } else if (
      eligibleHitCount === 0 ||
      (
        eligibleHitCount == null &&
        technicalHitCount === 0
      )
    ) {
      healthStatus = 'no-new';

      if (
        technicalHitCount != null &&
        technicalHitCount > 0
      ) {
        healthSummary =
          `${technicalHitCount} technisch erkannt, aktuell nichts Reader-fähig`;
      } else {
        healthSummary =
          'Technisch erreichbar, aktuell keine passende Meldung';
      }
    } else {
      healthStatus = 'healthy';
      healthSummary =
        eligibleHitCount != null
          ? `${eligibleHitCount} Reader-fähig`
          : 'Quelle funktioniert';
    }

    const todayKey =
      berlinDateKey(new Date());

    const todayRepairState =
      state.healedTodayBySource[key] || {};

    const healedTodayCount =
      todayRepairState.date === todayKey
        ? Number(todayRepairState.count || 0)
        : 0;

    return {
      source: source.name,
      sourceLabel: sourceFeedLabel(source),
      url: source.url,
      enabled: isEnabled,
      skipped,
      checkedAt: state.lastCheckedAtBySource[key] || null,
      lastSuccessAt: state.lastSuccessAtBySource[key] || null,
      lastNewAt: state.lastNewAtBySource[key] || null,

      // Backwards compatible legacy field.
      hitCount: technicalHitCount,
      averageHitCount: average,

      technicalHitCount,
      eligibleHitCount,
      rejectedHitCount,

      healthStatus,
      healthSummary,

      durationMs:
        Object.prototype.hasOwnProperty.call(
          state.lastDurationMsBySource,
          key
        )
          ? Number(state.lastDurationMsBySource[key])
          : null,

      anomaly: [
        anomalyText,
        trackingWarning
      ].filter(Boolean).join(' · ') || null,

      message: state.lastMessageBySource[key] || null,

      trackingStatus:
        trackingWarning
          ? 'warning'
          : Number(state.healedCountBySource[key] || 0) > 0
          ? 'healed'
          : 'ok',

      trackingWarning: trackingWarning,

      latestDetected: state.lastDetectedBySource[key] || null,
      latestStored: state.lastStoredBySource[key] || null,

      healedCount:
        Number(state.healedCountBySource[key] || 0),

      healedTodayCount,

      baselineSuppressedCount:
        Number(state.suppressedByBaselineCountBySource[key] || 0),

      undeliveredRecentCount:
        (() => {
          const warning = trackingWarning || '';
          const match =
            String(warning).match(
              /^(\d+)\s+aktuelle Meldung/
            );

          return match ? Number(match[1]) : 0;
        })(),

      nextCheckAt: isEnabled
        ? nextCheckAtFor(source, state, new Date())
        : null,

      checkIntervalMinutes: intervalMinutesFor(source),
      weekdaysOnly: source.weekdaysOnly === true
    };
  });

  state.trackingSchemaVersion =
    TRACKING_SCHEMA_VERSION;

  saveJson(HEALTH_FILE, {
    generatedAt: new Date().toISOString(),
    watcherVersion: VERSION,
    trackingSchemaVersion: TRACKING_SCHEMA_VERSION,
    sources: healthRows
  });

  saveJson(STATE_FILE, state);
  saveJson(ITEMS_FILE, items);

  fs.mkdirSync(path.dirname(FEED_FILE), { recursive: true });
  fs.writeFileSync(FEED_FILE, makeFeed(items, configuredSources));

  // Ein eigener RSS-Feed je Ordner/Themenbereich.
  fs.rmSync(GROUP_FEED_DIR, { recursive: true, force: true });
  fs.mkdirSync(GROUP_FEED_DIR, { recursive: true });

  const groups = [...new Set(configuredSources.flatMap(source => Array.isArray(source.groups) ? source.groups : []).filter(Boolean))]
    .sort((a, b) => String(a).localeCompare(String(b), 'de'));

  const slugify = value => String(value || '')
    .normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'thema';

  const groupIndex = [];
  for (const group of groups) {
    const slug = slugify(group);
    const groupItems = items.filter(item => Array.isArray(item.groups) && item.groups.some(g => String(g).toLowerCase() === String(group).toLowerCase()));
    const filename = `${slug}.xml`;
    fs.writeFileSync(path.join(GROUP_FEED_DIR, filename), makeFeed(groupItems, configuredSources, {
      title: `OM News Watcher · ${group}`,
      description: `Neue Meldungen aus dem Themenbereich ${group}`
    }));
    groupIndex.push({ group, slug, file: `feeds/${filename}`, count: groupItems.length });
  }
  saveJson(GROUP_FEED_INDEX, groupIndex);

  console.log(`\nRSS geschrieben: ${FEED_FILE} (${items.length} Einträge)`);
  console.log(`Themenfeeds geschrieben: ${groupIndex.length}`);
  console.log(`Gesundheitsdaten geschrieben: ${HEALTH_FILE} (${healthRows.length} Quellen)`);

})().catch(err => {
  console.error(err);
  process.exit(1);
});
