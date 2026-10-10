#!/usr/bin/env bash
# install-dependencies.sh
# Liest alle *executables.json in config/, installiert Pakete, JARs und
# Werkzeuge mit install-Angabe (Tarball, IzPack)
# und startet rekursiv weitere install-dependencies-Skripte in vendor/.
#
# Verwendung:
#   ./install-dependencies.sh                                  # eigener vendor-Baum
#   ./install-dependencies.sh --all                            # inkl. optionaler Pakete
#   ./install-dependencies.sh --vendor-root /pfad/zum/deployment   # zusaetzlicher Baum
#
# Hinweis: Ohne --vendor-root wird nur das vendor/ oberhalb des Skript-Ortes
# gescannt. Deployments mit eigenem vendor/ (webservice, worker) muessen entweder
# selbst aufrufen oder hier mit angegeben werden - sonst zeigen sie auf JAR-Versionen,
# die nie heruntergeladen wurden.

set -euo pipefail

###############################################################################
# 0 - Rekursions-Schutz & Parameter
###############################################################################
if [[ -n "${INSTALL_DEPS_RUNNING:-}" ]]; then
  exit 0
fi
export INSTALL_DEPS_RUNNING=1

# --all: Auch optionale Pakete (required=false) installieren
# --vendor-root <pfad>: Zusaetzlicher vendor-Baum, der mitgescannt wird. Ohne diese
#   Angabe sieht das Skript nur das vendor/ oberhalb seines eigenen Ortes - ein
#   Deployment mit eigenem vendor/ (webservice, worker) bliebe sonst unversorgt und
#   liefe auf eine andere Toolkit-Version als der Baum, in dem das Skript liegt.
#   Mehrfach angebbar, akzeptiert Repo-Wurzel oder vendor/ direkt.
INSTALL_ALL=0
EXTRA_VENDOR_ROOTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) INSTALL_ALL=1 ;;
    --vendor-root)
      shift
      [[ $# -gt 0 ]] || { echo "--vendor-root benoetigt einen Pfad"; exit 1; }
      EXTRA_VENDOR_ROOTS+=("$1")
      ;;
    --vendor-root=*) EXTRA_VENDOR_ROOTS+=("${1#*=}") ;;
  esac
  shift
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

# Loest GitHub-Release-Seiten in direkte Asset-Download-URLs auf.
# Unterstuetzt: .../releases, .../releases/latest, .../releases/tag/<tag>
# Direkte Links (auch .../releases/download/...) werden unveraendert zurueckgegeben.
# Asset-Auswahl per Glob-Pattern (assetPattern in der Config, Default: *.jar).
# Optional: GITHUB_TOKEN gegen API-Rate-Limits.
resolve_download_url() {
  local url="$1"
  local pattern="${2:-}"
  [[ -z "$pattern" ]] && pattern="*.jar"

  local api=""
  if [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/releases(/latest)?/?$ ]]; then
    api="https://api.github.com/repos/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/releases/latest"
  elif [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/releases/tag/([^/]+)/?$ ]]; then
    api="https://api.github.com/repos/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/releases/tags/${BASH_REMATCH[3]}"
  else
    echo "$url"
    return 0
  fi

  local auth=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

  local assets
  assets=$(curl -fsSL --max-time 30 "${auth[@]}" -H "Accept: application/vnd.github+json" "$api" | $JQ -r '.assets[]?.browser_download_url') || return 1
  [[ -z "$assets" ]] && return 1

  local asset
  while IFS= read -r asset; do
    if [[ "$(basename "$asset")" == $pattern ]]; then
      echo "$asset"
      return 0
    fi
  done <<< "$assets"

  return 1
}

