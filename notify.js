const fs = require('fs');
const path = require('path');
const nodemailer = require('nodemailer');

const ROOT = __dirname;
const SETTINGS_FILE = path.join(ROOT, 'email-settings.json');
const ITEMS_FILE = path.join(ROOT, 'data', 'items.json');
const SOURCES_FILE = path.join(ROOT, 'sources.json');
const STATE_FILE = path.join(ROOT, 'data', 'email-state.json');
const READER_STATE_FILE = path.join(ROOT, 'reader-state.json');

const FORCE = /^(1|true|yes)$/i.test(
  process.env.OM_NOTIFY_FORCE || ''
);

const DRY_RUN = /^(1|true|yes)$/i.test(
  process.env.OM_NOTIFY_DRY_RUN || ''
);

const CURRENT_WINDOW_HOURS = 48;
const FUTURE_TOLERANCE_HOURS = 24;
const MAX_HANDLED_GUIDS = 12000;

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

function saveJson(file, data) {
  fs.mkdirSync(path.dirname(file), {
    recursive: true
  });

  fs.writeFileSync(
    file,
    JSON.stringify(data, null, 2) + '\n'
  );
}

function escHtml(value = '') {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
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
    result = result.replace(pattern, '').trim();
  }

  return result || String(value || '').trim() || 'Quelle';
}

function normalizeTitle(value = '') {
  return String(value || '')
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim();
}

function normalizeUrl(value = '') {
  try {
    const url = new URL(value);
    url.search = '';
    url.hash = '';
    let result = url.toString().toLowerCase();
    while (result.endsWith('/')) {
      result = result.slice(0, -1);
    }
    return result;
  } catch {
    return String(value || '').toLowerCase().replace(/\/+$/, '');
  }
}

const GENERIC_EXACT = new Set([
  'main menu',
  'menu',
  'stories',
  'media kit',
  'financial reports',
  'media & resources',
  'media and resources',
  'mappe zum unternehmen',
  'unternehmensnews',
  'unternehmensmitteilungen',
  'newsroom',
  'press',
  'skip to main content',
  'events',
  'event',
  'paypal',
  'dokumentation zur fehlerbehebung',
  'aktualisieren sie diese seite',
  'update this page'
]);

const GENERIC_PREFIXES = [
  'read article',
  'read more',
  'learn more',
  'mehr erfahren',
  'weiterlesen',
  'weiter lesen',
  'download for free',
  'download',
  'alle akzeptieren',
  'accept all',
  'cookie',
  'privacy settings'
];

function titleTokens(value = '') {
  const stopwords = new Set([
    'der', 'die', 'das', 'den', 'dem', 'des', 'ein', 'eine',
    'und', 'oder', 'fur', 'mit', 'von', 'zu', 'im', 'in', 'auf',
    'the', 'a', 'an', 'and', 'or', 'for', 'with', 'of', 'to', 'on'
  ]);

  return new Set(
    normalizeTitle(value)
      .split(' ')
      .filter(token => token.length >= 3 && !stopwords.has(token))
  );
}

function titleSimilarity(lhs, rhs) {
  const a = titleTokens(lhs);
  const b = titleTokens(rhs);

  if (a.size < 4 || b.size < 4) {
    return 0;
  }

  let intersection = 0;
  for (const token of a) {
    if (b.has(token)) intersection += 1;
  }

  const union = new Set([...a, ...b]).size;
  return union ? intersection / union : 0;
}

function sourceHomepages(sources) {
  const map = new Map();

  for (const source of Array.isArray(sources) ? sources : []) {
    const homepage = normalizeUrl(source?.url || '');
    if (!homepage) continue;

    const names = [
      source?.name,
      source?.feedLabel,
      source?.feedTitle,
      source?.label
    ];

    for (const name of names) {
      if (name) {
        map.set(String(name).toLowerCase(), homepage);
      }
    }
  }

  return map;
}

/**
 * Gleiche Grundreinigung wie der integrierte Reader:
 * - generische Navigationstexte raus
 * - Homepage selbst raus
 * - doppelte Links raus
 * - doppelte Titel derselben Quelle raus
 * - sehr ähnliche Meldungen verschiedener Quellen zusammenfassen
 *
 * Rückgabe enthält auch die verworfenen GUIDs, damit sie nicht in jeder
 * späteren Sammelmail erneut geprüft werden.
 */
