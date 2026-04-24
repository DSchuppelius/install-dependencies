#!/usr/bin/env bash
# install-dependencies.sh
# Liest alle *executables.json in config/, installiert Pakete & JARs
# und startet rekursiv weitere install-dependencies-Skripte in vendor/.

set -euo pipefail

###############################################################################
# 0 - Rekursions-Schutz & Parameter
###############################################################################
if [[ -n "${INSTALL_DEPS_RUNNING:-}" ]]; then
  exit 0
fi
export INSTALL_DEPS_RUNNING=1

# --all: Auch optionale Pakete (required=false) installieren
INSTALL_ALL=0
for arg in "$@"; do
  case "$arg" in
    --all) INSTALL_ALL=1 ;;
  esac
done

if [[ "$INSTALL_ALL" -eq 1 ]]; then
  echo "Modus: ALLE Pakete (inkl. optionaler)"
else
  echo "Modus: Nur erforderliche Pakete (--all fuer optionale)"
fi

###############################################################################
# 1 - Verzeichnisse & Werkzeuge
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$SCRIPT_DIR/../config}"      # override moeglich
JQ=$(command -v jq) || { echo "jq noetig - sudo apt install jq"; exit 1; }

# pip-Feature einmalig pruefen (Performance bei vielen Pip-Paketen)
PIP_BREAK_SYSTEM_PACKAGES=""

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

# Noninteractive mode um Dialoge (z.B. Dienst-Neustarts) zu unterdrücken
export DEBIAN_FRONTEND=noninteractive

# apt update kann wegen einzelner Fremd-Repositories fehlschlagen.
# In dem Fall Deployment nicht abbrechen, sondern mit vorhandenen Listen fortfahren.
safe_apt_update() {
  local apt_output
  if apt_output=$(sudo apt-get update 2>&1); then
    echo "$apt_output"
    return 0
  fi

  echo "$apt_output"

  echo ""
  echo "WARNUNG: 'apt-get update' fehlgeschlagen."
  echo "Fahre mit vorhandenen Paketlisten fort (einzelne apt-Installationen koennen fehlschlagen)."
  echo "Hinweis: Mindestens ein APT-Repository ist fehlerhaft oder nicht erreichbar."

  # Moeglichst hilfreiche, aber allgemeine Diagnose der betroffenen Repositories.
  local broken_sources
  broken_sources=$(echo "$apt_output" | awk '/^(Err:|Fehl:)/ {print $2}' | sort -u | tr '\n' ' ')
  if [[ -n "$broken_sources" ]]; then
    echo "Betroffene Quelle(n): $broken_sources"
  fi

  return 0
}

safe_apt_update            # einmal zu Beginn

# Hilfsfunktion: Installer sicherstellen
ensure_installer() {
  local installer="$1"
  case "$installer" in
    pipx)
      if ! command -v pipx &>/dev/null; then
        echo "pipx nicht gefunden - installiere pipx..."
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y pipx || sudo pip3 install pipx
        pipx ensurepath 2>/dev/null || true
      fi
      ;;
    pip|pip3)
      if ! command -v pip3 &>/dev/null; then
        echo "pip3 nicht gefunden - installiere python3-pip..."
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-pip
      fi
      ;;
    npm)
      if ! command -v npm &>/dev/null; then
        echo "npm nicht gefunden - installiere nodejs npm..."
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs npm
      fi
      ;;
  esac
}