process_java_configs() {
  local cfg cfg_root url target pattern resolved
  for cfg in "$@"; do
    # Relative Zielpfade beziehen sich auf das Repo der Config (config/..),
    # nicht auf das Aufruf-CWD - analog zur Pfadaufloesung der Toolkits.
    cfg_root="$(cd "$(dirname "$cfg")/.." && pwd)"
    while IFS=$'\t' read -r url target pattern; do
      [[ "$target" != /* ]] && target="$cfg_root/$target"
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
        resolved=$(resolve_download_url "$url" "$pattern") || {
          echo "!!! GitHub-Release-Aufloesung fehlgeschlagen: $url (Asset-Pattern: ${pattern:-*.jar})"
          echo "!!! WARNUNG: Deployment wird fortgesetzt. Datei bitte manuell bereitstellen: $target"
          DOWNLOAD_WARNINGS=1
          continue
        }
        [[ "$resolved" != "$url" ]] && echo "GitHub-Release aufgeloest: $resolved"
        sudo mkdir -p "$(dirname "$target")"
        sudo curl -fL -o "$target" "$resolved" || {
          echo "!!! Download fehlgeschlagen: $resolved"
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
    # Kein required-Filter: JARs mit hinterlegter url sind selbstinstallierend, und ein
    # optionales Werkzeug soll trotzdem bereitstehen. "required" beschreibt zur Laufzeit
    # die Wichtigkeit des Werkzeugs, nicht ob es installiert werden soll.
    done < <($JQ -r '.javaExecutables? // {} | to_entries[] | select(.value.url? and .value.path?) | [.value.url, .value.path, .value.assetPattern // ""] | @tsv' "$cfg")
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
  # ZIP/JAR beginnt mit Magic Bytes PK (0x504B). od statt xxd/hexdump:
  # ueberall vorhanden und byteweise (hexdump ohne Formatangabe liefert
  # little-endian-vertauschte Reihenfolge).
  local magic
  magic=$(od -An -tx1 -N2 "$file" 2>/dev/null | tr -d ' \n')
  [[ "$magic" == "504b" ]] && return 0
  return 1
}

declare -A SEEN_JAR
DOWNLOAD_WARNINGS=0
process_java_configs "${CONFIG_FILES[@]}"

###############################################################################
# 4b - Installer: Werkzeuge, die weder apt noch eine einzelne JAR liefern
###############################################################################
# Feld "install" an einem Eintrag der shellExecutables (ein eigener Abschnitt
# ist nicht moeglich: der Config-Loader verlangt an jedem Eintrag jeder Sektion
# ein "path"). Das Objekt beschreibt EINE Quelle und wie sie auf die Platte kommt:
#
#   "type"           tarball | izpack
#   "url"            direkte Download-URL (GitHub-Release-Seiten wie bei den
#                    JARs: .../releases/tag/<tag> plus "assetPattern")
#   "sha256"         Pruefsumme des Downloads; bei Abweichung wird nichts installiert
#   "arch"           optional, z. B. "x86_64": andere Architekturen ueberspringen
#   "version"        erwartete Version; zusammen mit "versionCommand" die
#                    Fertig-Pruefung (Ausgabe enthaelt die Version -> nichts tun)
#   "versionCommand" Befehl, der die installierte Version ausgibt
#   tarball:  "member" Pfad der Datei im Archiv, "target" Zielpfad (0755)
#   izpack:   "installPath" Zielordner des IzPack-Installers (Java noetig),
#             "links" { "/usr/local/bin/x": "/opt/x/x" } Symlinks danach
#
# Wie bei den JARs gibt es keinen required-Filter: Was hier steht, ist
# selbstinstallierend; ein optionales Werkzeug soll trotzdem bereitstehen.
# Fehler brechen das Deployment nicht ab, sondern setzen DOWNLOAD_WARNINGS.

# Fuehrt einen Befehl mit sudo aus, wenn der naechste existierende Elternordner
# des Ziels nicht beschreibbar ist. So laufen Tests und Nutzer-Prefixe ohne root.
run_for_target() {
  local target="$1"
  shift
  local probe="$target"
  while [[ ! -e "$probe" && "$probe" != "/" ]]; do
    probe="$(dirname "$probe")"
  done
  if [[ -w "$probe" ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

verify_sha256() {
  local file="$1" expected="$2" actual
  [[ -z "$expected" ]] && { echo "  Hinweis: keine sha256 hinterlegt, Download ungeprueft"; return 0; }
  actual=$(sha256sum "$file" | awk '{print $1}')
  if [[ "$actual" != "$expected" ]]; then
    echo "!!! Pruefsumme stimmt nicht: erwartet $expected, erhalten $actual"
    return 1
  fi
  return 0
}

# Fertig, wenn versionCommand laeuft und seine Ausgabe die erwartete Version enthaelt.
installer_up_to_date() {
  local version_command="$1" version="$2" out
  [[ -z "$version_command" || -z "$version" ]] && return 1
  out=$(eval "$version_command" 2>&1) || return 1
  [[ "$out" == *"$version"* ]]
}

ensure_tool() {
  local tool="$1" package="$2"
  command -v "$tool" &>/dev/null && return 0
  echo "  $tool fehlt - installiere $package ..."
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
}

download_installer_source() {
  local url="$1" pattern="$2" out="$3" resolved
  resolved=$(resolve_download_url "$url" "$pattern") || {
    echo "!!! Download-Adresse nicht aufloesbar: $url (Asset-Pattern: ${pattern:-*})"
    return 1
  }
  [[ "$resolved" != "$url" ]] && echo "  GitHub-Release aufgeloest: $resolved"
  curl -fsSL --retry 3 -o "$out" "$resolved" || {
    echo "!!! Download fehlgeschlagen: $resolved"
    return 1
  }
}

install_from_tarball() {
  local name="$1" url="$2" pattern="$3" sha="$4" member="$5" target="$6" tmp
  [[ -z "$member" || -z "$target" ]] && { echo "!!! $name: tarball braucht member und target"; return 1; }
  tmp=$(mktemp -d)
  download_installer_source "$url" "$pattern" "$tmp/archive" || { rm -rf "$tmp"; return 1; }
  verify_sha256 "$tmp/archive" "$sha" || { rm -rf "$tmp"; return 1; }
  mkdir -p "$tmp/x"
  tar -xzf "$tmp/archive" -C "$tmp/x" || { echo "!!! $name: Archiv nicht entpackbar"; rm -rf "$tmp"; return 1; }
  if [[ ! -f "$tmp/x/$member" ]]; then
    echo "!!! $name: $member fehlt im Archiv"
    rm -rf "$tmp"
    return 1
  fi
  run_for_target "$target" mkdir -p "$(dirname "$target")"
  run_for_target "$target" install -m 0755 "$tmp/x/$member" "$target"
  rm -rf "$tmp"
  echo "  $target installiert"
}

install_from_izpack() {
  local name="$1" url="$2" pattern="$3" sha="$4" install_path="$5" links_json="$6" tmp jar
  [[ -z "$install_path" ]] && { echo "!!! $name: izpack braucht installPath"; return 1; }
  ensure_tool unzip unzip
  ensure_tool java default-jre-headless
  tmp=$(mktemp -d)
  download_installer_source "$url" "$pattern" "$tmp/archive" || { rm -rf "$tmp"; return 1; }
  verify_sha256 "$tmp/archive" "$sha" || { rm -rf "$tmp"; return 1; }
  mkdir -p "$tmp/x"
  unzip -q "$tmp/archive" -d "$tmp/x" || { echo "!!! $name: ZIP nicht entpackbar"; rm -rf "$tmp"; return 1; }
  jar=$(find "$tmp/x" -type f -iname '*installer*.jar' | head -1)
  [[ -z "$jar" ]] && jar=$(find "$tmp/x" -type f -name '*.jar' | head -1)
  if [[ -z "$jar" ]]; then
    echo "!!! $name: kein Installer-JAR im Archiv"
    rm -rf "$tmp"
    return 1
  fi
  # Unbeaufsichtigte IzPack-Installation: Zielordner vorgeben, Standardpakete.
  cat > "$tmp/auto-install.xml" <<XML
<AutomatedInstallation langpack="eng">
    <com.izforge.izpack.panels.htmlhello.HTMLHelloPanel id="welcome"/>
    <com.izforge.izpack.panels.target.TargetPanel id="install_dir">
        <installpath>$install_path</installpath>
    </com.izforge.izpack.panels.target.TargetPanel>
    <com.izforge.izpack.panels.packs.PacksPanel id="sdk_pack_select"/>
    <com.izforge.izpack.panels.install.InstallPanel id="install"/>
    <com.izforge.izpack.panels.finish.FinishPanel id="finish"/>
</AutomatedInstallation>
XML
  run_for_target "$install_path" mkdir -p "$(dirname "$install_path")"
  if ! run_for_target "$install_path" java -jar "$jar" "$tmp/auto-install.xml" > "$tmp/install.log" 2>&1; then
    echo "!!! $name: IzPack-Installation fehlgeschlagen"
    tail -n 5 "$tmp/install.log"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  local link_target link_name
  while IFS=$'\t' read -r link_name link_target; do
    [[ -z "$link_name" ]] && continue
    if [[ ! -e "$link_target" ]]; then
      echo "!!! $name: Linkziel fehlt nach der Installation: $link_target"
      return 1
    fi
    run_for_target "$link_name" mkdir -p "$(dirname "$link_name")"
    run_for_target "$link_name" ln -sfn "$link_target" "$link_name"
    echo "  $link_name -> $link_target"
  done < <(echo "$links_json" | $JQ -r 'to_entries[]? | [.key, .value] | @tsv')
  echo "  $install_path installiert"
}

declare -A SEEN_INSTALLER

process_installer_configs() {
  local cfg entry name type url pattern sha arch version version_command member target install_path links machine
  machine=$(uname -m)
  for cfg in "$@"; do
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      name=$(echo "$entry" | $JQ -r '.key')
      [[ -n "${SEEN_INSTALLER[$name]:-}" ]] && continue
      SEEN_INSTALLER["$name"]=1
      type=$(echo "$entry" | $JQ -r '.value.type // ""')
      url=$(echo "$entry" | $JQ -r '.value.url // ""')
      pattern=$(echo "$entry" | $JQ -r '.value.assetPattern // ""')
      sha=$(echo "$entry" | $JQ -r '.value.sha256 // ""')
      arch=$(echo "$entry" | $JQ -r '.value.arch // ""')
      version=$(echo "$entry" | $JQ -r '.value.version // ""')
      version_command=$(echo "$entry" | $JQ -r '.value.versionCommand // ""')
      member=$(echo "$entry" | $JQ -r '.value.member // ""')
      target=$(echo "$entry" | $JQ -r '.value.target // ""')
      install_path=$(echo "$entry" | $JQ -r '.value.installPath // ""')
      links=$(echo "$entry" | $JQ -c '.value.links // {}')

      if [[ -z "$type" || -z "$url" ]]; then
        echo "  [WARN] install an $name ohne type oder url - uebersprungen"
        continue
      fi
      if [[ -n "$arch" && "$arch" != "$machine" ]]; then
        echo "  Installer $name: nur fuer $arch, hier $machine - uebersprungen"
        continue
      fi
      if installer_up_to_date "$version_command" "$version"; then
        echo "  [OK] $name $version bereits installiert"
        continue
      fi
      echo "  [installer] $name ($type) ..."
      case "$type" in
        tarball) install_from_tarball "$name" "$url" "$pattern" "$sha" "$member" "$target" ;;
        izpack)  install_from_izpack "$name" "$url" "$pattern" "$sha" "$install_path" "$links" ;;
        *)       echo "  [WARN] Unbekannter Installer-Typ '$type' fuer $name"; false ;;
      esac || {
        echo "!!! WARNUNG: Deployment wird fortgesetzt. $name bitte manuell bereitstellen."
        DOWNLOAD_WARNINGS=1
        continue
      }
      if [[ -n "$version_command" ]] && ! installer_up_to_date "$version_command" "$version"; then
        echo "!!! WARNUNG: $name installiert, aber '$version_command' meldet nicht Version $version"
        DOWNLOAD_WARNINGS=1
      fi
    done < <($JQ -c '.shellExecutables? // {} | to_entries[] | select(.value.install? and (.value.install | type == "object")) | {key: .key, value: .value.install}' "$cfg")
  done
}

process_installer_configs "${CONFIG_FILES[@]}"

###############################################################################
# 5 - executables.json in vendor/ Paketen verarbeiten
###############################################################################
# 5.1  Projekt-Root ermitteln - steige solange nach oben, bis ein vendor/-Ordner
#      gefunden wird oder / erreicht ist.
ROOT="$SCRIPT_DIR"
while [[ "$ROOT" != "/" && ! -d "$ROOT/vendor" ]]; do
  ROOT="$(dirname "$ROOT")"
done

# 5.2  Zu scannende vendor-Baeume sammeln: der eigene plus alle per --vendor-root
#      uebergebenen. Doppelte Angaben werden ueber den realen Pfad entfernt.
VENDOR_DIRS=()
declare -A SEEN_VENDOR_DIR

add_vendor_dir() {
  local candidate="$1" real
  # Sowohl Repo-Wurzel als auch vendor/ direkt akzeptieren
  [[ -d "$candidate/vendor" ]] && candidate="$candidate/vendor"
  [[ -d "$candidate" ]] || { echo "Hinweis: vendor-Baum nicht gefunden, wird uebersprungen: $1"; return 0; }
  real="$(cd "$candidate" && pwd)"
  [[ -n "${SEEN_VENDOR_DIR[$real]:-}" ]] && return 0
  SEEN_VENDOR_DIR["$real"]=1
  VENDOR_DIRS+=("$real")
}

add_vendor_dir "$ROOT/vendor"
for extra in ${EXTRA_VENDOR_ROOTS[@]+"${EXTRA_VENDOR_ROOTS[@]}"}; do
  add_vendor_dir "$extra"
done

for VENDOR_DIR in ${VENDOR_DIRS[@]+"${VENDOR_DIRS[@]}"}; do
  echo "Suche in $VENDOR_DIR nach weiteren executables.json Konfigurationen ..."
  mapfile -t VENDOR_CONFIGS < <(find "$VENDOR_DIR" -maxdepth 5 -path '*/config/*executables.json' -type f | sort)

  if ((${#VENDOR_CONFIGS[@]}>0)); then
    echo "Gefundene Vendor-Konfig-Dateien:"
    printf '  * %s\n' "${VENDOR_CONFIGS[@]}"

    process_package_configs "Verarbeite Vendor-Config" "${VENDOR_CONFIGS[@]}"
    process_java_configs "${VENDOR_CONFIGS[@]}"
    process_installer_configs "${VENDOR_CONFIGS[@]}"
  else
    echo "Keine executables.json in $VENDOR_DIR gefunden."
  fi
done

if [[ "$DOWNLOAD_WARNINGS" -eq 1 ]]; then
  echo "Alle definierten Abhaengigkeiten wurden geprueft."
  echo "WARNUNG: Mindestens ein Download oder Installer ist fehlgeschlagen. Bitte betroffene Werkzeuge manuell bereitstellen."
else
  echo "Alle definierten Abhaengigkeiten wurden geprueft und installiert."
fi
