# install-dependencies

Kleines Bash‑Skript, das die Datei `config/executables.json` einliest und automatisch fehlende Linux‑Pakete (APT) sowie Java‑Executables installiert bzw. herunterlädt.

## Funktionsweise

* **Pfad‑Auflösung** – Das Skript liegt in `scripts/install.sh` und sucht per relativer Navigation nach `../config/executables.json`.
* **Requirement Check** – stellt sicher, dass [`jq`](https://stedolan.github.io/jq/) installiert ist.
* **shellExecutables** – für jeden Eintrag mit Schlüssel `package` wird geprüft, ob das Debian‑/Ubuntu‑Paket bereits vorhanden ist; fehlende Pakete werden via `sudo apt-get install -y <package>` nachinstalliert.
* **javaExecutables** – enthält Paare aus `url` und `path`. Existiert die Zieldatei nicht, lädt das Skript die Datei per `curl -L -o <path> <url>` herunter, prüft die ZIP/JAR-Magic-Bytes und setzt die Ausführungsrechte (`chmod +x`). Relative `path`-Angaben werden relativ zum Repo der jeweiligen Config aufgelöst (`config/..`), nicht zum Aufruf-Verzeichnis.
* **GitHub-Releases** – zeigt `url` auf eine GitHub-Release-Seite (`…/releases`, `…/releases/latest` oder `…/releases/tag/<tag>`), wird das passende Asset automatisch über die GitHub-API aufgelöst. Die Asset-Auswahl steuert das optionale Feld `assetPattern` (Glob auf den Asset-Dateinamen, Default `*.jar`). Direkte Download-URLs (auch `…/releases/download/…`) werden unverändert genutzt. Gegen API-Rate-Limits kann die Umgebungsvariable `GITHUB_TOKEN` gesetzt werden.

## Voraussetzungen

* Debian/Ubuntu-basiertes System mit `apt`
* Bash ≥ 4
* `jq` (Installationshinweis: `sudo apt install jq`)

## Verwendung

```bash
# Skript ausführbar machen (nur einmal erforderlich)
chmod +x install-dependencies.sh

# Ausführen
./install-dependencies.sh
```

### Beispiel-`executables.json`

```json
{
  "shellExecutables": {
    "git":  { "package": "git" },
    "jq":   { "package": "jq" }
  },
  "javaExecutables": {
    "plantuml": {
      "url": "https://github.com/plantuml/plantuml/releases/download/v1.2025.2/plantuml-1.2025.2.jar",
      "path": "/usr/local/bin/plantuml.jar"
    },
    "kosit-validator": {
      "url": "https://github.com/itplr-kosit/validator/releases",
      "assetPattern": "*-standalone.jar",
      "path": "tools/kosit/validator.jar"
    }
  }
}
```

> **Hinweis:** `config/executables.json` kannst du beliebig erweitern. Teile ohne `package` (bei `shellExecutables`) bzw. ohne `url` oder `path` (bei `javaExecutables`) werden ignoriert.

### Lizenz

MIT
