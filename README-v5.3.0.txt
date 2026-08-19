OM News Watcher v5.3.0 – News-Eligibility-Gate

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

NACH DEM UPDATE:
1. neuen Mac-Build installieren
2. Button heißt jetzt „Alle Quellen prüfen“
3. vollständigen Watcher-Lauf starten
4. anschließend „Neu laden“
5. im Quellendetail muss Watcher-Version v0.26 stehen
6. BMJ -> Quelle testen: technische Treffer und Reader-fähige Treffer werden getrennt gezeigt

Erwartung für die gezeigten alten BMJ-Treffer:
- alte Meldungen: verworfen als Altbestand
- SharedDocs/Publikationen: verworfen als statische Publikation
- CSS/SVG-Titel: verworfen als Artefakt
