OM News Watcher v1.8 / watcher v0.14

Stabilitäts-Update:
- globalen v1.7-Filter zurückgenommen
- bewährten v1.6/v0.12-Kern wieder als Standard
- gezielte Spezialprofile nur für bekannte schwierige Quellen
- Publikationsdatum bleibt erhalten
- sources.json bleibt unverändert
- keine neue globale Baseline
- gespeicherte Feed-Einträge werden nicht durch neue versteckte Profile gelöscht

Gezielte Profile:
Visa, SHEIN, HelloFresh, Zalando, ECDB, MediaMarktSaturn,
Tencent, Google Ads & Commerce, JD Corporate News,
Amazon Freight, YouGov, Galaxus, Mordor Case Studies,
Mordor Insights, OMT und experte.de Events.

Bewusst nicht künstlich grün:
Google Think, ServiceValue und Wish können weiterhin 0 Treffer zeigen,
wenn die Website selbst keine brauchbare Artikelliste liefert.

Upload:
1. Inhalt von mac-app/ nach Repository/mac-app/ hochladen und ersetzen.
2. watcher.js im Repository-Hauptverzeichnis ersetzen.

NICHT ersetzen:
sources.json
email-settings.json
data/state.json
data/items.json
notify.js
package.json
.github/workflows/*
