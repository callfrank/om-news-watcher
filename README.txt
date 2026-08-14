OM News Watcher v1.9 – Visuelles Einlernen

Neu:
- „Visuell einlernen“ für jede Quelle.
- Die Website wird direkt in der Mac-App angezeigt.
- 2–3 echte Meldungen anklicken; die App leitet daraus Item-, Titel-, Link- und optional Datum-Selektoren ab.
- Vorschau zeigt, wie viele Links die Regel künftig erkennt.
- Erst „Regel übernehmen“ ändert die Quelle lokal; danach wie gewohnt speichern.
- Ein erneutes Einlernen ist jederzeit möglich.
- „Zur Automatik zurücksetzen“ stellt die vorherige Erkennungsregel wieder her.
- Neue Quellen können im Editor direkt mit „Speichern & visuell einlernen“ angelegt werden.

Stabilität:
- watcher.js basiert wieder auf dem bewährten v0.12-Kern.
- Keine globalen v1.7/v1.8-Spezialfilter mehr.
- Visuell eingelernte Regeln werden explizit in sources.json gespeichert und vom GitHub-Watcher genutzt.
- Bestehende sources.json wird beim Update nicht überschrieben.

E-Mail:
- Aus
- Stündlich (05–18 Uhr, also 05, 06, …, 18 Uhr)
- Alle 2 Stunden (05, 07, 09, 11, 13, 15, 17 Uhr)
- Täglich um 06 Uhr
- Es wird nur gemailt, wenn neue Treffer vorliegen.

Upload:
1. Inhalt von mac-app/ nach Repository/mac-app/ hochladen und ersetzen.
2. watcher.js im Repository-Hauptverzeichnis ersetzen.
3. notify.js im Repository-Hauptverzeichnis ersetzen.

NICHT ersetzen:
- sources.json
- email-settings.json
- data/*
- package.json
- .github/workflows/*