# Hilfsfunktion: Paket mit Installer installieren
install_package() {
  local installer="$1"
  local package="$2"
  local path="$3"

  # Fuer pipx: Nur /usr/local/bin pruefen, nicht allgemein im PATH
  # (lokale ~/.local/bin Installation reicht nicht fuer Server-Dienste)
  if [[ "$installer" != "pipx" ]]; then
    if [[ -n "$path" ]] && command -v "$path" &>/dev/null; then
      echo "  [OK] $package bereits installiert ($path)"
      return 0
    fi
  fi

  case "$installer" in
    apt|apt-get|"")
      if ! dpkg -s "$package" &>/dev/null; then
        echo "  [apt] Installiere: $package"
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$package" || echo "!!! $package nicht verfuegbar !!!"
      fi
      ;;
    pip|pip3)
      ensure_installer pip
      if ! pip3 show "$package" &>/dev/null; then
        echo "  [pip] Installiere: $package (systemweit)"
        # --break-system-packages fuer neuere pip (23.0+), sonst ohne
        if pip_supports_break_system_packages; then
          sudo pip3 install "$package" --break-system-packages
        else
          sudo pip3 install "$package"
        fi
      fi
      ;;
    pipx)
      ensure_installer pipx
      # Pruefen ob in /usr/local/bin oder via pipx list vorhanden
      if [[ -x "/usr/local/bin/$path" ]] || PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx list 2>/dev/null | grep -q "$package"; then
        echo "  [OK] $package bereits installiert"
      else
        echo "  [pipx] Installiere: $package (global nach /usr/local/bin)"
        # PIPX_HOME und PIPX_BIN_DIR fuer systemweite Installation setzen
        sudo PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install "$package"
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

# Hilfsfunktion: Dependencies in pipx venv injizieren
inject_pipx_dependencies() {
  local package="$1"
  shift
  local deps=("$@")
  
  for dep in "${deps[@]}"; do
    [[ -z "$dep" ]] && continue
    echo "  [pipx inject] $dep -> $package"
    sudo PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx inject "$package" "$dep" 2>/dev/null || \
      echo "    (Warnung: inject fehlgeschlagen fuer $dep)"
  done
}

pip_supports_break_system_packages() {
  if [[ -z "$PIP_BREAK_SYSTEM_PACKAGES" ]]; then
    if pip3 install --help 2>&1 | grep -q "break-system-packages"; then
      PIP_BREAK_SYSTEM_PACKAGES="yes"
    else
      PIP_BREAK_SYSTEM_PACKAGES="no"
    fi
  fi

  [[ "$PIP_BREAK_SYSTEM_PACKAGES" == "yes" ]]
}

