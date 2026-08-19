# OM News Watcher

**OM News Watcher** ist ein eigenes News-, Presse- und Website-Monitoring-System für macOS und GitHub Actions.

Es überwacht definierte Webseiten auf neue Meldungen, Pressemitteilungen, Studien, Events, Quartalszahlen und andere relevante Veröffentlichungen. Die macOS-App dient dabei als Verwaltungs-, Prüf- und Reader-Oberfläche; die eigentliche automatische Überwachung läuft unabhängig davon über GitHub Actions.

**Aktueller Stand: v5.3.5**

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












## v5.3.6 Infra-Hotfix – kein Chromium-Install mehr in GitHub Actions

Der GitHub-Workflow installiert Chromium und Ubuntu-Systempakete nicht mehr
bei jedem Lauf neu.

Stattdessen verwendet der Watcher auf `ubuntu-24.04` den dort bereits
vorinstallierten Google-Chrome-Browser über den Playwright-Channel `chrome`.

Dadurch entfällt der bisherige Schritt:

```text
npx playwright install chromium --with-deps
```

und damit auch die Abhängigkeit von `apt`/Ubuntu-Paketservern während jedes
Watcher-Laufs.

### Versionen

- macOS-App: **5.3.5** unverändert
- Watcher: **0.31**
- Workflow: **v5.3.6 Infra-Hotfix**

## v5.3.5 – robuster Selector-Fallback

v5.3.5 beseitigt die letzte harte Abhängigkeit visueller Regeln von einem
einzelnen CSS-Kandidatenselektor.

Wenn eine visuell gelernte oder per `includeRegex` eingegrenzte Quelle nach
einem vollständigen Reload mit dem engen `candidateSelector` 0 Treffer
liefert, erfolgt automatisch ein zweiter Durchlauf über alle klickbaren
DOM-Elemente.

Wichtig: Der breite Scan ist kein ungefilterter Import. Danach greifen
weiterhin:

- `includeRegex`
- Visual-Sample-Shape
- Artikel-/URL-Qualitätsregeln
- News-Eligibility-Gate

Der Mac-Schnelltest meldet in diesem Fall ausdrücklich:

`Selektor-Fallback: Treffer über breiten DOM-Scan + URL-Regel reproduziert.`

Der GitHub-Watcher protokolliert:

`Selector-Fallback: enger Selektor 0 Treffer, breiter DOM-Scan N Treffer.`

### Versionen

- macOS-App: **5.3.5**
- Watcher: **0.30**
- Tracking-/Health-Schema: **3**

## v5.3.4 – visuelles Einlernen: identische Klicklogik

v5.3.4 behebt einen Unterschied zwischen visuellem Trainer, Schnelltest und
GitHub-Watcher. Der Trainer konnte bereits Meldungskarten erkennen, deren
Ziel über `onclick` oder `data-*` hinterlegt ist. Test und Watcher waren an
dieser Stelle enger und konnten dieselben Karten nach einem Reload deshalb
mit 0 Treffern bewerten.

Ab v5.3.4 verwenden Trainer, Schnelltest und Watcher dieselbe Menge klickbarer
Elemente:

- `a[href]`
- `data-href`
- `data-url`
- `data-link`
- `[role="link"]`
- `button[onclick]`
- beliebige `[onclick]`-Elemente

Das aus den markierten Beispielen erzeugte Kandidatenmuster wird außerdem
nicht mehr ausschließlich als `a[href*="..."]` gespeichert, sondern kann
denselben Pfad auch in `data-*`- und `onclick`-Attributen erkennen.

### Versionen

- macOS-App: **5.3.4**
- Watcher: **0.29**
- Tracking-/Health-Schema: **3**

## v5.3.3 – Build-Hotfix für den Regel-Debugger

v5.3.3 korrigiert einen Swift-Compilerfehler aus v5.3.1/v5.3.2.

Im `RuleDebuggerView` wurde noch die alte Eigenschaft

```text
health.displayHitCount
```

verwendet. Das neue Health-Modell nutzt seit v5.3.1 getrennte Werte für
technisch erkannte und Reader-fähige Treffer. Der Debugger verwendet nun
`health.displayTechnicalCount`.

Zusätzlich bleibt `displayHitCount` als kompatibler Alias erhalten, damit
weitere ältere View-Bestandteile nicht erneut denselben Buildfehler auslösen.

### Versionen

- macOS-App: **5.3.3**
- Watcher: **0.28** unverändert
- Tracking-/Health-Schema: **3**

## v5.3.2 – visuelles Einlernen und undatierte Fehltreffer

