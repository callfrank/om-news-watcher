OM News Watcher v1.7 / watcher v0.13

Neu:
- Semantische Titel-Erkennung für Card-/Teaser-Seiten.
  CTA-Texte wie „Mehr erfahren“ oder „Link öffnet in neuem Tab“
  werden nach Möglichkeit durch die echte Überschrift der Karte ersetzt.
- Offensichtliche Mülltreffer werden global verworfen:
  Cookie-Buttons, HTML-Markup als Titel, generische CTA-Titel,
  Shop-/Produktpfade und generische PDF-/Factsheet-Treffer.
- Publikationsdatum wird aus <time>, Datumsfeldern oder eindeutigen URL-Daten
  übernommen, wenn es zuverlässig erkennbar ist.
- Im RSS bleibt der Titel kompakt:
    Deloitte · Originaltitel
  Die Beschreibung enthält zusätzlich:
    Quelle · Veröffentlicht · Erkannt
- Im Schnelltest zeigt die Mac-App ein gefundenes Veröffentlichungsdatum an.

Sicherheits-/Regression-Prinzip:
- GLOBAL_BASELINE_TOKEN bleibt unverändert.
- Bestehende Quellen werden durch v1.7 NICHT automatisch neu baseline-gesetzt.
- Bestehende Spezialregeln in sources.json bleiben erhalten.
- Wenn die neue Qualitätsprüfung nur Müll findet, wird lieber 0 Treffer gemeldet,
  statt einen falschen grünen Status zu erzeugen.
- Die Änderungen an v1.7 selbst schreiben sources.json nicht um.

Beispiele der adressierten Fehlertypen:
- Galaxus: Produktkategorien statt Medienmitteilungen
- experte.de: Event-Cards ohne direkt brauchbaren Linktext
- OMT: HTML-/Bildinhalt als Titel
- PayPal: „Link öffnet in neuem Tab“
- Startup-Verband: „Mehr erfahren“
- ServiceValue: Cookie-Aktion „Alle akzeptieren“
- Visa / YouGov: generische PDF-/Factsheet-Treffer
- Mordor: Card-/Teaser-Strukturen mit bisher 0 Treffern

Upload:
1. Inhalt von mac-app/ nach Repository/mac-app/ hochladen und ersetzen.
2. watcher.js im Repository-Hauptverzeichnis ersetzen.

NICHT ersetzen:
- sources.json
- email-settings.json
- data/state.json
- data/items.json
- notify.js
- package.json
- .github/workflows/*
