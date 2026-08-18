OM News Watcher v5.1.2 – Fetch-Hotfix

UPLOAD:
- watcher.js ersetzen
- mac-app/ ersetzen
- README.md ersetzen

NICHT ERSETZEN:
- sources.json
- data/state.json
- data/items.json
- .github/workflows/watch.yml

TEST:
1. neuen Mac-Build installieren
2. "Jetzt prüfen"
3. nach erfolgreichem Lauf "Neu laden"
4. Wortfilter muss "Watcher-Version v0.24" anzeigen
5. "Neuester erkannter Artikel" kontrollieren
6. Reader -> Alle Meldungen -> nach "awd" suchen
