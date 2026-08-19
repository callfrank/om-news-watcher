OM News Watcher v5.3.6 – Infra-Hotfix

BITTE ERSETZEN:
- watcher.js
- .github/workflows/watch.yml
- README.md

NICHT ERSETZEN:
- mac-app/
- sources.json
- notify.js
- notify.yml
- data/*

WICHTIG:
Der Mac-App-Build ist NICHT betroffen.
Die App bleibt 5.3.5.
Der Watcher wird 0.31.

NACH DEM UPLOAD:
1. Aktuell hängenden Watcher-Lauf abbrechen.
2. Den dadurch gestarteten/wartenden alten Lauf ebenfalls abbrechen, falls er
   noch die alte watch.yml geladen hat.
3. Actions -> OM News Watcher -> Run workflow.
4. Im neuen Lauf darf es KEINEN Schritt "Chromium installieren" mehr geben.
5. Stattdessen erscheint "Vorinstalliertes Chrome prüfen".
6. Nach grünem Lauf in der App "Neu laden".
7. Erwartete Watcher-Version: v0.31.
