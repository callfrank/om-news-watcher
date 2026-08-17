OM News Watcher v2.0

Schwerpunkte dieser Version
===========================

1. Bedienung
- Toolbar-Buttons mit kurzen sichtbaren Beschriftungen und Tooltips.
- Neuer Button „Alle testen“ mit Fortschritt über alle aktiven Quellen.
- Timeout wird als eigener Status angezeigt.
- Große, aber strukturell plausible Archive werden nicht mehr automatisch als Fehler gewertet.

2. Visuelles Einlernen v2
- Markieren von Links, Karten, Buttons, role=link, data-href/data-url und einfachen onclick-Zielen.
- CTA-Texte wie „Weiterlesen“, „Read article“, „Mehr erfahren“, „Download“ und PDF-Größen werden nicht als Titel akzeptiert.
- Titel, Datum und Ziel-Link werden innerhalb derselben Karte gesucht.
- Aus den Trainingsbeispielen wird zusätzlich ein gemeinsames URL-Muster gelernt.
- Dynamische CSS-Klassen werden stärker gemieden.
- Zu enge Regeln (z. B. 3 Beispiele -> 1 Treffer) werden abgelehnt.
- Nach „Regel übernehmen“ erfolgt ein kompletter Reload-Test. Erst danach wird die Regel als validiert gespeichert.
- Bei fehlgeschlagener Validierung bleibt die vorherige Regel unverändert.

3. Schutz vor falschen Regeln
- Automatische Reparaturen werden vor dem Speichern erneut getestet.
- Fremde Asset-/PDF-Bereiche werden nicht als Reparatur akzeptiert, wenn sie nicht zur Quelle passen.
- Visuell eingelernten Regeln steht bei instabilen CSS-Selektoren ein URL-Muster-Fallback zur Verfügung.

4. Trefferqualität
- Smart-Titel-Erkennung im Mac-Schnelltest und im GitHub-Watcher.
- CTA-/PDF-Titel werden durch Überschriften aus dem Kartenblock ersetzt.
- Datum wird – sofern im Kartenblock vorhanden – separat übernommen.
- Externe Links bleiben möglich, wenn sie beim Einlernen tatsächlich ausgewählt wurden.

5. GitHub-Stabilität
- watch.yml versucht nicht mehr, generierte docs/feed.xml-Dateien per Rebase zu mergen.
- Bei parallelen Änderungen wird der neueste main-Stand geholt und nur die frisch erzeugten Feed-/State-Dateien darübergelegt.

6. E-Mail
- Bestehende Modi bleiben erhalten: Aus, stündlich 05–18 Uhr, alle 2 Stunden 05–18 Uhr, täglich 06 Uhr.

Upload nach GitHub
==================

- Inhalt von mac-app/ -> Repository/mac-app/ ersetzen
- watcher.js -> Repository-Hauptverzeichnis ersetzen
- notify.js -> Repository-Hauptverzeichnis ersetzen
- watch.yml -> Repository/.github/workflows/watch.yml ersetzen

NICHT ersetzen:
- sources.json
- email-settings.json
- data/state.json
- data/items.json
- package.json
- notify.yml / build-macos-app.yml

Empfohlener Test nach dem Build
===============================
1. Telekom prüfen (Regression: muss weiterhin gut sein).
2. Galaxus/SHEIN visuell einlernen (3 Beispiele müssen >=3 Vorschautreffer ergeben).
3. JD/Mordor/MediaMarktSaturn/PayPal/Startup-Verband einlernen (Reload-Validierung).
4. HelloFresh prüfen (keine fremde PDF-Flut).
5. Momox/Wish/YouGov/Flaschenpost prüfen (echte Titel statt CTA/PDF-Größe).
6. Etsy/Visa prüfen (große plausible Archive).
7. Tencent prüfen (Timeout eigener Status).
8. „Alle testen“ ausführen.
9. OM News Watcher Workflow manuell starten und Git-Speicherung prüfen.