function cleanLikeReader(values, sources) {
  const homepages = sourceHomepages(sources);
  const sorted = [...(Array.isArray(values) ? values : [])]
    .sort((a, b) =>
      Date.parse(b?.detectedAt || 0) -
      Date.parse(a?.detectedAt || 0)
    );

  const seenLinks = new Set();
  const seenSourceTitles = new Set();
  const cleaned = [];
  const rejected = [];

  for (const item of sorted) {
    if (!item?.guid || !item?.title || !item?.link) {
      rejected.push({ item, reason: 'technisch/unvollständig' });
      continue;
    }

    const title = normalizeTitle(item.title);

    if (title.length < 5) {
      rejected.push({ item, reason: 'technisch/unpassend' });
      continue;
    }

    if (
      GENERIC_EXACT.has(title) ||
      GENERIC_PREFIXES.some(prefix =>
        title === prefix || title.startsWith(prefix + ' ')
      )
    ) {
      rejected.push({ item, reason: 'Navigation/Fehltreffer' });
      continue;
    }

    const link = normalizeUrl(item.link);
    const homepage =
      homepages.get(String(item.source || '').toLowerCase()) ||
      homepages.get(String(item.sourceLabel || '').toLowerCase());

    if (homepage && link === homepage) {
      rejected.push({ item, reason: 'Quellenseite statt Meldung' });
      continue;
    }

    if (seenLinks.has(link)) {
      rejected.push({ item, reason: 'Duplikat' });
      continue;
    }
    seenLinks.add(link);

    const sourceTitleKey =
      String(item.source || '').toLowerCase() + '|' + title;

    if (seenSourceTitles.has(sourceTitleKey)) {
      rejected.push({ item, reason: 'Duplikat' });
      continue;
    }
    seenSourceTitles.add(sourceTitleKey);

    if (title.length >= 24) {
      const duplicateIndex = cleaned
        .slice(0, 120)
        .findIndex(existing =>
          String(existing.source || '').toLowerCase() !==
            String(item.source || '').toLowerCase() &&
          titleSimilarity(existing.title, item.title) >= 0.86
        );

      if (duplicateIndex >= 0) {
        // Wie im Reader: Relevanz/Ordner des Duplikats auf den ersten
        // Treffer übertragen, aber nur eine Meldung anzeigen/mailen.
        const existing = cleaned[duplicateIndex];
        existing.priority = Math.max(
          Number(existing.priority || 2),
          Number(item.priority || 2)
        );
        existing.groups = [
          ...new Set([
            ...(existing.groups || []),
            ...(item.groups || [])
          ])
        ];
        existing.tags = [
          ...new Set([
            ...(existing.tags || []),
            ...(item.tags || [])
          ])
        ];

        rejected.push({ item, reason: 'Duplikat' });
        continue;
      }
    }

    cleaned.push({ ...item });
  }

  return { cleaned, rejected };
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

  const parsed = Date.parse(
    text.replace(/\bSept\./i, 'Sep')
  );

  return Number.isFinite(parsed) ? parsed : NaN;
}

function itemPublishedTimestamp(item) {
  const explicit = Date.parse(String(item?.publishedAt || ''));
  if (Number.isFinite(explicit)) return explicit;
  return pageDateTimestamp(item?.pageDate || '');
}

function isCurrentPublication(item, now = Date.now()) {
  if (item?.historicalBackfill === true) {
    return false;
  }

  const published = itemPublishedTimestamp(item);

  if (Number.isFinite(published)) {
    const lower =
      now - CURRENT_WINDOW_HOURS * 60 * 60 * 1000;
    const upper =
      now + FUTURE_TOLERANCE_HOURS * 60 * 60 * 1000;

    return published >= lower && published <= upper;
  }

  // Quellen ohne zuverlässiges Publikationsdatum dürfen wie im Reader
  // über ihren echten Erkennungszeitpunkt arbeiten.
  const detected = Date.parse(String(item?.detectedAt || ''));

  return (
    Number.isFinite(detected) &&
    detected >= now - CURRENT_WINDOW_HOURS * 60 * 60 * 1000 &&
    detected <= now + FUTURE_TOLERANCE_HOURS * 60 * 60 * 1000
  );
}

function localParts(timeZone) {
  const parts =
    new Intl.DateTimeFormat(
      'de-DE',
      {
        timeZone,
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        hourCycle: 'h23'
      }
    )
    .formatToParts(new Date());

  const values =
    Object.fromEntries(
      parts.map(p => [p.type, p.value])
    );

  return {
    date:
      `${values.year}-${values.month}-${values.day}`,
    hour:
      Number(values.hour)
  };
}