v5.3.2 korrigiert zwei Fehler, die unter anderem bei DeliveryHero sichtbar
wurden.

### 1. Undatierte Bereichsseiten sind nicht automatisch News

Bisher konnte ein technisch erkannter Link ohne Veröffentlichungsdatum als
aktuelle Meldung gelten. Dadurch konnten beispielsweise Bereiche wie
`Publikationen`, `IPO Mitteilungen`, `Wertpapierprospekt` oder
`Diversity & Inclusion` als Reader-fähig erscheinen.

Ab v5.3.2 gilt:

- ein vorhandenes Veröffentlichungsdatum wird weiterhin mit dem 48-Stunden-
  Fenster geprüft;
- ohne Datum muss die Ziel-URL ein starkes Artikelsignal besitzen;
- typische Investor-Relations-, Publikations-, IPO- und Prospectus-
  Übersichtsseiten werden verworfen;
- fehlerhaft zusammengesetzte URLs wie `/de/https://...` werden verworfen.

### 2. Datum wird auch aus dem Kartentext erkannt

Einige Webseiten zeigen das Veröffentlichungsdatum zwar sichtbar in der
Meldungskarte, verwenden dafür aber weder `<time>` noch eine CSS-Klasse mit
`date` oder `published`.

Watcher, Schnelltest und visueller Trainer suchen deshalb zusätzlich direkt
im Kartentext nach Datumsformaten wie:

- `13.08.2026`
- `2026-08-13`
- `13. August 2026`
- `August 13, 2026`

Damit kann das Eligibility-Gate ältere Karten zuverlässig als Altbestand
erkennen.

### 3. Visuelles Einlernen bekommt einen reload-sicheren Fallback

Das visuelle Einlernen validiert die gewählte Regel weiterhin nach einem
vollständigen Reload. Wenn ein enger CSS-Selector wie
`a[href*="/de/nachrichten/"]` nach dem Reload nicht stabil reproduzierbar ist,
wird zusätzlich eine Variante getestet, die zunächst alle klickbaren Links
liest und erst danach das aus den markierten Beispielen gebildete URL-Muster
anwendet.

Der Button heißt deshalb jetzt bewusst:

`Regel prüfen & übernehmen`

Eine Regel wird weiterhin erst gespeichert, wenn sie nach einem vollständigen
Reload technisch reproduzierbar ist.

### Versionen

- macOS-App: **5.3.2**
- Watcher: **0.28**
- Tracking-/Health-Schema: **3**

## v5.3.1 – Quellen-Gesundheit nach technischer und redaktioneller Realität

Das Gesundheitsdashboard unterscheidet ab v5.3.1 zwischen einem technischen
Fehler und dem völlig normalen Fall, dass eine funktionierende Quelle aktuell
keine neue Reader-fähige Meldung liefert.

### Neue Gesundheitsstufen

- **Gesund** – Quelle funktioniert und liefert Reader-fähige Kandidaten.
- **Keine neue Meldung** – technischer Abruf funktioniert, aber aktuell ist
  nichts Reader-fähig. Dieser Zustand ist **keine Warnung**.
- **Auffällig** – Trefferzahl weicht deutlich vom historischen Niveau ab oder
  das Tracking meldet eine Inkonsistenz.
- **Fehler** – Timeout, HTTP-/Browserfehler oder ein anderer technischer
  Abruffehler.
- **Übersprungen/Pausiert** – eigener neutraler Zustand.

### Getrennte Trefferzahlen

Das Dashboard zeigt nun getrennt:

- **Technisch** – wie viele passende Artikelkandidaten der Watcher auf der
  Quelle erkannt hat.
- **Reader** – wie viele davon das News-Eligibility-Gate tatsächlich als
  aktuelle Meldung akzeptiert.
- verworfene Kandidaten erscheinen beim Reader-Wert als `−N`.

Ein funktionierendes BMJ kann damit beispielsweise korrekt als

```text
5 technisch · 0 Reader-fähig · Keine neue Meldung
```

erscheinen, ohne eine Warnung zu erzeugen.

### Zero-Hit ist nicht automatisch kaputt

Ein erfolgreicher Abruf mit `0` passenden Artikeln erzeugt nicht mehr
automatisch `Keine Artikel erkannt` als Warnung. Erst wenn die Trefferzahl
gegenüber einer belastbaren Historie auffällig einbricht, wird daraus eine
Trefferzahl-Anomalie.

`Letzter Erfolg` wird jetzt bei jedem technisch erfolgreichen Abruf
aktualisiert – auch bei 0 Reader-fähigen Meldungen.

