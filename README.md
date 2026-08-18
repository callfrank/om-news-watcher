# OM News Watcher

**OM News Watcher** ist ein eigenes News-, Presse- und Website-Monitoring-System für macOS und GitHub Actions.

Es überwacht definierte Webseiten auf neue Meldungen, Pressemitteilungen, Studien, Events, Quartalszahlen und andere relevante Veröffentlichungen. Die macOS-App dient dabei als Verwaltungs-, Prüf- und Reader-Oberfläche; die eigentliche automatische Überwachung läuft unabhängig davon über GitHub Actions.

**Aktueller Stand: v5.1.2**

---

## Was OM News Watcher macht

OM News Watcher kombiniert:

- automatisches Website-Monitoring
- visuelles Einlernen von Artikelbereichen
- automatische Reparatur problematischer Erkennungsregeln
- Quellenverwaltung mit Ordnern, Schlagworten und Relevanz
- individuelle Prüfintervalle
- Themenfeeds / RSS
- integrierten Reader
- Quellen-Gesundheitsdashboard
- Tracking-Audit
- Selbstheilung verlorener Meldungen
- Mehrfachaktionen für viele Quellen
- Export, Import und Backup

Die Überwachung läuft über **GitHub Actions**. Der Mac muss dafür nicht eingeschaltet sein.

---

# Architektur

## GitHub

Der GitHub-Watcher:

1. lädt `sources.json`
2. prüft alle aktuell fälligen Quellen
3. erkennt passende Artikel
4. vergleicht erkannte URLs mit dem bisherigen Tracking-Zustand
5. speichert neue Meldungen
6. aktualisiert RSS- und Themenfeeds
7. erzeugt Gesundheitsdaten
8. veröffentlicht die Feeds über GitHub Pages

Wichtige Dateien:

```text
watcher.js
sources.json

data/
  state.json
  items.json
  health.json

docs/
  feed.xml
  feeds/

.github/
  workflows/
    watch.yml
    build-macos-app.yml

mac-app/
  OMNewsWatcher/
  OMNewsWatcher.xcodeproj/
```

---

# macOS-App

Die macOS-App ist die Verwaltungsoberfläche für den Watcher.

Sie kann unter anderem:

- Quellen hinzufügen
- Quellen bearbeiten
- Quellen löschen
- Quellen pausieren
- Quellen testen
- alle Quellen testen
- Ordner zuweisen
- Schlagworte vergeben
- Relevanz festlegen
- Prüfintervalle festlegen
- visuelle Regeln einlernen
- problematische Regeln reparieren
- alte Regelstände wiederherstellen
- GitHub-Watcher manuell starten
- Reader öffnen
- Gesundheitsdaten anzeigen
- Quellen exportieren und importieren

Der GitHub-Zugriff erfolgt über ein Fine-Grained Personal Access Token.

**Das Token wird ausschließlich im macOS-Schlüsselbund gespeichert und gehört niemals ins Repository.**

---

# Quellenverwaltung

Jede Quelle kann unter anderem folgende Eigenschaften besitzen:

- Name
- URL
- Feed-Kennzeichnung
- Ordner
- Schlagwörter
- Relevanz
- aktiv / pausiert
- Prüfintervall
- optional nur Montag bis Freitag
- JavaScript-Wartezeit
- Abrufart
- Erkennungsregel
- URL-Filter
- visuell eingelernte Regel

Mögliche Prüfintervalle:

- 30 Minuten
- 1 Stunde
- 3 Stunden
- 6 Stunden
- 12 Stunden
- täglich
- wöchentlich

Ein manueller Lauf über **„Jetzt prüfen“** ignoriert die Intervalle und prüft alle aktiven Quellen.

---

# Ordner und Themen

Quellen können redaktionell in Ordner einsortiert werden, zum Beispiel:

- Events
- Finanzen
- Firmen
- Institute
- Logistik
- Quartalszahlen
- Research
- Staat
- Verbände
- Sonstiges

Die Ordner dienen sowohl der Organisation in der App als auch der Erzeugung eigener Themenfeeds.

---

# Visuelles Einlernen

