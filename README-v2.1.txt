OM News Watcher v2.1

Fokus: Trefferqualität, Titelzerlegung und intelligentes URL-Lernen.

Neu/verbessert:
- Visuelles Einlernen speichert die 2–3 Beispiel-URLs dauerhaft als Qualitätsprofil.
- Beim Reload müssen Treffer zur URL-Form der Beispiele passen (Host, Query, Dateityp, Pfadtiefe, Slug-Länge, gemeinsamer Pfad).
- Quellen-Übersichtsseite selbst wird nie mehr als Artikel akzeptiert (Wish-Fall).
- Kategorien/Navigation/CTA-Titel werden auch bei includeRegex/Einlernregeln verworfen.
- Kartenüberschriften werden vor dem Link-/CTA-Text bevorzugt.
- Titel werden von Presse-/Datums-/CTA-Zusätzen bereinigt (OTTO/DPD/Flaschenpost).
- Publikationsdatum wird in der App kompakt als TT.MM.JJJJ dargestellt.
- Semantische Newsroom-/News-Verzeichnisse werden bei großen Treffermengen bevorzugt (SHEIN/Etsy).
- Automatische Reparatur verwirft extreme 80+ -> 2/3 Reduktionen und Landingpage-Vorschläge (HelloFresh/Visa).
- Bestehende v2.0-Funktionen bleiben: beschriftete Toolbar, Alle testen, Reload-Validierung, Timeout-Status, E-Mail-Modi, Cloudflare/Cookie-Bedienmodus.

Upload:
1. Inhalt von mac-app/ nach Repository/mac-app/ hochladen und vorhandene Dateien ersetzen.
2. watcher.js im Repository-Hauptverzeichnis ersetzen.

Nicht erneut hochladen/ändern:
- sources.json
- email-settings.json
- data/*
- notify.js
- package.json
- .github/workflows/*
