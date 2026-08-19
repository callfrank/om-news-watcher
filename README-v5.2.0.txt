OM News Watcher v5.2.0 – Quality Gate

ERSETZEN:
- watcher.js
- notify.js
- mac-app/
- README.md

NICHT ERSETZEN:
- sources.json
- data/state.json
- data/items.json
- data/email-state.json
- email-settings.json
- .github/workflows/watch.yml
- .github/workflows/notify.yml

Nach dem ersten erfolgreichen Watcher-Lauf bereinigt v5.2.0 automatisch bestehende Fehltreffer und cache-busted Duplikate in data/items.json.