Bei Webseiten ohne zuverlässigen RSS-Feed kann der gewünschte Artikelbereich direkt in der App eingelernt werden.

Ablauf:

1. Quelle öffnen
2. **„Visuell einlernen“**
3. Modus **„Links markieren“**
4. 2–3 echte Meldungen anklicken
5. App analysiert Struktur und Ziel-URLs
6. Regel validieren
7. Regel übernehmen
8. speichern

Die App versucht zunächst, stabile Kartenstrukturen zu erkennen.

Falls moderne Webseiten ihre DOM-Struktur dynamisch verändern, kann sie stattdessen ein gemeinsames URL-Muster aus den markierten Meldungen ableiten.

---

# Automatische Reparatur

Erkennt die App bei einem Test:

- zu viele Treffer
- keine Treffer
- Navigationslinks
- ungeeignete Seitenbereiche

kann sie eine engere Erkennungsregel vorschlagen.

Die vorgeschlagene Regel wird vor dem Speichern erneut getestet.

---

# Regel-Versionierung

Vor Änderungen an einer visuellen oder automatisch reparierten Regel wird der vorherige Zustand gespeichert.

Bis zu mehrere ältere Regelstände können vorgehalten werden.

Über:

**„Vorherige Regel“**

kann der letzte funktionierende Zustand wiederhergestellt werden.

---

# Regel-Debugger

Über:

**„Regel erklären“**

kann für eine Quelle nachvollzogen werden:

- welcher Selektor verwendet wird
- welcher URL-Filter aktiv ist
- welche Titellänge verlangt wird
- welche Abrufart verwendet wird
- welche Treffer der lokale Test liefert
- wie lange der Test dauert
- welche Gesundheitsdaten der GitHub-Watcher meldet

---

# Reader

OM News Watcher besitzt einen eigenen Reader.

Ansichten:

- **Neu & relevant**
- Posteingang
- Seit letztem Besuch
- Heute relevant
- Alle Meldungen
- Favoriten
- Archiv
- Ordner

## Neu & relevant

Die Standardansicht des Readers zeigt:

- ungelesene Meldungen
- nicht archivierte Meldungen
- mindestens 2 Relevanzsterne
- seit dem vorherigen Reader-Besuch neu erkannte Inhalte

Damit soll der Reader vor allem die Frage beantworten:

> Was ist seit meinem letzten Besuch neu und wirklich relevant?

---

# Tracking-Audit seit v5.1

Ab v5.1 werden zwei Zustände getrennt geführt:

```text
gesehen
ausgeliefert
```

Das ist wichtig, weil eine URL zwar auf einer Webseite erkannt worden sein kann, aber trotzdem nie im Reader gelandet sein könnte.

Intern werden deshalb unter anderem getrennt geführt:

```text
seenBySource
deliveredBySource
```

Dadurch kann OM News Watcher erkennen, wenn ein Artikel:

- auf der Quelle vorhanden ist
- bereits irgendwann erkannt wurde
- aber nie als Meldung gespeichert wurde

---

# Selbstheilung

OM News Watcher besitzt seit v5.1 eine automatische Selbstheilung.

Wenn ein Artikel:

- bereits als gesehen gilt
- nie ausgeliefert wurde
- und laut Veröffentlichungsdatum innerhalb der letzten 48 Stunden liegt

wird er nachträglich in den Reader übernommen.

Solche Meldungen werden intern als wiederhergestellt markiert.

Bewusst bei der erstmaligen Einrichtung einer Quelle unterdrückte Altmeldungen werden davon ausgeschlossen.

---

# Baseline-Verhalten

Neue Quellen benötigen einmalig einen Ausgangsbestand.

Beim ersten Lauf werden vorhandene Artikel deshalb als bekannte Ausgangsbasis gespeichert, ohne alle alten Meldungen in den Reader zu übernehmen.

Seit v5.1 gilt:

**Eine Änderung an einer Erkennungsregel löst keinen automatischen Baseline-Reset mehr aus.**

Damit kann ein Neueinlernen oder eine Regelreparatur nicht mehr versehentlich dazu führen, dass aktuelle Meldungen als bereits bekannt verschwinden.

---

# Quellen-Gesundheitsdashboard

