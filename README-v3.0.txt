OM News Watcher v3.0 – Redaktion & Feed-Organisation

Neu:
- Ordner/Themenbereiche pro Quelle (Mehrfachzuordnung möglich)
- eigener RSS-Feed je Ordner unter docs/feeds/<slug>.xml
- OPML-Export aller Feeds
- CSV- und JSON-Export der Quellen
- OPML-Import (htmlUrl bevorzugt; reine xmlUrl-Feeds werden direkt als RSS/Atom-Quelle überwacht)
- redaktionelle Relevanz mit 1–3 Sternen
- Schlagwörter pro Quelle
- optionale Include-/Exclude-Keywordfilter
- Ordnernavigation und Statusfilter in der Seitenleiste
- Mehrfachverwaltung/Bulk-Aktionen
- Quellen-Gesundheitsübersicht
- Feed-Vorschau aus data/items.json
- letzter neuer Treffer pro Quelle
- Duplikaterkennung im Feed; Fundstellen werden zusammengeführt
- Priorität und Themen in RSS und E-Mail-Digest
- bestehender Button „Alle testen“ bleibt erhalten
- Toolbar bleibt beschriftet

Upload:
1. mac-app/ nach Repository/mac-app/ hochladen und ersetzen
2. watcher.js ins Repository-Hauptverzeichnis ersetzen
3. notify.js ins Repository-Hauptverzeichnis ersetzen
4. watch.yml nach .github/workflows/watch.yml ersetzen

Nicht ersetzen:
- sources.json
- email-settings.json
- data/state.json
- data/items.json
- package.json
- notify.yml
- build-macos-app.yml
