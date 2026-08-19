from pathlib import Path

WATCHER = Path("watcher.js")

OLD_VERSION = "const VERSION = '0.32';"
NEW_VERSION = "const VERSION = '0.33';"

INSERT_BEFORE_FETCH = r'''async function fetchTextFresh(rawUrl, options = {}) {
'''

HTML_HELPER = r'''function stripHtmlText(value = '') {
  return String(value || '')
    .replace(/<script\b[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style\b[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&nbsp;/gi, ' ')
    .replace(/&#(\d+);/g, (_, value) => {
      try { return String.fromCodePoint(Number(value)); } catch { return ' '; }
    })
    .replace(/\s+/g, ' ')
    .trim();
}

function htmlDateFromText(value = '') {
  const text = stripHtmlText(value);
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
}

function preferredHtmlTitle(html = '') {
  const headingPattern = /<h[1-6]\b[^>]*>([\s\S]*?)<\/h[1-6]>/gi;
  const headings = [];
  let match;

  while ((match = headingPattern.exec(html)) !== null) {
    const value = normalizeTitle(stripHtmlText(match[1]));
    if (
      value.length >= 8 &&
      value.length <= 320 &&
      !genericTitle(value)
    ) {
      headings.push(value);
    }
  }

  if (headings.length) {
    return headings.sort((a, b) => b.length - a.length)[0];
  }

  const titleMatch = html.match(/<title\b[^>]*>([\s\S]*?)<\/title>/i);
  if (titleMatch?.[1]) {
    const value = normalizeTitle(stripHtmlText(titleMatch[1]));
    if (value.length >= 8 && value.length <= 320 && !genericTitle(value)) {
      return value;
    }
  }

  return '';
}

function configuredHtmlTargets(html = '', source) {
  const includeRegex = safeRegex(source.includeRegex);
  if (!includeRegex) return [];

  const rawCandidates = [];
  const anchorPattern = /<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>/gi;
  let match;

  while ((match = anchorPattern.exec(html)) !== null) {
    rawCandidates.push(match[1]);
  }

  // Headless-/React-Seiten können Ziel-URLs zusätzlich nur in JSON oder
  // JavaScript serialisieren. Deshalb auch escaped URL-Strings scannen.
  const decoded = String(html || '')
    .replace(/\\u002f/gi, '/')
    .replace(/\\\//g, '/');

  const embeddedPatterns = [
    /https?:\/\/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+/gi,
    /\/(?:[A-Za-z0-9._~!$&'()*+,;=:@%\-]+\/){2,}[A-Za-z0-9._~!$&'()*+,;=:@%\-]+/g
  ];

  for (const pattern of embeddedPatterns) {
    for (const value of decoded.match(pattern) || []) {
      rawCandidates.push(value);
    }
  }

  const targets = [];
  const seen = new Set();

  for (const raw of rawCandidates) {
    const link = canonicalUrl(raw, source.url);
    if (!link) continue;
    if (!isAllowedUrl(link, source)) continue;
    if (!includeRegex.test(link)) continue;
    if (source.visualLearned === true && !visualSampleShapeAllows(link, source)) continue;

    const key = link.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    targets.push(link);

    if (targets.length >= 20) break;
  }

  return targets;
}

async function fetchConfiguredHtmlRows(source) {
  if (!source.includeRegex) return [];

  const overview = await fetchTextFresh(source.url, {
    timeoutMs: 7000,
    accept: 'text/html,application/xhtml+xml,*/*'
  });

  const targets = configuredHtmlTargets(overview.text, source);
  if (!targets.length) return [];

  const rows = await Promise.all(
    targets.map(async link => {
      try {
        const detail = await fetchTextFresh(link, {
          timeoutMs: 6500,
          accept: 'text/html,application/xhtml+xml,*/*'
        });

        const title = preferredHtmlTitle(detail.text);
        if (!title) return null;

        return {
          title,
          href: link,
          date: htmlDateFromText(detail.text)
        };
      } catch {
        return null;
      }
    })
  );

  return rows.filter(Boolean);
}

'''

OLD_RUNTIME_MARKER = r'''    // Bei Startseiten zusätzlich einen unabhängigen RSS-/Atom-Kanal nutzen.
'''

NEW_RUNTIME_BLOCK = r'''    // v0.33: Wenn Playwright trotz einer engen, visuell gelernten
    // URL-Regel keine Treffer liefert, die Seite direkt als HTML laden.
    // Passende Detail-URLs werden ausschließlich über includeRegex und die
    // Form der Trainingsbeispiele zugelassen; Titel/Datum kommen anschließend
    // von den Detailseiten. Das vermeidet seitenabhängige Sonderregeln.
    if (
      rows.length === 0 &&
      Boolean(source.includeRegex) &&
      (source.visualLearned === true || Array.isArray(source.visualSampleURLs))
    ) {
      try {
        const htmlRows = await fetchConfiguredHtmlRows(source);
        const htmlFiltered = normalizeAndFilter(htmlRows, source);

        if (htmlFiltered.length > 0) {
          rows = htmlFiltered;
          notes.push(
            `HTML-URL-Fallback: ${rows.length} Treffer über gespeichertes URL-Muster.`
          );
        } else {
          notes.push('HTML-URL-Fallback: keine zum URL-Muster passenden Detailseiten.');
        }
      } catch (err) {
        notes.push(
          `HTML-URL-Fallback fehlgeschlagen: ${err?.message || String(err)}`
        );
      }
    }

    // Bei Startseiten zusätzlich einen unabhängigen RSS-/Atom-Kanal nutzen.
'''


def main() -> None:
    text = WATCHER.read_text(encoding="utf-8")

    if NEW_VERSION not in text:
        if OLD_VERSION not in text:
            raise SystemExit("watcher.js: expected VERSION 0.32 not found")
        text = text.replace(OLD_VERSION, NEW_VERSION, 1)
        print("watcher.js: version bumped to 0.33")
    else:
        print("watcher.js: version already 0.33")

    if "async function fetchConfiguredHtmlRows(source)" not in text:
        if INSERT_BEFORE_FETCH not in text:
            raise SystemExit("watcher.js: fetchTextFresh insertion point not found")
        text = text.replace(
            INSERT_BEFORE_FETCH,
            HTML_HELPER + INSERT_BEFORE_FETCH,
            1,
        )
        print("watcher.js: configured HTML fallback helpers applied")
    else:
        print("watcher.js: configured HTML fallback helpers already present")

    if "HTML-URL-Fallback: ${rows.length} Treffer" not in text:
        if OLD_RUNTIME_MARKER not in text:
            raise SystemExit("watcher.js: runtime fallback insertion point not found")
        text = text.replace(
            OLD_RUNTIME_MARKER,
            NEW_RUNTIME_BLOCK,
            1,
        )
        print("watcher.js: HTML URL fallback runtime applied")
    else:
        print("watcher.js: HTML URL fallback runtime already present")

    WATCHER.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