Die App kann Gesundheitsinformationen des GitHub-Watchers anzeigen.

Unter anderem:

- letzter GitHub-Check
- letzter erfolgreicher Check
- letzter neuer Artikel
- Trefferzahl
- durchschnittliche Trefferzahl
- Laufzeit
- nächster Check
- Tracking-Status
- neuester erkannter Artikel
- neuester gespeicherter Artikel
- Anzahl automatischer Tracking-Reparaturen

---

# Trefferzahl-Anomalien

Der Watcher merkt sich die Trefferzahlen einer Quelle.

Er warnt unter anderem bei:

- plötzlich 0 Treffern
- ungewöhnlich starkem Rückgang
- ungewöhnlich starkem Anstieg

Damit lassen sich Layoutänderungen oder kaputte Erkennungsregeln schneller erkennen.

---

# Tracking-Warnungen

Zusätzlich zur reinen Trefferzahl kann der Watcher erkennen, wenn eine aktuelle Meldung zwar gefunden wurde, aber nicht korrekt ausgeliefert wurde.

Beispiel:

```text
⚠ 1 aktuelle Meldung erkannt, aber nicht ausgeliefert
```

Damit reicht ein grüner HTTP- oder Seitentest allein nicht mehr als Gesundheitsmerkmal aus.

---

# Mehrfachaktionen

Mehrere Quellen können gleichzeitig ausgewählt und bearbeitet werden.

Unter anderem:

- aktivieren
- pausieren
- testen
- Ordner zuordnen
- aus Ordner entfernen
- Schlagwort hinzufügen
- Relevanz setzen
- löschen

---

# Pausieren

Quellen können deaktiviert werden, ohne sie zu löschen.

Pausierte Quellen:

- bleiben in `sources.json`
- behalten ihre Regeln
- behalten ihre Ordner und Schlagworte
- werden vom automatischen Watcher nicht geprüft

---

# Feeds

Der zentrale Feed wird über GitHub Pages veröffentlicht.

Beispiel:

```text
https://callfrank.github.io/om-news-watcher/feed.xml
```

Zusätzlich können Themenfeeds erzeugt werden.

Sie liegen unter:

```text
docs/feeds/
```

und werden ebenfalls über GitHub Pages bereitgestellt.

---

# Export und Backup

Die App unterstützt:

- JSON-Export
- CSV-Export
- OPML
- vollständiges Backup
- Wiederherstellung

Das vollständige Backup kann unter anderem enthalten:

- Quellen
- Reader-Zustand
- App-Einstellungen
- GitHub-Verbindungsparameter

**Das GitHub-Token wird bewusst nicht exportiert.**

---

# GitHub Actions

## Automatischer Watcher

Workflow:

```text
.github/workflows/watch.yml
```

Aufgaben:

- Node.js vorbereiten
- Playwright / Chromium installieren
- Quellen prüfen
- RSS erzeugen
- Status speichern
- GitHub Pages aktualisieren

## macOS-App bauen

Workflow:

```text
.github/workflows/build-macos-app.yml
```

Die App wird automatisch auf GitHub gebaut.

Das fertige ZIP befindet sich anschließend unter:

```text
GitHub
→ Actions
→ Build OM News Watcher Mac
→ letzter erfolgreicher Lauf
→ Artifacts
```

---

# macOS Gatekeeper

Die automatisch erzeugte App ist derzeit nicht mit einer Apple Developer ID notarisiert.

Beim ersten Start kann macOS deshalb eine Sicherheitswarnung anzeigen.

Die App kann über die macOS-Sicherheitseinstellungen einmalig freigegeben werden.

---

# Typischer Update-Ablauf

Je nach Version müssen nicht immer dieselben Dateien ersetzt werden.

Bei Änderungen nur an der App:

```text
mac-app/
```

Bei Änderungen am eigentlichen Tracking zusätzlich:

```text
watcher.js
```

Nur wenn ausdrücklich angegeben:

```text
.github/workflows/watch.yml
```

**Nicht ohne ausdrücklichen Grund ersetzen oder löschen:**

```text
sources.json
data/state.json
data/items.json
```

Diese Dateien enthalten den produktiven Quellen- und Tracking-Zustand.

