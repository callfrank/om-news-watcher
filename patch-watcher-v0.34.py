from pathlib import Path

WATCHER = Path("watcher.js")

OLD_VERSION = "const VERSION = '0.33';"
NEW_VERSION = "const VERSION = '0.34';"

OLD_TARGET_BLOCK = r'''  const rawCandidates = [];
  const anchorPattern = /<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>/gi;
  let match;

  while ((match = anchorPattern.exec(html)) !== null) {
    rawCandidates.push(match[1]);
  }
'''

NEW_TARGET_BLOCK = r'''  const rawCandidates = [];

  // v0.34: href-Werte sowohl quoted als auch unquoted lesen. Einige
  // Headless-/CMS-Ausgaben unterscheiden sich hier vom Browser-DOM.
  const anchorPattern = /<a\b[^>]*?href\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))/gi;
  let match;

  while ((match = anchorPattern.exec(html)) !== null) {
    const value = match[1] || match[2] || match[3] || '';
    if (value) rawCandidates.push(value);
  }
'''

OLD_RAW_LOOP = r'''  for (const raw of rawCandidates) {
    const link = canonicalUrl(raw, source.url);
'''

NEW_RAW_LOOP = r'''  for (const raw of rawCandidates) {
    const cleanedRaw = decodeHtmlEntities(String(raw || ''))
      .replace(/^[\s"'(<]+|[\s"')>,;\\]+$/g, '');
    const link = canonicalUrl(cleanedRaw, source.url);
'''

OLD_FETCH_ROWS = r'''async function fetchConfiguredHtmlRows(source) {
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

NEW_FETCH_ROWS = r'''async function fetchConfiguredHtmlRows(source, page = null) {
  if (!source.includeRegex) return [];

  // v0.34: Der bereits geladene Playwright-DOM ist die wichtigste Quelle.
  // Genau dort können dynamisch erzeugte News-Links vorhanden sein, die ein
  // zweiter serverseitiger fetch() nicht zurückliefert.
  let renderedHtml = '';
  if (page) {
    try {
      renderedHtml = await page.content();
    } catch {}
  }

  // Zusätzlich die exakte Quell-URL ohne Cache-Busting abrufen. Manche CMS
  // liefern bei unbekannten Query-Parametern eine reduzierte/andere Variante.
  let directHtml = '';
  try {
    const overview = await fetchTextFresh(source.url, {
      timeoutMs: 7000,
      cacheBust: false,
      accept: 'text/html,application/xhtml+xml,*/*'
    });
    directHtml = overview.text || '';
  } catch {}

  const combinedHtml = [renderedHtml, directHtml]
    .filter(Boolean)
    .join('\n');

  const targets = configuredHtmlTargets(combinedHtml, source);
  if (!targets.length) return [];

  const rows = await Promise.all(
    targets.map(async link => {
      try {
        const detail = await fetchTextFresh(link, {
          timeoutMs: 6500,
          cacheBust: false,
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

OLD_RUNTIME_CALL = r'''        const htmlRows = await fetchConfiguredHtmlRows(source);
'''

NEW_RUNTIME_CALL = r'''        const htmlRows = await fetchConfiguredHtmlRows(source, page);
'''


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new.strip() in text:
        print(f"{label}: already applied")
        return text
    if old not in text:
        raise SystemExit(f"{label}: expected block not found")
    print(f"{label}: applied")
    return text.replace(old, new, 1)


def main() -> None:
    text = WATCHER.read_text(encoding="utf-8")

    if NEW_VERSION not in text:
        if OLD_VERSION not in text:
            raise SystemExit("watcher.js: expected VERSION 0.33 not found")
        text = text.replace(OLD_VERSION, NEW_VERSION, 1)
        print("watcher.js: version bumped to 0.34")
    else:
        print("watcher.js: version already 0.34")

    text = replace_once(
        text,
        OLD_TARGET_BLOCK,
        NEW_TARGET_BLOCK,
        "watcher.js anchor discovery",
    )
    text = replace_once(
        text,
        OLD_RAW_LOOP,
        NEW_RAW_LOOP,
        "watcher.js URL cleanup",
    )
    text = replace_once(
        text,
        OLD_FETCH_ROWS,
        NEW_FETCH_ROWS,
        "watcher.js rendered DOM fallback",
    )
    text = replace_once(
        text,
        OLD_RUNTIME_CALL,
        NEW_RUNTIME_CALL,
        "watcher.js runtime page handoff",
    )

    WATCHER.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
