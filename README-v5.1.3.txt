OM News Watcher v5.1.3 – Mail/Reader-Synchronisierung

ZIEL
Die E-Mail zeigt nur noch neue relevante Meldungen und schiebt keinen
Bestand nach, den du im Reader bereits gesehen hast.

UPLOAD / ERSETZEN
- notify.js
- .github/workflows/notify.yml
- mac-app/
- README.md

NICHT ERSETZEN
- sources.json
- data/state.json
- data/items.json
- data/email-state.json
- email-settings.json
- .github/workflows/watch.yml

NEU
Die App legt reader-state.json automatisch selbst an. Diese Datei bitte
nicht manuell erstellen.

TEST
1. neuen Mac-Build installieren
2. Reader einmal öffnen
3. etwa 2–3 Sekunden warten
4. GitHub-Repo prüfen: reader-state.json sollte vorhanden sein
5. optional in Einstellungen "Test-E-Mail senden"
6. bei der nächsten regulären Mail darf kein bereits im Reader vorhandener
   Altbestand mehr als "neue Treffer" erscheinen
