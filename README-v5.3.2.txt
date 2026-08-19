OM News Watcher v5.3.2

BITTE ERSETZEN:
- watcher.js
- mac-app/
- README.md

NICHT ERSETZEN:
- sources.json
- notify.js
- watch.yml
- notify.yml
- data/items.json
- data/state.json
- data/email-state.json

NACH DEM UPLOAD:
1. neuen Mac-Build installieren
2. Alle Quellen prüfen
3. GitHub-Lauf vollständig grün abwarten
4. Neu laden
5. DeliveryHero -> Quelle testen
6. Falls noch nötig: Neu einlernen -> 2–3 echte Meldungen -> Regel prüfen & übernehmen

ERWARTET:
- App 5.3.2
- Watcher v0.28
- statische DeliveryHero-Bereiche nicht mehr Reader-fähig
- sichtbare Datumsangaben in Karten werden auch ohne date-CSS-Klasse erkannt
- visuelles Einlernen besitzt reload-sicheren URL-Fallback
