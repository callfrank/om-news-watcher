OM News Watcher v1.8.2

Gezielter Stabilitätsfix:
- Galaxus: mindestens 4 Sekunden Ladezeit, breiter Link-Fallback, danach enger /de/page/-Filter.
- Zalando: breiter Link-Fallback; Filter-/Sortierlinks werden weiter ausgeschlossen.
- OTTO: bereinigter Pressetitel statt „Presse + Datum + Titel + Mehr erfahren“.
- OTTO: Publikationsdatum wird aus der Kartenzeile übernommen.

Upload:
1. Inhalt von mac-app/ nach Repository/mac-app/ hochladen und ersetzen.
2. watcher.js im Repository-Hauptverzeichnis ersetzen.

Nicht anfassen:
sources.json
email-settings.json
data/*
notify.js
package.json
.github/workflows/*