function currentSlot(settings) {
  const timezone =
    settings.timezone ||
    'Europe/Berlin';

  const local =
    localParts(timezone);

  if (FORCE) {
    return {
      eligible: true,
      key:
        `manual-${new Date().toISOString()}`,
      timezone,
      local
    };
  }

  if (settings.mode === 'hourly') {
    if (local.hour < 5 || local.hour > 18) {
      return {
        eligible: false,
        timezone,
        local
      };
    }

    return {
      eligible: true,
      key:
        `${local.date}-${String(local.hour).padStart(2, '0')}`,
      timezone,
      local
    };
  }

  if (settings.mode === 'two-hour') {
    const hours =
      new Set([5, 7, 9, 11, 13, 15, 17]);

    if (!hours.has(local.hour)) {
      return {
        eligible: false,
        timezone,
        local
      };
    }

    return {
      eligible: true,
      key:
        `${local.date}-${String(local.hour).padStart(2, '0')}`,
      timezone,
      local
    };
  }

  if (settings.mode === 'daily') {
    if (local.hour !== 6) {
      return {
        eligible: false,
        timezone,
        local
      };
    }

    return {
      eligible: true,
      key:
        `${local.date}-06`,
      timezone,
      local
    };
  }

  return {
    eligible: false,
    timezone,
    local
  };
}

function smtpConfig() {
  const required = [
    'OM_SMTP_HOST',
    'OM_SMTP_PORT',
    'OM_SMTP_USER',
    'OM_SMTP_PASSWORD',
    'OM_EMAIL_FROM',
    'OM_EMAIL_TO'
  ];

  const missing =
    required.filter(
      key =>
        !String(process.env[key] || '').trim()
    );

  if (missing.length) {
    throw new Error(
      `Fehlende GitHub Secrets: ${missing.join(', ')}`
    );
  }

  const port =
    Number(process.env.OM_SMTP_PORT);

  if (!Number.isFinite(port)) {
    throw new Error(
      'OM_SMTP_PORT ist keine gültige Zahl.'
    );
  }

  return {
    host: process.env.OM_SMTP_HOST,
    port,
    secure: port === 465,
    auth: {
      user: process.env.OM_SMTP_USER,
      pass: process.env.OM_SMTP_PASSWORD
    },
    from: process.env.OM_EMAIL_FROM,
    to: process.env.OM_EMAIL_TO
  };
}

function groupItems(items) {
  const groups = new Map();

  for (const item of items) {
    const label =
      item.sourceLabel ||
      compactSourceName(item.source);

    if (!groups.has(label)) {
      groups.set(label, []);
    }

    groups.get(label).push(item);
  }

  return groups;
}

function summaryParts(stats = {}) {
  const parts = [];

  if (stats.readerSeen) {
    parts.push(`${stats.readerSeen} bereits im Reader gesehen`);
  }
  if (stats.historical) {
    parts.push(`${stats.historical} Altbestand/nicht aktuell`);
  }
  if (stats.lowPriority) {
    parts.push(`${stats.lowPriority} geringe Relevanz`);
  }
  if (stats.quality) {
    parts.push(`${stats.quality} Navigation/Duplikate/Fehltreffer`);
  }

  return parts;
}

