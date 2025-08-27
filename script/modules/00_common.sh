#!/bin/bash
# lib/00_common.sh — Common utility functions for system checks, package installation, backups, and random generation
: "${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# === Check LOG_FILE ===
check_LOG_FILE() {
  if [[ -z "${LOG_FILE:-}" || ! -f "$LOG_FILE" || ! -w "$LOG_FILE" ]]; then
    mkdir -p "$LOGS_DIR" || exit_error "Cannot create logs directory: $LOGS_DIR"
    LOG_FILE="$LOGS_DIR/${LOG_NAME}.log"
    touch "$LOG_FILE" || exit_error "Cannot create log file: $LOG_FILE"
    log "WARN" "Using fallback log file: $LOG_FILE"
  fi
}

# === Required commands and corresponding packages ===
declare -g -a missing_packages=()

# --- Check if a command exists ---
command_exists() {
    local cmd="$1"
    if command -v "$cmd" &>/dev/null; then
        log "DEBUG" "Command '$cmd' found"
        return 0
    else
        log "WARN" "Command '$cmd' not found"
        return 1
    fi
}

# --- Verify all required commands are present ---
check_required_commands() {
    log "INFO" "Checking required commands..."
    log "DEBUG" "Required commands: ${!required_commands[@]}"
    log "DEBUG" "Command → Package mapping: $(for cmd in "${!required_commands[@]}"; do echo -n "$cmd=${required_commands[$cmd]} "; done)"

    missing_packages=()
    for cmd in "${!required_commands[@]}"; do
        if ! command_exists "$cmd"; then
            local pkg="${required_commands[$cmd]}"
            # Добавляем только если ещё не добавлен
            if [[ ! " ${missing_packages[*]} " =~ " ${pkg} " ]]; then
                missing_packages+=("$pkg")
            fi
        fi
    done

    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        log "INFO" "Missing packages will be installed: ${missing_packages[*]}"
    else
        log "INFO" "All required commands are present"
    fi
}

# --- Check disk space and presence of systemd ---
check_system_resources() {
    log "INFO" "Checking system resources..."
    local required_space_mb=1024
    local available_space_mb
    available_space_mb=$(df -m / | tail -1 | awk '{print $4}')
    if (( available_space_mb < required_space_mb )); then
        exit_error "Insufficient disk space. Required: ${required_space_mb}MB, Available: ${available_space_mb}MB"
    fi
    if ! command_exists systemctl; then
        exit_error "systemd (systemctl) is required"
    fi
    log "INFO" "System resource check passed"
}

# --- Install missing packages ---
install_packages() {
    log "DEBUG" "Invoking install_packages with: ${missing_packages[*]}"
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        log "INFO" "Installing missing packages: ${missing_packages[*]}"
        apt-get update -y &>/dev/null || exit_error "Failed to update package list"
        apt-get install -y "${missing_packages[@]}" &>/dev/null || exit_error "Failed to install: ${missing_packages[*]}"
        log "INFO" "All missing packages installed"
    else
        log "INFO" "No packages to install"
    fi
}


