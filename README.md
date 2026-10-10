# install-dependencies

Kleines Bash‑Skript, das die Datei `config/executables.json` einliest und automatisch fehlende Linux‑Pakete (APT) sowie Java‑Executables installiert bzw. herunterlädt.

## Funktionsweise

* **Pfad‑Auflösung** – Das Skript liegt in `scripts/install.sh` und sucht per relativer Navigation nach `../config/executables.json`.
* **Requirement Check** – stellt sicher, dass [`jq`](https://stedolan.github.io/jq/) installiert ist.
* **shellExecutables** – für jeden Eintrag mit Schlüssel `package` wird geprüft, ob das Debian‑/Ubuntu‑Paket bereits vorhanden ist; fehlende Pakete werden via `sudo apt-get install -y <package>` nachinstalliert.
* **javaExecutables** – enthält Paare aus `url` und `path`. Existiert die Zieldatei nicht, lädt das Skript die Datei per `curl -L -o <path> <url>` herunter, prüft die ZIP/JAR-Magic-Bytes und setzt die Ausführungsrechte (`chmod +x`). Relative `path`-Angaben werden relativ zum Repo der jeweiligen Config aufgelöst (`config/..`), nicht zum Aufruf-Verzeichnis.
* **install** (Feld an einem `shellExecutables`-Eintrag) – für Werkzeuge, die weder apt noch eine einzelne JAR liefern. Ein eigener Abschnitt geht nicht, weil der Config-Loader an jedem Eintrag ein `path` verlangt. Das Objekt hat `type` (`tarball` oder `izpack`), `url`, optional `sha256` (Download wird bei Abweichung verworfen), `arch` (z. B. `x86_64`, andere Rechner überspringen den Eintrag) sowie `version` und `versionCommand` (liefert der Befehl die Version, ist nichts zu tun). `tarball` kopiert `member` aus dem Archiv nach `target` (0755). `izpack` entpackt das ZIP, startet das IzPack-Installer-JAR unbeaufsichtigt nach `installPath` (Java wird bei Bedarf als `default-jre-headless` installiert) und legt die Symlinks aus `links` an. Wie bei den JARs gibt es keinen `required`-Filter; Fehler setzen nur eine Warnung.
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
  },
  "shellExecutables-mit-install (Beispiel, gleiche Sektion wie oben)": {
    "pdfcraft-cli": {
      "path": "pdfcraft-cli",
      "install": {
        "type": "tarball",
        "url": "https://github.com/storytold/pdfcraft/releases/tag/v0.5.0",
        "assetPattern": "pdfcraft-cli-*-linux-x86_64.tar.gz",
        "sha256": "9fe5d1ef82924667184d68dc6aea2f23c98bdcd4d3802327c8cf17cc5d9da72b",
        "arch": "x86_64",
        "member": "pdfcraft-cli-0.5.0-linux-x86_64/pdfcraft-cli",
        "target": "/usr/local/bin/pdfcraft-cli",
        "version": "0.5.0",
        "versionCommand": "pdfcraft-cli --version"
      }
    },
    "verapdf": {
      "path": "verapdf",
      "install": {
        "type": "izpack",
        "url": "https://software.verapdf.org/releases/1.30/verapdf-greenfield-1.30.3-installer.zip",
        "sha256": "b512bf24945503a33fc10738ecffc1f2dccaaf8593a448e94ee9ac86a9559a59",
        "installPath": "/opt/verapdf",
        "links": { "/usr/local/bin/verapdf": "/opt/verapdf/verapdf" },
        "version": "1.30.3",
        "versionCommand": "verapdf --version"
      }
    }
  }
}
```

> **Hinweis:** `config/executables.json` kannst du beliebig erweitern. Teile ohne `package` (bei `shellExecutables`), ohne `url` oder `path` (bei `javaExecutables`) bzw. `install`-Objekte ohne `type` oder `url` werden ignoriert.

### Lizenz

MIT
