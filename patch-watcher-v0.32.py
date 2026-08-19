from pathlib import Path

WATCHER = Path("watcher.js")

OLD_VERSION = "const VERSION = '0.31';"
NEW_VERSION = "const VERSION = '0.32';"

OLD_AUTOMATIC_BLOCK = r'''    return nodes.map(el => {
      const card = el.closest?.(cardSelector) || el.parentElement || el;
      return { title: titleFor(el, card), href: hrefFrom(el, card), date: dateFor(card) };
    });
'''

NEW_AUTOMATIC_BLOCK = r'''    const clickableProbeSelector = 'a[href],[data-href],[data-url],[data-link],[role="link"],button[onclick],[onclick]';
    const titleProbeSelector = 'h1,h2,h3,h4,h5,h6,[class*="headline" i],[class*="heading" i],[class*="title" i],[data-testid*="title" i],strong';

    const cardFor = el => {
      const semantic = el?.closest?.(cardSelector);
      if (semantic) return semantic;

      let node = el?.parentElement;
      const fallback = node || el;

      for (
        let depth = 0;
        node && depth < 9 && node !== document.body && node !== document.documentElement;
        depth += 1, node = node.parentElement
      ) {
        const text = clean(node.textContent || '');
        if (text.length < 8 || text.length > 3000) continue;

        const linkCount = node.querySelectorAll?.(clickableProbeSelector)?.length || 0;
        if (linkCount < 1 || linkCount > 16) continue;

        const hasPlausibleTitle = Array.from(
          node.querySelectorAll?.(titleProbeSelector) || []
        ).some(candidate => {
          const value = clean(
            candidate.textContent ||
            candidate.getAttribute?.('aria-label') ||
            candidate.title ||
            ''
          );
          return value.length >= 5 && value.length <= 320 && !generic(value);
        });

        if (hasPlausibleTitle) return node;
      }

      return fallback;
    };

    return nodes.map(el => {
      const card = cardFor(el);
      return {
        title: titleFor(el, card),
        href: hrefFrom(el, card),
        date: dateFor(card)
      };
    });
'''


def main() -> None:
    text = WATCHER.read_text(encoding="utf-8")

    if NEW_VERSION not in text:
        if OLD_VERSION not in text:
            raise SystemExit("watcher.js: expected VERSION 0.31 not found")
        text = text.replace(OLD_VERSION, NEW_VERSION, 1)
        print("watcher.js: version bumped to 0.32")
    else:
        print("watcher.js: version already 0.32")

    if "const cardFor = el => {" not in text or "clickableProbeSelector" not in text:
        if OLD_AUTOMATIC_BLOCK not in text:
            raise SystemExit("watcher.js: automatic card block not found")
        text = text.replace(
            OLD_AUTOMATIC_BLOCK,
            NEW_AUTOMATIC_BLOCK,
            1,
        )
        print("watcher.js: smart ancestor card detection applied")
    else:
        print("watcher.js: smart ancestor card detection already present")

    WATCHER.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
