# OM News Watcher – Prototyp

Ein kleiner Website-Watcher für News-/Presse-Seiten, die in Feedly keinen brauchbaren RSS-Feed anbieten oder ihre Inhalte per JavaScript laden.

## Was er macht

1. GitHub Actions startet automatisch Chromium über Playwright.
2. Die konfigurierten Websites werden wie in einem echten Browser geladen.
3. Bereits bekannte Artikel-URLs werden gespeichert.
4. Nur neu erkannte URLs werden dem RSS-Feed hinzugefügt.
5. GitHub Pages veröffentlicht `docs/feed.xml`, damit Feedly den Feed abonnieren kann.

Beim **ersten Lauf** werden vorhandene Artikel nur als bekannt gespeichert. Dadurch wird Feedly nicht mit alten Meldungen geflutet.

## Einrichtung bei GitHub

### 1. Repository anlegen

Auf GitHub ein neues Repository erstellen, z. B. `om-news-watcher`.

Für den einfachsten Prototypen: **Public** wählen. Dadurch sind allerdings auch `sources.json` und damit die beobachteten Quellen öffentlich sichtbar. Keine Passwörter oder Zugangsdaten eintragen.

### 2. Dateien hochladen

Den Inhalt des Ordners `om-news-watcher` vollständig in das Repository hochladen. Wichtig: auch der versteckte Ordner `.github/workflows/` muss vorhanden sein.

Auf dem Mac blendest du versteckte Dateien im Finder mit **Cmd + Shift + .** ein.

### 3. GitHub Pages aktivieren

Im Repository:

**Settings → Pages → Build and deployment → Source: GitHub Actions**

### 4. Ersten manuellen Lauf starten

Im Repository auf **Actions → OM News Watcher → Run workflow** gehen.

Automatisch läuft der Watcher danach zweimal pro Stunde, ungefähr um Minute 17 und 47.

### 5. Feed in Feedly abonnieren

Nach einem erfolgreichen Lauf ist der Feed typischerweise erreichbar unter:

`https://DEIN-GITHUB-NAME.github.io/om-news-watcher/feed.xml`

Diese URL in Feedly hinzufügen.

## Erste Website eintragen

`sources.json` bearbeiten:

```json
[
  {
    "name": "Name der Quelle",
    "url": "https://www.beispiel.de/news",
    "enabled": true,
    "waitMs": 2500,
    "selectors": {
      "item": "",
      "title": "",
      "link": "",
      "date": ""
    }
  }
]
```

Die Selektoren dürfen zunächst leer bleiben. Dann versucht der Watcher automatisch, Artikel-Links zu erkennen.

Für schwierige Seiten können später gezielte CSS-Selektoren gesetzt werden.

## Was Version 0.1 bewusst noch nicht macht

- Login-geschützte Seiten
- Captcha-Umgehung
- Cloudflare-Schutz umgehen
- Volltexte kopieren
- KI-Relevanzbewertung
- grafische Verwaltungsoberfläche

Der Feed enthält bewusst nur Titel, Quelle und Link.