# --- Update and upgrade system packages ---
update_and_upgrade_packages() {
    log "INFO" "Updating system package list..."
    if ! apt-get update -y &>/dev/null; then
        exit_error "Failed to update package list"
    fi
    
    pick_fast_mirror

    local updates
    updates=$(apt list --upgradable 2>/dev/null | grep -c "upgradable")

    if (( updates > 0 )); then
        log "INFO" "$updates package(s) can be upgraded"
        log "INFO" "Applying upgrades..."

        if apt-get upgrade -y -V; then
            log "INFO" "System upgrade completed successfully"
        else
            exit_error "System upgrade failed"
        fi

        if apt-get autoremove -y &>/dev/null; then
            log "INFO" "Unused packages removed"
        fi

        # Log previously missing packages (if any)
        if [[ ${missing_packages[@]+set} && ${#missing_packages[@]} -gt 0 ]]; then
            log "INFO" "Previously missing packages installed:"
            for pkg in "${missing_packages[@]}"; do
                log "OK" " - $pkg"
            done
        fi

    else
        log "INFO" "No upgrades available — system is up to date"
    fi
}


# --- Install yq from GitHub ---
yq_install() {
    local yq_bin="/usr/bin/yq"
    local attempts=3
    for ((i=1; i<=attempts; i++)); do
        [[ -f "$yq_bin" ]] && rm -f "$yq_bin"
        if wget -q https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O "$yq_bin"; then
            chmod +x "$yq_bin"
            if command -v yq &>/dev/null; then
                log "INFO" "yq installed successfully: $(yq --version)"
                return 0
            fi
        fi
        log "WARN" "yq installation attempt #$i failed, retrying..."
        sleep 3
    done
    exit_error "Failed to install yq after $attempts attempts"
}

# Optimized backup_file: keeps last 3 backups, optional backup directory
backup_file() {
    local file="$1"
    local backup_dir="${2:-$(dirname -- "$file")}"
    local base ts backups old

    # Preconditions
    if [[ ! -f "$file" ]]; then
        log "WARN" "File $file does not exist. Skipping backup."
        return 0
    fi
    if [[ ! -d "$backup_dir" ]]; then
        mkdir -p -- "$backup_dir" || { log "ERROR" "Cannot create backup dir $backup_dir"; }
    fi
    if [[ ! -w "$backup_dir" ]]; then
        log "ERROR" "Backup dir $backup_dir is not writable. Skipping backup."
    fi

    # Create backup
    base="$(basename -- "$file")"
    ts="$(date +%Y%m%d%H%M%S)"
    local backup="${backup_dir%/}/${base}.bak.${ts}"
    cp -- "$file" "$backup" || { log "ERROR" "Failed to copy $file to $backup"; }
    log "INFO" "Backup created: $backup"

    # Cleanup: keep only the newest 3 backups
    IFS=$'\n' read -d '' -r -a backups < <(
        ls -1t -- "${backup_dir%/}/${base}.bak."* 2>/dev/null
    )
    if (( ${#backups[@]} > 3 )); then
        for old in "${backups[@]:3}"; do
            rm -f -- "$old" && log "INFO" "Removed old backup: $old"
        done
    fi
}

# --- Restore latest backup for a file ---
restore_backup_file() {
    local file="$1"
    local last_backup
    last_backup=$(ls -t "${file}.bak."* 2>/dev/null | head -n1)
    [[ -z "$last_backup" ]] && exit_error "No backup found for $file"
    cp "$last_backup" "$file" || exit_error "Failed to restore from $last_backup"
    log "INFO" "File $file restored from $last_backup"
}

# --- Ensure directory exists ---
ensure_directory_exists() {
    local dir="$1"
    [[ -d "$dir" ]] || mkdir -p "$dir" || exit_error "Failed to create directory: $dir"
}

# --- Ensure file exists and writable ---
ensure_file_exists() {
    local file="$1"
    [[ -f "$file" ]] || touch "$file" || exit_error "Failed to create file: $file"
    [[ -w "$file" ]] || exit_error "File $file is not writable"
}

# --- Generate random alphanumeric string ---
generate_random_string() {
    local min="${1:-16}"
    local max="${2:-32}"
    local len
    len=$(shuf -i "$min-$max" -n1)
    openssl rand -base64 $((len * 3 / 4)) | tr -dc 'a-zA-Z0-9' | head -c "$len"
}

# --- Generate random free TCP port ---
generate_random_port() {
    local min="${1:-1024}"
    local max="${2:-65535}"
    for i in {1..100}; do
        local port
        port=$(shuf -i "$min-$max" -n1)
        if ! is_port_in_use "$port"; then
            echo "$port"
            return
        fi
    done
    exit_error "Could not find a free port in range $min-$max"
}

# --- Check if TCP port is in use ---
is_port_in_use() {
    local port=$1
    if command -v ss &>/dev/null; then
        ss -tuln | awk '{print $4}' | grep -qE "[:.]${port}\b"
    else
        netstat -tuln | awk '{print $4}' | grep -qE "[:.]${port}\b"
    fi
}

pick_fast_mirror() {
  COUNTRY=""
  LIMIT=15
  TEST_BYTES=$((1024 * 1024 * 20))
  DRY_RUN=0
  APT_UPDATE=1

  print_results_table() {
    printf "%-3s %-50s %-3s %-4s %-4s %-7s %-7s %-8s %-10s\n" "#" "Зеркало" "Sel" "Cur" "Sec" "MB/s" "DLsec" "Lat(ms)" "Статус"
    local i=1

    for line in "${RESULTS[@]}"; do
        parsed=$(awk '$1 ~ /^(OK|SLOW|UNREACHABLE)$/ && NF >= 6 { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 }' <<< "$line")
        IFS=$'\t' read -r status url spd dlsec latms secflag <<< "$parsed"


        local mb="0.00"
        [[ "$spd" != "0" ]] && mb=$(awk -v s="$spd" 'BEGIN{printf "%.2f",s/1048576}')

        local cur="-"
        [[ -n "${CURMAP[$url]:-}" ]] && cur="Y"
        [[ "$secflag" == "Y" ]] || secflag="-"
        local sel="${SELMAP[$url]:--}"

        printf "%-3s %-50s %-3s %-4s %-4s %-7s %-7s %-8s %-10s\n" \
        "$i" "${url:0:50}" "$sel" "$cur" "$secflag" "$mb" "$dlsec" "$latms" "$status"
        ((i++))
    done
  }

    detect_country() {
    local ip c
    set +o pipefail
    for url in \
        "https://ipinfo.io/country" \
        "https://ifconfig.co/country-iso" \
        "http://ip-api.com/line/?fields=countryCode"
    do
        log DEBUG "Trying: $url"
        c=$(curl -m 3 -fsSL "$url" 2>/dev/null | tr -d '\r\n')
        [[ "$c" =~ ^[A-Z]{2}$ ]] && COUNTRY="$c" && return 0
    done

    if command -v geoiplookup >/dev/null 2>&1; then
        ip=$(curl -m 3 -fsSL https://ifconfig.me 2>/dev/null)
        log DEBUG "IP: $ip"
        c=$(geoiplookup "$ip" 2>/dev/null | grep -oE '[A-Z]{2}$')
        [[ "$c" =~ ^[A-Z]{2}$ ]] && COUNTRY="$c" && return 0
    fi

    log DEBUG "Country detection failed."
    COUNTRY=""
    set -o pipefail
    return 1
    }


  while getopts ":c:n:s:dNh" opt; do
    case $opt in
      c) COUNTRY="${OPTARG^^}" ;;
      n) LIMIT="$OPTARG" ;;
      s) TEST_BYTES="$OPTARG" ;;
      d) DRY_RUN=1 ;;
      N) APT_UPDATE=0 ;;
    esac
  done

  : "${RUN_DIR:=$(pwd -P)}"

  if [[ -r /etc/os-release ]]; then . /etc/os-release; fi
  CODENAME="${UBUNTU_CODENAME:-}"
  if [[ -z "$CODENAME" && -x /usr/bin/lsb_release ]]; then
    CODENAME=$(lsb_release -sc || true)
  fi
  if [[ -z "$CODENAME" ]]; then
    log ERROR "Failed to determine Ubuntu codename."
    return 1
  fi

  normalize_repo_url() {
    local u="$1"
    u=$(grep -oE 'https?://[^ ]+' <<<"$u" | head -n1 || true)
    [[ -z "$u" ]] && { echo ""; return; }
    u="${u%/}"
    if [[ "$u" =~ /ubuntu($|/) ]]; then
      u="${u%%/ubuntu*}/ubuntu"
    fi
    echo "$u/"
  }

  declare -A CURMAP=()
  collect_current_mirrors() {
    local f line base
    if [[ -f /etc/apt/sources.list ]]; then
      while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        base=$(normalize_repo_url "$line")
        [[ -n "$base" ]] && CURMAP["$base"]=1
      done < <(grep -hE '^(deb|deb-src)[[:space:]]' /etc/apt/sources.list || true)
    fi
    shopt -s nullglob
    for f in /etc/apt/sources.list.d/*.list; do
      while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        base=$(normalize_repo_url "$line")
        [[ -n "$base" ]] && CURMAP["$base"]=1
      done < <(grep -hE '^(deb|deb-src)[[:space:]]' "$f" || true)
    done
    for f in /etc/apt/sources.list.d/*.sources; do
      while IFS= read -r line; do
        line="${line#URIs:}"
        base=$(normalize_repo_url "$line")
        [[ -n "$base" ]] && CURMAP["$base"]=1
      done < <(grep -hi '^URIs:' "$f" || true)
    done
    shopt -u nullglob
  }
  collect_current_mirrors

  if [[ -z "$COUNTRY" ]]; then
    log INFO "COUNTRY is not set, attempting to detect..."
    if detect_country; then
      log INFO "Detected country: $COUNTRY"
    else
      log WARN "Could not detect country. Using global mirror list."
    fi
  fi

  BASE_MIRRORS_URL="http://mirrors.ubuntu.com"
  if [[ -n "$COUNTRY" ]]; then
    lc_country=$(tr '[:upper:]' '[:lower:]' <<<"$COUNTRY")
    for cand in \
      "$BASE_MIRRORS_URL/mirrors.${lc_country}.txt" \
      "$BASE_MIRRORS_URL/mirrors.${COUNTRY}.txt" \
      "$BASE_MIRRORS_URL/${COUNTRY}.txt"
    do
      if curl -fsI "$cand" >/dev/null 2>&1; then
        MIRROR_LIST_URL="$cand"
        break
      fi
    done
    : "${MIRROR_LIST_URL:=$BASE_MIRRORS_URL/mirrors.txt}"
  else
    MIRROR_LIST_URL="$BASE_MIRRORS_URL/mirrors.txt"
  fi

  log INFO "Downloading mirror list: $MIRROR_LIST_URL"
  mapfile -t ALL_MIRRORS < <(curl -fsSL "$MIRROR_LIST_URL" | grep -E '^https?://')

  declare -a TEST_LIST=()
  for k in "${!CURMAP[@]}"; do TEST_LIST+=( "$k" ); done
  count=0
  for m in "${ALL_MIRRORS[@]}"; do
    [[ -n "${CURMAP[$m]:-}" ]] && continue
    TEST_LIST+=( "$m" )
    ((++count >= LIMIT)) && break
  done

  (( ${#TEST_LIST[@]} == 0 )) && log ERROR "No mirrors to test." && return 1
  log INFO "Testing ${#TEST_LIST[@]} mirrors (codename: $CODENAME, $TEST_BYTES bytes per test)..."

  is_security_url() {
    local u="$1"
    [[ "$u" =~ security\.ubuntu\.com ]] && return 0
    [[ "$u" =~ ubuntu-security ]] && return 0
    return 1
  }

  has_security_suite() {
    local m="$1"
    local suite="${CODENAME}-security"
    if is_security_url "$m"; then return 0; fi
    local rel="${m%/}/dists/$suite/Release"
    curl -ILfs "$rel" >/dev/null 2>&1
  }

  test_mirror() {
    local m="$1"
    local suite="$CODENAME"
    if is_security_url "$m"; then suite="${CODENAME}-security"; fi
    local rel="${m%/}/dists/$suite/Release"
    local pkg="${m%/}/dists/$suite/main/binary-amd64/Packages.xz"
    local ttfb
    ttfb=$(curl -fIsS -o /dev/null -w "%{time_starttransfer}\n" "$rel" 2>/dev/null || echo 0)
    ttfb=$(awk -v v="$ttfb" 'BEGIN{printf "%.0f", v*1000}')
    local secflag="-"
    if has_security_suite "$m"; then secflag="Y"; fi
    if ! curl -fsI "$rel" >/dev/null 2>&1; then
      echo "UNREACHABLE $m 0 0 $ttfb $secflag"
      return
    fi
    local target="$pkg"
    if ! curl -fsI "$pkg" >/dev/null 2>&1; then target="$rel"; fi
    local speed time
    read -r speed time < <(
      curl -fSsL --range 0-$((TEST_BYTES-1)) --max-time 10 -o /dev/null \
        -w "%{speed_download} %{time_total}\n" "$target" 2>/dev/null || echo "0 0"
    )
    if [[ -z "$speed" || "$speed" == "0" ]]; then
      echo "SLOW $m 0 0 $ttfb $secflag"
    else
      echo "OK $m $speed $time $ttfb $secflag"
    fi
  }

  RESULTS=()
  for m in "${TEST_LIST[@]}"; do
    RESULTS+=( "$(test_mirror "$m")" )
  done

  mapfile -t OK_SEC < <(
    printf '%s\n' "${RESULTS[@]}" \
      | awk '$1=="OK" && $6=="Y"{print}' \
      | sort -k5,5n -k3,3nr
  )

  if (( ${#OK_SEC[@]} < 2 )); then
    log INFO "Подходящих зеркал (Sec=Y) меньше двух; изменения не вносятся."
    print_results_table | column -t
    return 1
  fi

  BEST_ARCHIVE=$(awk '{print $2}' <<<"${OK_SEC[0]}")
  BEST_SECURITY="<none>"
  for l in "${OK_SEC[@]:1}"; do
    url=$(awk '{print $2}' <<<"$l")
    if [[ "$url" != "$BEST_ARCHIVE" ]]; then
      BEST_SECURITY="$url"
      break
    fi
  done
  if [[ "$BEST_SECURITY" == "<none>" ]]; then
    log INFO "Не смог выбрать второе отличное зеркало (Sec=Y); изменения не применены."
    return 1
  fi

  declare -A SELMAP=()
  SELMAP["$BEST_ARCHIVE"]="A"
  SELMAP["$BEST_SECURITY"]="S"

  if (( DRY_RUN )); then
    log INFO "=== Результаты теста зеркал (dry-run) ==="
    print_results_table | column -t
    return 0
  fi

  APT_SOURCES_LIST_DEB822="/etc/apt/sources.list.d/ubuntu.sources"
  APT_SOURCES_LIST_CLASSIC="/etc/apt/sources.list"

  if [[ -f "$APT_SOURCES_LIST_DEB822" ]]; then
    backup_file "$APT_SOURCES_LIST_DEB822" "$SCRIPT_DIR"
    tmp=$(mktemp)
    awk -v arch="$BEST_ARCHIVE" -v sec="$BEST_SECURITY" '
      BEGIN { block=0 }
      /^Types:/ { block++; print; next }
      /^URIs:/ {
        if (block==1) print "URIs: " arch
        else if (block==2) print "URIs: " sec
        else print
        next
      }
      { print }
    ' "$APT_SOURCES_LIST_DEB822" > "$tmp"
    mv "$tmp" "$APT_SOURCES_LIST_DEB822"
    log INFO "Updated $APT_SOURCES_LIST_DEB822."
  elif [[ -f "$APT_SOURCES_LIST_CLASSIC" ]]; then
    backup_file "$APT_SOURCES_LIST_CLASSIC"
    sed -i -E "s|http(s)?://[^ ]*archive.ubuntu.com/ubuntu/?|$BEST_ARCHIVE|g" "$APT_SOURCES_LIST_CLASSIC"
    sed -i -E "s|http(s)?://[^ ]*security.ubuntu.com/ubuntu/?|$BEST_SECURITY|g" "$APT_SOURCES_LIST_CLASSIC"
    log INFO "Updated $APT_SOURCES_LIST_CLASSIC."
  else
    log INFO "APT источники не найдены; создаю новый /etc/apt/sources.list."
    cat >"$APT_SOURCES_LIST_CLASSIC" <<NEWLIST
deb ${BEST_ARCHIVE} ${CODENAME} main restricted universe multiverse
deb ${BEST_ARCHIVE} ${CODENAME}-updates main restricted universe multiverse
deb ${BEST_ARCHIVE} ${CODENAME}-backports main restricted universe multiverse
deb ${BEST_SECURITY} ${CODENAME}-security main restricted universe multiverse
NEWLIST
  fi

  if (( APT_UPDATE )); then
    log INFO "apt-get update..."
    apt-get update -y &>/dev/null || exit_error "Failed to update package list"
  fi

  log INFO "=== Result test mirrors ==="
  print_results_table | column -t
}
