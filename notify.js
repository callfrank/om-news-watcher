const fs = require('fs');
const path = require('path');
const nodemailer = require('nodemailer');

const ROOT = __dirname;
const SETTINGS_FILE = path.join(ROOT, 'email-settings.json');
const ITEMS_FILE = path.join(ROOT, 'data', 'items.json');
const STATE_FILE = path.join(ROOT, 'data', 'email-state.json');

const FORCE = /^(1|true|yes)$/i.test(
  process.env.OM_NOTIFY_FORCE || ''
);

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
  let result =
    String(value || '')
      .trim();

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
    result =
      result
        .replace(pattern, '')
        .trim();
  }

  return result ||
    String(value || '').trim() ||
    'Quelle';
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
      parts.map(
        p => [p.type, p.value]
      )
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

  if (settings.mode === 'two-hour') {
    const hours =
      new Set([
        5, 7, 9, 11, 13, 15, 17
      ]);

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
        !String(
          process.env[key] || ''
        ).trim()
    );

  if (missing.length) {
    throw new Error(
      `Fehlende GitHub Secrets: ${missing.join(', ')}`
    );
  }

  const port =
    Number(
      process.env.OM_SMTP_PORT
    );

  if (!Number.isFinite(port)) {
    throw new Error(
      'OM_SMTP_PORT ist keine gültige Zahl.'
    );
  }

  return {
    host:
      process.env.OM_SMTP_HOST,
    port,
    secure:
      port === 465,
    auth: {
      user:
        process.env.OM_SMTP_USER,
      pass:
        process.env.OM_SMTP_PASSWORD
    },
    from:
      process.env.OM_EMAIL_FROM,
    to:
      process.env.OM_EMAIL_TO
  };
}

function groupItems(items) {
  const groups =
    new Map();

  for (const item of items) {
    const label =
      item.sourceLabel ||
      compactSourceName(
        item.source
      );

    if (!groups.has(label)) {
      groups.set(
        label,
        []
      );
    }

    groups.get(label).push(item);
  }

  return groups;
}

function buildMail(items, force) {
  if (force && items.length === 0) {
    return {
      subject:
        'OM News Watcher – Test-E-Mail',
      text:
        'Die E-Mail-Benachrichtigung funktioniert. Aktuell liegen keine Feed-Einträge für eine Vorschau vor.',
      html:
        '<h2>OM News Watcher</h2><p>Die E-Mail-Benachrichtigung funktioniert.</p><p>Aktuell liegen keine Feed-Einträge für eine Vorschau vor.</p>'
    };
  }

  const groups =
    groupItems(items);

  const count =
    items.length;

  const subject =
    force
      ? `OM News Watcher – Test mit ${count} Treffern`
      : `OM News Watcher – ${count} neue${count === 1 ? 'r Treffer' : ' Treffer'}`;

  const textParts = [
    force
      ? 'Test-E-Mail – Vorschau mit aktuellen Feed-Einträgen'
      : `${count} neue Treffer`,
    ''
  ];

  const htmlParts = [
    '<div style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Arial,sans-serif;max-width:760px;margin:auto;color:#172033">',
    `<h2 style="margin-bottom:4px;">OM News Watcher</h2>`,
    `<p style="margin-top:0;color:#667085;">${
      force
        ? 'Test-E-Mail – Vorschau mit aktuellen Feed-Einträgen'
        : `${count} neue Treffer`
    }</p>`
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

      htmlParts.push(
        '<li style="margin-bottom:10px;">',
        `<a href="${escHtml(item.link)}" style="color:#1257a6;text-decoration:none;font-weight:600;">${escHtml(item.title)}</a>`,
        '</li>'
      );
    }

    textParts.push('');
    htmlParts.push('</ul>');
  }

  htmlParts.push(
    '<hr style="border:0;border-top:1px solid #e5e7eb;margin-top:28px;">',
    '<p style="font-size:12px;color:#98a2b3;">OM News Watcher · onlinemarktplatz.de</p>',
    '</div>'
  );

  return {
    subject,
    text:
      textParts.join('\n'),
    html:
      htmlParts.join('\n')
  };
}