### Tracking-Reparaturen

Der Health-Report führt zusätzlich `healedTodayCount`. Im Dashboard steht
deshalb **Reparaturen heute** statt nur des wenig hilfreichen kumulierten
Gesamtwerts. Der Gesamtzähler bleibt in den Quelldetails weiterhin sichtbar.

### Versionen

- macOS-App: **5.3.1**
- Watcher: **0.27**
- Health-/Tracking-Schema: **3**

## v5.3.0 – News-Eligibility-Gate

v5.3.0 trennt erstmals konsequent zwischen **technisch erkannt** und
**tatsächlich als aktuelle Nachricht auslieferbar**.

Das behebt insbesondere Fälle wie das BMJ: Eine Erkennungsregel kann korrekt
mehrere Dokumentseiten finden, trotzdem dürfen alte Gesetzgebungsverfahren,
Broschüren, Ratgeber oder HTML-/SVG-Artefakte nicht als neue Reader-Meldung
erscheinen.

### GitHub-Watcher v0.26

Vor dem Speichern in `data/items.json` gilt zusätzlich zum Quality Gate nun
ein News-Eligibility-Gate:

- belastbares Veröffentlichungsdatum älter als 48 Stunden → nicht als neue
  Meldung speichern
- zukünftiges/unplausibles Datum → nicht ausliefern
- `/SharedDocs/Publikationen/` → statische Publikation, nicht News
- Broschüren-/Ratgeber-/Guide-Pfade → nicht News
- CSS-/SVG-Fragmente wie `.st0{fill:none;stroke:...}` → Artefakt, kein Titel
- „Broschüren und Infomaterial“ → Übersichtsseite, keine Meldung

Wichtig: Eine URL kann damit weiterhin technisch erkannt werden, ohne jemals
Reader, RSS oder E-Mail zu erreichen.

Beim Start wird `lastStoredBySource` aus dem bereinigten `items.json` neu
aufgebaut. Alte Artefakte verschwinden dadurch auch aus dem
Gesundheitsdashboard.

### Quellentest in der macOS-App

Der lokale Test zeigt jetzt drei getrennte Werte:

- **technisch erkannt**
- **Reader-fähig**
- **verworfen**

Verworfene Beispieltreffer erhalten einen Grund, z. B.:

- Altbestand – Veröffentlichung älter als 48 Stunden
- Statische Publikation/Ratgeberseite
- Übersichts-/Publikationsseite statt News
- HTML/SVG-Artefakt statt Überschrift

Eine technisch funktionierende Quelle mit ausschließlich altem Bestand wird
nicht mehr als Problemquelle behandelt, sondern als
**„Quelle funktioniert – aktuell keine neue Meldung“**.

### Toolbar

Der missverständliche Button **„Jetzt prüfen“** heißt nun
**„Alle Quellen prüfen“**.

## v5.2.1 – begrenzter aktiver Reader-Verlauf

Der Reader soll ein Arbeitsbereich und kein dauerhaft wachsendes Protokoll
sein. Gelesene Meldungen bleiben deshalb nicht mehr unbegrenzt grau in
`Alle Meldungen` und in Ordneransichten sichtbar.

Unter **Einstellungen → Reader** kann festgelegt werden, wie lange gelesene
Meldungen im aktiven Verlauf sichtbar bleiben:

- Nur heute
- 1 Tag (Standard)
- 3 Tage
- 7 Tage
- 14 Tage
- 30 Tage

Unabhängig davon bleiben immer sichtbar:

- ungelesene Meldungen
- Favoriten
- explizit archivierte Meldungen im Archiv

Der GitHub-Watcher begrenzt `data/items.json` bereits auf maximal 500
Tracking-Einträge. Die neue Reader-Frist verhindert zusätzlich, dass der
aktive Arbeitsbereich mit erledigten grauen Meldungen vollläuft.

## v5.2.0 – ein gemeinsamer Quality Gate für Watcher, RSS und Reader

v5.2.0 behebt die strukturelle Abweichung zwischen Feedly und der macOS-App.
Bisher konnte `docs/feed.xml` Roh-/Alt-Treffer enthalten, die der Reader erst
später ausblendete. Dadurch zeigte Feedly andere und teilweise wiederholte
Meldungen als die App.

### Wichtige Korrekturen

- Cache-Busting (`_omw_fresh`) wird beim Kanonisieren einer Artikel-URL immer
  entfernt und kann deshalb keine neue GUID mehr erzeugen.
- bereits gespeicherte cache-busted URLs werden beim nächsten Lauf
  kanonisiert und dedupliziert.