---

# Nach einem Watcher-Update

Empfohlener Ablauf:

1. Dateien nach GitHub hochladen
2. automatischen Mac-Build prüfen
3. GitHub-Watcher einmal manuell über **„Jetzt prüfen“** starten
4. erfolgreichen Lauf abwarten
5. in der App **„Neu laden“**
6. Gesundheitsdashboard kontrollieren
7. Reader auf neue Meldungen prüfen

---

# Wichtige Zustandsdateien

## sources.json

Konfiguration aller Quellen.

## data/state.json

Tracking-Zustand des Watchers.

Nicht löschen, wenn nicht ausdrücklich ein kompletter Neuaufbau beabsichtigt ist.

## data/items.json

Aktuell gespeicherte Reader-/Feed-Meldungen.

## data/health.json

Gesundheits- und Tracking-Audit-Daten.

---

# Sicherheit

Nicht ins Repository gehören:

- GitHub Personal Access Tokens
- Passwörter
- API-Schlüssel
- sonstige Zugangsdaten

Der GitHub-Token der macOS-App wird im Apple Schlüsselbund gespeichert.

---

# Ziel

OM News Watcher soll nicht nur ein Feedreader sein.

Das Ziel ist ein eigenständiges:

**Redaktions-, Quellen- und Monitoring-System**

mit dem Ablauf:

```text
Quellen überwachen
        ↓
neue Inhalte erkennen
        ↓
Tracking prüfen
        ↓
Probleme automatisch erkennen
        ↓
relevante Meldungen priorisieren
        ↓
im Reader redaktionell bearbeiten
```

---


## Hotfix v5.1.2 – frischer Remote-Abruf

v5.1.2 behebt den Fall, dass der lokale Mac bereits neue Inhalte sieht,
während ein Remote-Runner noch eine gecachte ältere Version derselben
Startseite erhält.

Der GitHub-Watcher verwendet nun zusätzlich:

- `Cache-Control: no-cache, no-store`
- `Pragma: no-cache`
- einen zufälligen Cache-Busting-Parameter bei HTML-/Browser-Aufrufen
- blockierte Service Worker im Playwright-Kontext
- bei Startseiten automatisch einen RSS-/Atom-Zweitkanal, sofern verfügbar
- zusätzlich einen Versuch über `/feed/` bei Startseiten

Browser- und Feed-Treffer werden zusammengeführt. Feed-Einträge stehen bei
der Aktualitätsbewertung vor den HTML-Treffern.

`data/health.json` enthält außerdem die tatsächlich gelaufene
`watcherVersion`. Die macOS-App zeigt App-, Watcher- und Tracking-Version an.

## Hotfix v5.1.1

v5.1.1 korrigiert zwei Fehler der ersten v5.1-Tracking-Migration:

- `items.json` ist nun die maßgebliche Wahrheit dafür, ob eine Meldung
  tatsächlich im Reader angekommen ist.
- Aktuelle Artikel, die auf der Webseite erkannt werden, aber in
  `items.json` fehlen, werden innerhalb eines 48-Stunden-Fensters
  selbstheilend nachgeliefert.
- Frühere `seenBySource`- oder `deliveredBySource`-Einträge können eine
  fehlende Reader-Meldung nicht mehr dauerhaft verschlucken.
- Historische Artikel, die erst deutlich später entdeckt wurden, werden als
  `historicalBackfill` markiert.
- Historische Backfills erscheinen nicht in „Neu & relevant“,
  „Posteingang“, „Seit letztem Besuch“ oder „Heute relevant“.
- „Alle Meldungen“ behält sie zur Nachvollziehbarkeit.
- Im Reader wird primär das Veröffentlichungsdatum angezeigt; der
  Erkennungszeitpunkt bleibt in den Details verfügbar.
- Wiederhergestellte aktuelle Meldungen werden als „🩹 Wiederhergestellt“
  gekennzeichnet.

## Version

**OM News Watcher v5.1.2**

Tracking-Audit, items.json-basierte Selbstheilung, Schutz vor historischen Fehl-Backfills, Quellen-Gesundheit, Regel-Versionierung, visueller Trainer und integrierter Reader.