function buildMail(items, force, stats = {}) {
  if (force && items.length === 0) {
    return {
      subject:
        'OM News Watcher – Test-E-Mail',
      text:
        'Die E-Mail-Benachrichtigung funktioniert. Aktuell liegen keine neuen relevanten Meldungen für eine Vorschau vor.',
      html:
        '<h2>OM News Watcher</h2><p>Die E-Mail-Benachrichtigung funktioniert.</p><p>Aktuell liegen keine neuen relevanten Meldungen für eine Vorschau vor.</p>'
    };
  }

  const groups = groupItems(items);
  const count = items.length;

  const subject =
    force
      ? `OM News Watcher – Test mit ${count} relevanten Meldungen`
      : `OM News Watcher – ${count} neue relevante ${count === 1 ? 'Meldung' : 'Meldungen'}`;

  const subtitle =
    force
      ? 'Test-E-Mail – Vorschau mit aktuellen relevanten Meldungen'
      : `${count} neue relevante ${count === 1 ? 'Meldung' : 'Meldungen'}`;

  const textParts = [
    subtitle,
    ''
  ];

  const htmlParts = [
    '<div style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Arial,sans-serif;max-width:760px;margin:auto;color:#172033">',
    '<h2 style="margin-bottom:4px;">OM News Watcher</h2>',
    `<p style="margin-top:0;color:#667085;">${escHtml(subtitle)}</p>`
  ];

  for (const [source, sourceItems] of groups) {
    textParts.push(source);

    htmlParts.push(
      `<h3 style="margin-top:24px;margin-bottom:8px;">${escHtml(source)}</h3>`,
      '<ul style="padding-left:20px;">'
    );

    for (const item of sourceItems) {
      textParts.push(
        `• ${item.title}`,
        `  ${item.link}`
      );

      const priority =
        Math.max(
          1,
          Math.min(
            3,
            Number(item.priority || 2)
          )
        );

      const topic =
        Array.isArray(item.groups) && item.groups.length
          ? ` · ${item.groups.join(', ')}`
          : '';

      textParts.push(
        `  ${'★'.repeat(priority)}${topic}`
      );

      htmlParts.push(
        '<li style="margin-bottom:10px;">',
        `<a href="${escHtml(item.link)}" style="color:#1257a6;text-decoration:none;font-weight:600;">${escHtml(item.title)}</a>`,
        `<div style="font-size:12px;color:#667085;margin-top:2px;">${'★'.repeat(priority)}${escHtml(topic)}</div>`,
        '</li>'
      );
    }

    textParts.push('');
    htmlParts.push('</ul>');
  }

  const filtered = summaryParts(stats);

  if (filtered.length) {
    const filteredTotal =
      Number(stats.readerSeen || 0) +
      Number(stats.historical || 0) +
      Number(stats.lowPriority || 0) +
      Number(stats.quality || 0);

    textParts.push(
      `${filteredTotal} weitere Änderungen wurden nicht als neue relevante Meldungen versendet:`,
      filtered.join(' · '),
      ''
    );

    htmlParts.push(
      '<div style="margin-top:26px;padding:12px 14px;background:#f7f8fa;border:1px solid #e5e7eb;border-radius:8px;color:#667085;font-size:12px;">',
      `<strong>${filteredTotal} weitere Änderungen nicht gemeldet</strong><br>`,
      escHtml(filtered.join(' · ')),
      '</div>'
    );
  }

  htmlParts.push(
    '<hr style="border:0;border-top:1px solid #e5e7eb;margin-top:28px;">',
    '<p style="font-size:12px;color:#98a2b3;">OM News Watcher · gleiche Aktualitäts- und Qualitätslogik wie „Neu &amp; relevant“</p>',
    '</div>'
  );

  return {
    subject,
    text: textParts.join('\n'),
    html: htmlParts.join('\n')
  };
}

async function sendMail(mail) {
  const smtp = smtpConfig();

  const transporter =
    nodemailer.createTransport({
      host: smtp.host,
      port: smtp.port,
      secure: smtp.secure,
      requireTLS: smtp.port !== 465,
      auth: smtp.auth
    });

  await transporter.verify();

  await transporter.sendMail({
    from: smtp.from,
    to: smtp.to,
    subject: mail.subject,
    text: mail.text,
    html: mail.html
  });
}

function addHandled(state, guids) {
  const merged = [
    ...(guids || []),
    ...(state.handledGuids || []),
    ...(state.sentGuids || [])
  ].filter(Boolean);

  state.handledGuids =
    [...new Set(merged)]
      .slice(0, MAX_HANDLED_GUIDS);
}

