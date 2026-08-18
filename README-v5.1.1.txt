OM News Watcher v5.1.1 – Tracking Hotfix

ZWEI ZIELE

1. Fehlende aktuelle Meldungen reparieren
   items.json ist nun die letzte Wahrheit.
   Ist ein Artikel auf der Quelle vorhanden, innerhalb der letzten 48 Stunden
   veröffentlicht und NICHT in items.json, wird er nachgeliefert – auch wenn
   alte seenBySource/deliveredBySource-Zustände den Link bereits kennen.

2. Alte Meldungen nicht als "heute neu" darstellen
   Publikationsdatum, Erkennungszeit und Auslieferungszeit werden getrennt.
   Artikel, die erst mehr als 72 Stunden nach ihrer Veröffentlichung
   ausgeliefert wurden, gelten als historicalBackfill.
   Sie bleiben in "Alle Meldungen", verschwinden aber aus:
   - Neu & relevant
   - Posteingang
   - Seit letztem Besuch
   - Heute relevant
   und werden nicht erneut in RSS-Themenfeeds als aktuelle Meldung ausgegeben.

UPLOAD
Ersetzen:
- watcher.js
- mac-app/
- README.md

NICHT ersetzen:
- sources.json
- data/state.json
- data/items.json
- .github/workflows/watch.yml

TEST NACH DEM UPDATE
1. Mac-App Build abwarten.
2. "Jetzt prüfen".
3. Nach erfolgreichem Lauf "Neu laden".
4. Reader -> Alle Meldungen -> "awd" suchen.
   Erwartung: Wortfilter-AWD erscheint, sofern die Quelle weiterhin ein
   Veröffentlichungsdatum innerhalb des 48-Stunden-Fensters liefert.
5. "Neu & relevant" öffnen.
   Erwartung: alte Schwarz-/Archivmeldungen erscheinen dort nicht mehr.
