#!/usr/bin/env bash
# install-dependencies.sh
# Liest alle *executables.json in config/, installiert Pakete & JARs
# und startet rekursiv weitere install-dependencies-Skripte in vendor/.

set -euo pipefail

###############################################################################
# 0 - Rekursions-Schutz
###############################################################################
if [[ -n "${INSTALL_DEPS_RUNNING:-}" ]]; then
  exit 0
fi
export INSTALL_DEPS_RUNNING=1

###############################################################################
# 1 - Verzeichnisse & Werkzeuge
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$SCRIPT_DIR/../config}"      # override moeglich
JQ=$(command -v jq) || { echo "jq noetig - sudo apt install jq"; exit 1; }

###############################################################################
# 2 - Alle *executables.json einsammeln
###############################################################################
mapfile -t CONFIG_FILES < <(find "$CONFIG_DIR" -maxdepth 1 -name '*executables.json' -type f | sort)
if ((${#CONFIG_FILES[@]}==0)); then
  echo "Keine executables.json-Dateien in $CONFIG_DIR gefunden."
  exit 1
fi

echo "Gefundene Konfig-Dateien:"
printf '  * %s\n' "${CONFIG_FILES[@]}"

###############################################################################
# 3 - Pakete installieren (apt, pip, pipx, npm, etc.)
###############################################################################
declare -A SEEN_PKG
sudo apt-get update            # einmal zu Beginn

# Hilfsfunktion: Installer sicherstellen
ensure_installer() {
  local installer="$1"
  case "$installer" in
    pipx)
      if ! command -v pipx &>/dev/null; then
        echo "pipx nicht gefunden - installiere pipx..."
        sudo apt-get install -y pipx || sudo pip3 install pipx
        pipx ensurepath 2>/dev/null || true
      fi
      ;;
    pip|pip3)
      if ! command -v pip3 &>/dev/null; then
        echo "pip3 nicht gefunden - installiere python3-pip..."
        sudo apt-get install -y python3-pip
      fi
      ;;
    npm)
      if ! command -v npm &>/dev/null; then
        echo "npm nicht gefunden - installiere nodejs npm..."
        sudo apt-get install -y nodejs npm
      fi
      ;;
  esac
}

# Hilfsfunktion: Paket mit Installer installieren
install_package() {
  local installer="$1"
  local package="$2"
  local path="$3"

  # Pruefen ob bereits installiert (via path)
  if [[ -n "$path" ]] && command -v "$path" &>/dev/null; then
    echo "  [OK] $package bereits installiert ($path)"
    return 0
  fi

  case "$installer" in
    apt|apt-get|"")
      if ! dpkg -s "$package" &>/dev/null; then
        echo "  [apt] Installiere: $package"
        sudo apt-get install -y "$package" || echo "!!! $package nicht verfuegbar !!!"
      fi
      ;;
    pip|pip3)
      ensure_installer pip
      if ! pip3 show "$package" &>/dev/null; then
        echo "  [pip] Installiere: $package"
        pip3 install --user "$package" || sudo pip3 install "$package"
      fi
      ;;
    pipx)
      ensure_installer pipx
      if ! pipx list 2>/dev/null | grep -q "$package"; then
        echo "  [pipx] Installiere: $package"
        pipx install "$package"
      fi
      ;;
    npm)
      ensure_installer npm
      if ! npm list -g "$package" &>/dev/null; then
        echo "  [npm] Installiere: $package"
        sudo npm install -g "$package"
      fi
      ;;
    *)
      echo "  [WARN] Unbekannter Installer: $installer fuer $package"
      ;;
  esac
}

# Alle Executable-Sektionen durchgehen
SECTIONS="shellExecutables pythonExecutables nodeExecutables"

for cfg in "${CONFIG_FILES[@]}"; do
  echo "Verarbeite: $cfg"
  for section in $SECTIONS; do
    # Pruefen ob Sektion existiert und Eintraege hat
    count=$(jq -r --arg sec "$section" '(.[$sec]? // {}) | length' "$cfg")
    if [[ "$count" -gt 0 ]]; then
      echo "  Sektion: $section ($count Eintraege)"
    fi
    
    # Process substitution statt Pipe um SEEN_PKG zu erhalten
    while IFS=$'\t' read -r installer package path; do
      [[ -z "$package" ]] && continue
      # Mehrere Pakete (Space-getrennt) unterstuetzen
      for pkg in $package; do
        if [[ -n "${SEEN_PKG[$pkg]:-}" ]]; then
          continue
        fi
        SEEN_PKG["$pkg"]=1
        install_package "$installer" "$pkg" "$path"
      done
    done < <(jq -r --arg sec "$section" '
      (.[$sec]? // {}) | to_entries[] |
      [.value.installer // "apt", .value.packageDeb // .value.package, .value.path] | @tsv
    ' "$cfg")
  done
done

###############################################################################
# 4 - Java-Executables herunterladen
###############################################################################
declare -A SEEN_JAR
for cfg in "${CONFIG_FILES[@]}"; do
  jq -r '.javaExecutables? // {} | to_entries[] | select(.value.url? and .value.path?) | [.value.url, .value.path] | @tsv
  ' "$cfg" | while IFS=$'\t' read -r url target; do
    [[ -n "${SEEN_JAR[$target]:-}" ]] && continue
    SEEN_JAR["$target"]=1
    if [[ ! -f "$target" ]]; then
      echo "Lade $url -> $target ..."
      sudo curl -L -o "$target" "$url"
      sudo chmod +x "$target"
    else
      echo "$target bereits vorhanden"
    fi
  done
done

###############################################################################
# 5 - weitere install-dependencies.sh in vendor/ ausfuehren
###############################################################################
# 5.1  Projekt-Root ermitteln - steige solange nach oben, bis ein vendor/-Ordner
#      gefunden wird oder / erreicht ist.
ROOT="$SCRIPT_DIR"
while [[ "$ROOT" != "/" && ! -d "$ROOT/vendor" ]]; do
  ROOT="$(dirname "$ROOT")"
done

VENDOR_DIR="$ROOT/vendor"
if [[ -d "$VENDOR_DIR" ]]; then
  echo "Suche in $VENDOR_DIR nach weiteren install-dependencies-Skripten ..."
  while IFS= read -r other_script; do
    # Eigene Datei ueberspringen
    if [[ "$(realpath "$other_script")" != "$(realpath "$SCRIPT_DIR/install-dependencies.sh")" ]]; then
      echo "--------------------------------------------------------------"
      echo "Starte abhaengiges Skript: $other_script"
      bash "$other_script"
      echo "Fertig: $other_script"
      echo "--------------------------------------------------------------"
    fi
  done < <(find "$VENDOR_DIR" -maxdepth 5 -type f -name 'install-dependencies.sh')
fi

echo "Alle definierten Abhaengigkeiten wurden geprueft und installiert."