(async () => {
  const settings =
    readJson(
      SETTINGS_FILE,
      {
        mode: 'off',
        timezone: 'Europe/Berlin',
        enabledAt: null
      }
    );

  const rawItems =
    readJson(
      ITEMS_FILE,
      []
    );

  const sources =
    readJson(
      SOURCES_FILE,
      []
    );

  const readerState =
    readJson(
      READER_STATE_FILE,
      {
        lastSeenAt: null
      }
    );

  const state =
    readJson(
      STATE_FILE,
      {
        sentGuids: [],
        handledGuids: [],
        lastSlot: null,
        lastSentAt: null
      }
    );

  if (!FORCE && settings.mode === 'off') {
    console.log(
      'E-Mail-Benachrichtigungen sind ausgeschaltet.'
    );
    return;
  }

  const slot = currentSlot(settings);

  console.log(
    `Modus: ${settings.mode}; lokale Stunde: ${slot.local.hour}; Zeitzone: ${slot.timezone}`
  );

  if (!slot.eligible) {
    console.log(
      'Für diese lokale Stunde ist keine E-Mail vorgesehen.'
    );
    return;
  }

  if (!FORCE && state.lastSlot === slot.key) {
    console.log(
      `Zeitslot ${slot.key} wurde bereits verarbeitet.`
    );
    return;
  }

  const now = Date.now();
  const handled =
    new Set([
      ...(state.handledGuids || []),
      ...(state.sentGuids || [])
    ]);

  const enabledAt =
    settings.enabledAt
      ? Date.parse(settings.enabledAt)
      : NaN;

  const readerSeenAt =
    readerState.lastSeenAt
      ? Date.parse(readerState.lastSeenAt)
      : NaN;

  const { cleaned, rejected } =
    cleanLikeReader(rawItems, sources);

  const stats = {
    readerSeen: 0,
    historical: 0,
    lowPriority: 0,
    quality: 0
  };

  const handledThisRun = [];

  // Qualitätsausschlüsse zählen und als verarbeitet markieren.
  for (const entry of rejected) {
    const guid = entry?.item?.guid;

    if (!guid || handled.has(guid)) continue;

    const detected =
      Date.parse(entry?.item?.detectedAt || '');

    if (
      Number.isFinite(enabledAt) &&
      Number.isFinite(detected) &&
      detected < enabledAt
    ) {
      continue;
    }

    stats.quality += 1;
    handledThisRun.push(guid);
  }

  let candidates = [];

  for (const item of cleaned) {
    if (!item?.guid || handled.has(item.guid)) {
      continue;
    }

    const detected =
      Date.parse(item.detectedAt || '');

    if (
      Number.isFinite(enabledAt) &&
      Number.isFinite(detected) &&
      detected < enabledAt
    ) {
      // Vor Aktivierung der Mail-Funktion: dauerhaft ignorieren.
      handledThisRun.push(item.guid);
      continue;
    }

    if (Number(item.priority || 2) < 2) {
      stats.lowPriority += 1;
      handledThisRun.push(item.guid);
      continue;
    }

    if (!isCurrentPublication(item, now)) {
      stats.historical += 1;
      handledThisRun.push(item.guid);
      continue;
    }

    if (
      Number.isFinite(readerSeenAt) &&
      Number.isFinite(detected) &&
      detected <= readerSeenAt
    ) {
      // Der Artikel war bereits vorhanden, als der Reader zuletzt
      // geöffnet/bedient wurde. Keine verspätete Sammelmail mehr.
      stats.readerSeen += 1;
      handledThisRun.push(item.guid);
      continue;
    }

    candidates.push(item);
  }

  candidates.sort((a, b) => {
    const pa = Number(a.priority || 2);
    const pb = Number(b.priority || 2);

    if (pa !== pb) return pb - pa;

    const publishedA =
      itemPublishedTimestamp(a);
    const publishedB =
      itemPublishedTimestamp(b);

    if (
      Number.isFinite(publishedA) &&
      Number.isFinite(publishedB) &&
      publishedA !== publishedB
    ) {
      return publishedB - publishedA;
    }

    return (
      Date.parse(b.detectedAt || 0) -
      Date.parse(a.detectedAt || 0)
    );
  });

  if (FORCE) {
    const preview =
      cleaned
        .filter(
          item =>
            Number(item.priority || 2) >= 2 &&
            isCurrentPublication(item, now)
        )
        .slice(0, 5);

    const mail =
      buildMail(
        preview,
        true,
        stats
      );

    if (DRY_RUN) {
      console.log(mail.text);
      return;
    }

    await sendMail(mail);

    console.log(
      'Test-E-Mail wurde versendet.'
    );

    return;
  }

  // Alles, was bewusst gefiltert wurde, gilt als verarbeitet.
  addHandled(state, handledThisRun);

  if (candidates.length === 0) {
    state.lastSlot = slot.key;
    state.lastEvaluatedAt =
      new Date().toISOString();
    state.lastFilterSummary = stats;

    saveJson(
      STATE_FILE,
      state
    );

    console.log(
      'Keine neuen relevanten Meldungen – keine E-Mail gesendet.'
    );

    return;
  }

  const mail =
    buildMail(
      candidates,
      false,
      stats
    );

  if (DRY_RUN) {
    console.log(mail.text);
    return;
  }

  await sendMail(mail);

  state.sentGuids =
    [
      ...new Set([
        ...candidates.map(item => item.guid),
        ...(state.sentGuids || [])
      ])
    ].slice(0, 5000);

  addHandled(
    state,
    candidates.map(item => item.guid)
  );

  state.lastSlot = slot.key;
  state.lastSentAt =
    new Date().toISOString();
  state.lastEvaluatedAt =
    state.lastSentAt;
  state.lastFilterSummary = stats;
  state.lastSentCount =
    candidates.length;

  saveJson(
    STATE_FILE,
    state
  );

  console.log(
    `${candidates.length} neue relevante Meldung(en) per E-Mail versendet.`
  );
})().catch(error => {
  console.error(error);
  process.exit(1);
});