process_package_configs() {
  local message_prefix="$1"
  shift

  local cfg section count installer package path pkg
  for cfg in "$@"; do
    echo "$message_prefix: $cfg"
    for section in $SECTIONS; do
      # Pruefen ob Sektion existiert und Eintraege hat
      count=$($JQ -r --arg sec "$section" '(.[$sec]? // {}) | length' "$cfg")
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
      done < <($JQ -r --arg sec "$section" --argjson all "$INSTALL_ALL" '
        (.[$sec]? // {}) | to_entries[] |
        select($all == 1 or .value.required != false) |
        [.value.installer // "apt", .value.packageDeb // .value.package, .value.path] | @tsv
      ' "$cfg")
    done
  done
}

process_dependency_configs() {
  local cfg section installer package deps_json
  for cfg in "$@"; do
    for section in $SECTIONS; do
      # Pakete mit dependencies finden
      while IFS=$'\t' read -r installer package deps_json; do
        [[ -z "$package" || -z "$deps_json" || "$deps_json" == "null" ]] && continue

        # Nur fuer pipx-Pakete relevant
        if [[ "$installer" == "pipx" ]]; then
          # JSON-Array in Bash-Array umwandeln
          mapfile -t deps < <(echo "$deps_json" | $JQ -r '.[]')
          if [[ ${#deps[@]} -gt 0 ]]; then
            inject_pipx_dependencies "$package" "${deps[@]}"
          fi
        fi
      done < <($JQ -r --arg sec "$section" --argjson all "$INSTALL_ALL" '
        (.[$sec]? // {}) | to_entries[] |
        select(.value.dependencies?) |
        select($all == 1 or .value.required != false) |
        [.value.installer // "apt", .value.package, (.value.dependencies | tojson)] | @tsv
      ' "$cfg")
    done
  done
}

process_java_configs() {
  local cfg url target
  for cfg in "$@"; do
    while IFS=$'\t' read -r url target; do
      [[ -n "${SEEN_JAR[$target]:-}" ]] && continue
      SEEN_JAR["$target"]=1
      if is_valid_jar "$target"; then
        echo "$target bereits vorhanden und gueltig"
      else
        if [[ -f "$target" ]]; then
          echo "!!! $target existiert aber ist ungueltig (kaputt/leer) - lade neu ..."
          sudo rm -f "$target"
        else
          echo "Lade $url -> $target ..."
        fi
        sudo curl -fL -o "$target" "$url" || {
          echo "!!! Download fehlgeschlagen: $url"
          echo "!!! WARNUNG: Deployment wird fortgesetzt. Datei bitte manuell bereitstellen: $target"
          sudo rm -f "$target"
          DOWNLOAD_WARNINGS=1
          continue
        }
        if ! is_valid_jar "$target"; then
          echo "!!! Heruntergeladene Datei ist keine gueltige JAR: $target"
          echo "!!! WARNUNG: Deployment wird fortgesetzt. Datei bitte manuell bereitstellen: $target"
          sudo rm -f "$target"
          DOWNLOAD_WARNINGS=1
          continue
        fi
        sudo chmod +x "$target"
        echo "$target heruntergeladen und validiert ✓"
      fi
    done < <($JQ -r --argjson all "$INSTALL_ALL" '.javaExecutables? // {} | to_entries[] | select(.value.url? and .value.path?) | select($all == 1 or .value.required != false) | [.value.url, .value.path] | @tsv' "$cfg")
  done
}

# Alle Executable-Sektionen durchgehen
SECTIONS="shellExecutables pythonExecutables nodeExecutables"

process_package_configs "Verarbeite" "${CONFIG_FILES[@]}"

###############################################################################
# 3b - Dependencies verarbeiten (pipx inject etc.)
###############################################################################
echo "Verarbeite Dependencies (pipx inject)..."
process_dependency_configs "${CONFIG_FILES[@]}"

###############################################################################
# 4 - Java-Executables herunterladen
###############################################################################
# Prueft ob eine JAR-Datei gueltig ist (Mindestgroesse + ZIP-Magic-Bytes)
is_valid_jar() {
  local file="$1"
  [[ ! -f "$file" ]] && return 1
  local size
  size=$(stat -c%s "$file" 2>/dev/null || echo 0)
  [[ "$size" -lt 10240 ]] && return 1           # kleiner als 10 KB = sicher kaputt
  # ZIP/JAR beginnt mit Magic Bytes PK (0x504B)
  local magic
  magic=$(xxd -l 2 -p "$file" 2>/dev/null || hexdump -n 2 -e '"%02x"' "$file" 2>/dev/null || echo "")
  [[ "$magic" == "504b" ]] && return 0
  return 1
}

declare -A SEEN_JAR
DOWNLOAD_WARNINGS=0
process_java_configs "${CONFIG_FILES[@]}"

###############################################################################
# 5 - executables.json in vendor/ Paketen verarbeiten
###############################################################################
# 5.1  Projekt-Root ermitteln - steige solange nach oben, bis ein vendor/-Ordner
#      gefunden wird oder / erreicht ist.
ROOT="$SCRIPT_DIR"
while [[ "$ROOT" != "/" && ! -d "$ROOT/vendor" ]]; do
  ROOT="$(dirname "$ROOT")"
done

VENDOR_DIR="$ROOT/vendor"
if [[ -d "$VENDOR_DIR" ]]; then
  echo "Suche in $VENDOR_DIR nach weiteren executables.json Konfigurationen ..."
  mapfile -t VENDOR_CONFIGS < <(find "$VENDOR_DIR" -maxdepth 5 -path '*/config/*executables.json' -type f | sort)
  
  if ((${#VENDOR_CONFIGS[@]}>0)); then
    echo "Gefundene Vendor-Konfig-Dateien:"
    printf '  * %s\n' "${VENDOR_CONFIGS[@]}"

    process_package_configs "Verarbeite Vendor-Config" "${VENDOR_CONFIGS[@]}"
    process_java_configs "${VENDOR_CONFIGS[@]}"
  else
    echo "Keine executables.json in $VENDOR_DIR gefunden."
  fi
fi

if [[ "$DOWNLOAD_WARNINGS" -eq 1 ]]; then
  echo "Alle definierten Abhaengigkeiten wurden geprueft."
  echo "WARNUNG: Mindestens ein Java-Download ist fehlgeschlagen. Bitte betroffene Datei(en) manuell bereitstellen."
else
  echo "Alle definierten Abhaengigkeiten wurden geprueft und installiert."
fi