async function sendMail(mail) {
  const smtp =
    smtpConfig();

  const transporter =
    nodemailer.createTransport({
      host:
        smtp.host,
      port:
        smtp.port,
      secure:
        smtp.secure,
      requireTLS:
        smtp.port !== 465,
      auth:
        smtp.auth
    });

  await transporter.verify();

  await transporter.sendMail({
    from:
      smtp.from,
    to:
      smtp.to,
    subject:
      mail.subject,
    text:
      mail.text,
    html:
      mail.html
  });
}

(async () => {
  const settings =
    readJson(
      SETTINGS_FILE,
      {
        mode:
          'off',
        timezone:
          'Europe/Berlin',
        enabledAt:
          null
      }
    );

  const items =
    readJson(
      ITEMS_FILE,
      []
    );

  const state =
    readJson(
      STATE_FILE,
      {
        sentGuids:
          [],
        lastSlot:
          null,
        lastSentAt:
          null
      }
    );

  if (
    !FORCE &&
    settings.mode === 'off'
  ) {
    console.log(
      'E-Mail-Benachrichtigungen sind ausgeschaltet.'
    );
    return;
  }

  const slot =
    currentSlot(settings);

  console.log(
    `Modus: ${settings.mode}; lokale Stunde: ${slot.local.hour}; Zeitzone: ${slot.timezone}`
  );

  if (
    !slot.eligible
  ) {
    console.log(
      'Für diese lokale Stunde ist keine E-Mail vorgesehen.'
    );
    return;
  }

  if (
    !FORCE &&
    state.lastSlot === slot.key
  ) {
    console.log(
      `Zeitslot ${slot.key} wurde bereits verarbeitet.`
    );
    return;
  }

  const sent =
    new Set(
      state.sentGuids || []
    );

  const enabledAt =
    settings.enabledAt
      ? Date.parse(
          settings.enabledAt
        )
      : null;

  let candidates =
    items.filter(
      item => {
        if (
          !item ||
          !item.guid ||
          !item.title ||
          !item.link
        ) {
          return false;
        }

        if (
          sent.has(
            item.guid
          )
        ) {
          return false;
        }

        if (
          enabledAt &&
          Number.isFinite(enabledAt)
        ) {
          const detected =
            Date.parse(
              item.detectedAt || ''
            );

          if (
            Number.isFinite(detected) &&
            detected < enabledAt
          ) {
            return false;
          }
        }

        return true;
      }
    );

  candidates.sort(
    (a, b) =>
      Date.parse(
        a.detectedAt || 0
      ) -
      Date.parse(
        b.detectedAt || 0
      )
  );

  if (FORCE) {
    // Eine Testmail soll keine echten Benachrichtigungen
    // als "verschickt" markieren.
    const preview =
      items
        .filter(
          item =>
            item &&
            item.title &&
            item.link
        )
        .slice(
          0,
          5
        );

    const mail =
      buildMail(
        preview,
        true
      );

    if (
      /^(1|true|yes)$/i.test(
        process.env.OM_NOTIFY_DRY_RUN || ''
      )
    ) {
      console.log(mail.text);
      return;
    }

    await sendMail(mail);

    console.log(
      'Test-E-Mail wurde versendet.'
    );

    return;
  }

  if (
    candidates.length === 0
  ) {
    state.lastSlot =
      slot.key;

    saveJson(
      STATE_FILE,
      state
    );

    console.log(
      'Keine neuen Treffer – keine E-Mail gesendet.'
    );

    return;
  }

  const mail =
    buildMail(
      candidates,
      false
    );

  if (
    /^(1|true|yes)$/i.test(
      process.env.OM_NOTIFY_DRY_RUN || ''
    )
  ) {
    console.log(mail.text);
    return;
  }

  await sendMail(mail);

  const merged =
    [
      ...candidates.map(
        item => item.guid
      ),
      ...(state.sentGuids || [])
    ];

  state.sentGuids =
    [
      ...new Set(
        merged
      )
    ].slice(
      0,
      5000
    );

  state.lastSlot =
    slot.key;

  state.lastSentAt =
    new Date()
      .toISOString();

  saveJson(
    STATE_FILE,
    state
  );

  console.log(
    `${candidates.length} neue Treffer per E-Mail versendet.`
  );
})().catch(error => {
  console.error(error);
  process.exit(1);
});
