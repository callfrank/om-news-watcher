OM News Watcher v5.1.0 – Tracking-Audit & Selbstheilung

WARUM DIESE VERSION?
Der Wortfilter-Fall vom 18.08.2026 hat gezeigt:
Eine Quelle kann lokal korrekt erkannt werden, während ein Link im zentralen
Tracking bereits als "gesehen" gilt, ohne je als Reader-Meldung ausgeliefert
worden zu sein.

NEU IN v5.1

1. "GESEHEN" UND "AUSGELIEFERT" SIND GETRENNT
- seenBySource = auf der Quelle erkannt
- deliveredBySource = tatsächlich als Meldung gespeichert
- Ein Link kann dadurch nicht mehr still zwischen beiden Zuständen verschwinden.

2. SELBSTHEILUNG (48 STUNDEN)
- Erkennt der Watcher einen Link, der schon als "gesehen" gilt,
  aber nie ausgeliefert wurde, prüft er das Veröffentlichungsdatum.
- Liegt es innerhalb der letzten 48 Stunden, wird die Meldung nachträglich
  in items.json / Reader übernommen.
- Solche Meldungen erhalten intern recovered=true.
- Bewusst beim Erst-/Baseline-Lauf unterdrückte Altmeldungen werden NICHT
  nachträglich ausgespielt.

3. BASELINE NUR NOCH BEWUSST
- Änderungen an einer Erkennungsregel lösen ab v0.22 keinen automatischen
  Baseline-Reset mehr aus.
- baselineVersion dient nur noch als Regel-Versionskennung.
- Neue Quellen bekommen weiterhin einmalig ihren notwendigen Start-Baseline.
- Ein expliziter Reset kann künftig über baselineRequestedVersion ausgelöst werden.

4. TRACKING-AUDIT PRO QUELLE
health.json enthält zusätzlich:
- trackingStatus / trackingWarning
- latestDetected
- latestStored
- healedCount
- baselineSuppressedCount
- undeliveredRecentCount

5. GESUNDHEITSDASHBOARD
- neue Spalte "Tracking"
- zeigt OK, fehlende aktuelle Meldungen oder Anzahl geretteter Meldungen
- Detailansicht zeigt "Neuester erkannter Artikel" und
  "Neuester gespeicherter Artikel"
- Tracking-Reparaturen werden gezählt.

ERSTER LAUF NACH DEM UPDATE
Der Watcher migriert vorhandene Reader-Einträge automatisch in deliveredBySource.
Wenn der Wortfilter-AWD-Link bereits in seenBySource steckt, aber nie im Reader
war, sollte er beim ersten v5.1-Lauf nachgeholt werden, sofern Wortfilter weiterhin
das Veröffentlichungsdatum innerhalb des 48-Stunden-Fensters liefert.

UPLOAD
Ersetzen:
- watcher.js im Repository-Hauptverzeichnis
- mac-app/ komplett

NICHT ersetzen:
- sources.json
- data/state.json
- data/items.json
- .github/workflows/watch.yml

Danach:
1. Mac-App-Build abwarten.
2. OM News Watcher einmal manuell über "Jetzt prüfen" starten.
3. Nach erfolgreichem Lauf "Neu laden".
4. Reader -> Alle Meldungen -> nach "awd" suchen.