- `Main Menu`, `Who we are`, `Find us on`, Fehlerbehebungs-/Update-Seiten,
  `Seite 2`, `Seite 3` usw. werden als hochsichere Fehltreffer verworfen.
- statische Bereiche wie Datenschutz, Kontakt, Karriere, Preise, Entwickler-
  und Produktseiten werden ohne Veröffentlichungsdatum nicht als News
  gespeichert.
- das Quality Gate läuft **vor `data/items.json`**.
- das gleiche Gate läuft zusätzlich direkt vor der RSS-Erzeugung. Feedly kann
  damit nicht mehr ungefilterte Rohdaten bekommen.
- vorhandene Fehltreffer werden beim nächsten Watcher-Lauf aus `items.json`
  entfernt; legitime Meldungen bleiben erhalten.
- `Neu & relevant` bedeutet jetzt ausschließlich: ungelesen, nicht archiviert,
  nicht historisch, mindestens 2 Sterne und aktuell. Der letzte Reader-Besuch
  beeinflusst diese Ansicht nicht mehr.
- `Seit letztem Besuch` bleibt die einzige Ansicht, die den letzten Besuch als
  Kriterium verwendet.

### Hinweis zu Feedly

Bereits von Feedly früher eingelesene Fehltreffer können durch eine spätere
RSS-Bereinigung nicht aus Feedlys Historie gelöscht werden. Entscheidend ist,
dass ab v5.2.0 keine neuen Wiederholungen dieser Fehltreffer mehr erzeugt
werden. Alte Feedly-Einträge können einmalig als gelesen markiert werden.

## v5.1.3 – Reader und E-Mail verwenden dieselbe Relevanzlogik

Die E-Mail-Benachrichtigung zählt nicht mehr einfach alle noch nie
versendeten Datensätze aus `data/items.json`.

Vor einer Mail werden die Meldungen nun mit derselben Grundlogik wie im
integrierten Reader aufbereitet:

- Navigationstexte und generische Schaltflächen werden entfernt
- Quellenseiten selbst werden nicht als Meldung gewertet
- doppelte Links und doppelte Titel werden entfernt
- sehr ähnliche Meldungen verschiedener Quellen werden zusammengeführt
- Relevanz muss mindestens 2 Sterne betragen
- `historicalBackfill` wird ausgeschlossen
- verlässliche Veröffentlichungsdaten müssen innerhalb des aktuellen
  48-Stunden-Fensters liegen
- bei Quellen ohne Publikationsdatum wird ersatzweise der echte
  Erkennungszeitpunkt verwendet

### Reader-Aktivität wird berücksichtigt

Die macOS-App schreibt einen kleinen Zustand nach:

```text
reader-state.json
```

Gespeichert wird ausschließlich der Zeitpunkt der letzten Reader-Aktivität,
keine Zugangsdaten und kein Artikelinhalt.

Der Zeitpunkt wird aktualisiert, wenn:

- der Reader geöffnet wird
- eine Meldung als gelesen/ungelesen markiert wird
- Favoriten verändert werden
- archiviert oder wiederhergestellt wird
- mehrere Meldungen als gelesen markiert werden

Die Schreibvorgänge werden gebündelt (Debounce), damit nicht für jeden Klick
ein GitHub-Commit entsteht.

Die E-Mail überspringt anschließend Meldungen, die bereits vorhanden waren,
als der Reader zuletzt angesehen oder bedient wurde. Damit kann eine
verspätete Sammelmail keinen alten Reader-Bestand erneut als neue Meldungen
verschicken.

### Neue Betreffzeile

Statt:

```text
OM News Watcher – 51 neue Treffer
```

lautet die Mail künftig beispielsweise:

```text
OM News Watcher – 2 neue relevante Meldungen
```

Optional wird darunter transparent zusammengefasst, wie viele weitere
Änderungen verworfen wurden, etwa:

```text
49 weitere Änderungen nicht gemeldet
42 bereits im Reader gesehen · 4 Altbestand/nicht aktuell ·
3 Navigation/Duplikate/Fehltreffer
```

### E-Mail-Zustand

`data/email-state.json` unterscheidet nun zwischen tatsächlich versendeten
und bereits anderweitig verarbeiteten Meldungen. Dadurch tauchen gefilterte
Alt- oder Fehltreffer in späteren Sammelmails nicht erneut auf.

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

**OM News Watcher v5.3.5**

Tracking-Audit, items.json-basierte Selbstheilung, Schutz vor historischen Fehl-Backfills, Quellen-Gesundheit, Regel-Versionierung, visueller Trainer und integrierter Reader.
