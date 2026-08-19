OM News Watcher v5.3.1 – Health Dashboard

BITTE ERSETZEN:
- watcher.js
- mac-app/
- README.md

NICHT ERSETZEN:
- sources.json
- notify.js
- .github/workflows/watch.yml
- .github/workflows/notify.yml
- data/items.json
- data/state.json
- data/email-state.json
- email-settings.json

NACH DEM UPLOAD:
1. neuen Mac-Build installieren
2. "Alle Quellen prüfen" ausführen
3. GitHub-Lauf bis watch + deploy grün abwarten
4. App -> Neu laden
5. Probleme -> Quellen-Gesundheit öffnen

ERWARTET:
- App 5.3.1
- Watcher v0.27
- Tracking-Schema 3
- "Keine neue Meldung" zählt NICHT als Problem
- Technisch / Reader sind getrennte Spalten
- echte Abruffehler = Fehler
- Trefferzahl-Anomalien = Auffällig
- Reparaturen heute statt nur kumulierter Gesamtzahl
