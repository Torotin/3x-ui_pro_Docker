#!/bin/bash
# ./install.sh — Main installation script

# === Parameters and Variables ===
LOGLEVEL="INFO"  # ERROR, WARN, INFO, DEBUG
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(realpath "$0")")"
LIB_DIR="$SCRIPT_DIR/modules"
TEMPLATE_DIR="$SCRIPT_DIR/template"
LOGS_DIR="$PROJECT_ROOT"
LOG_NAME="$(basename "$0" .sh)"
LOG_FILE="$LOGS_DIR/$LOG_NAME.log"
ENV_FILE="$PROJECT_ROOT/$LOG_NAME.env"
ENV_TEMPLATE_FILE="$TEMPLATE_DIR/$LOG_NAME.env.template"
DOCKER_DIR="/opt/docker-proxy"
DOCKER_COMPOSE_FILE="$DOCKER_DIR/compose.yml"
DOCKER_ENV_FILE="$DOCKER_DIR/.env"
DOCKER_ENV_TEMPLATE="$TEMPLATE_DIR/docker.env.template"
GITHUB_REPO_OWNER="${REPO_OWNER:-Torotin}"
GITHUB_REPO_NAME="${REPO_NAME:-3x-ui_pro_Docker}"
LOADED_MODULES=()

# Detect which branch the installer was fetched from; fall back to env or main
detect_github_branch() {
  local branch candidate src_path

  branch="${REPO_BRANCH:-}"
  [[ -n "$branch" ]] && { echo "$branch"; return; }

  # Try to parse branch out of the source path (works for raw.githubusercontent.com URLs)
  src_path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
  if [[ "$src_path" =~ raw\.githubusercontent\.com/[^/]+/[^/]+/([^/]+)/ ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi

  # If we're inside a git clone, use the current branch; fall back to commit short hash
  if command -v git >/dev/null 2>&1; then
    local git_root
    git_root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$git_root" ]]; then
      candidate="$(git -C "$git_root" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
      if [[ -n "$candidate" && "$candidate" != "HEAD" ]]; then
        echo "$candidate"
        return
      fi
      candidate="$(git -C "$git_root" rev-parse --short HEAD 2>/dev/null || true)"
      [[ -n "$candidate" ]] && { echo "$candidate"; return; }
    fi
  fi

  echo "main"
}

declare -A required_commands=(
    ["mc"]="mc"
    ["perl"]="perl"
    ["curl"]="curl"
    ["openssl"]="openssl"
    ["lsof"]="lsof"
    ["ufw"]="ufw"
    ["jq"]="jq"
    ["gzip"]="gzip"
    ["cron"]="cron"
    ["sqlite3"]="sqlite3"
    ["git"]="git"
    ["tcpdump"]="tcpdump"
    ["netstat"]="net-tools"
    ["traceroute"]="traceroute"
    ["whois"]="whois"
    ["idn"]="idn"
    ["envsubst"]="gettext"
    ["ss"]="iproute2"
    ["htpasswd"]="apache2-utils"
)

trap 'log "ERROR" "Script aborted (exit code $?) at line $LINENO"' ERR

# === Logging ===
log() {
  local level="$1"; shift
  # Очистка level от пробелов и переводов строки
  level="${level//[[:space:]]/}"
  if [[ -z "$level" ]]; then
    level="INFO"
  fi

  local timestamp caller module_path
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  caller="${FUNCNAME[1]:-MAIN}"

  if [[ ${BASH_SOURCE[1]+isset} ]]; then
    module_path="$(realpath --relative-to="$PROJECT_ROOT" "${BASH_SOURCE[1]}" 2>/dev/null || echo "${BASH_SOURCE[1]}")"
  else
    module_path="$(realpath --relative-to="$PROJECT_ROOT" "$0" 2>/dev/null || echo "$0")"
  fi

  local color reset="\033[0m"
  local current=3  # default INFO
  local active=3   # default INFO

  # Определяем уровень текущего сообщения
  case "$level" in
    ERROR) current=1 ;;
    WARN)  current=2 ;;
    INFO|OK) current=3 ;;
    DEBUG) current=4 ;;
    *) current=3 ;;
  esac

  # Определяем активный уровень логирования
  case "$LOGLEVEL" in
    ERROR) active=1 ;;
    WARN)  active=2 ;;
    INFO|OK) active=3 ;;
    DEBUG) active=4 ;;
    *) active=3 ;;
  esac

  (( current > active )) && return

  case "$level" in
    INFO)   color='\033[1;34m' ;;
    OK)     color='\033[1;32m' ;;
    WARN*)  color='\033[1;33m' ;;
    ERR*|FAIL*) color='\033[1;31m' ;;
    DEBUG)  color='\033[1;36m' ;;
    SEP)
      local sep="------------------------------------------------------------"
      echo -e "\033[1;30m$sep$reset"
      echo "$sep" >> "$LOG_FILE"
      return ;;
    TITLE)
      local title="== [$module_path] $* =="
      echo -e "\033[1;36m$title$reset"
      echo "$title" >> "$LOG_FILE"
      return ;;
    *) color='\033[0m' ;;
  esac

  local formatted="[${timestamp}] [$level] [$module_path] [$caller]"
  echo -e "${color}${formatted}${reset} $*"
  echo "${formatted} $*" >> "$LOG_FILE"
}

# === Exit Handling ===
reset_permissions() {
  local TARGET_DIR="$1"
  local TARGET_USER="${2:-}"
  local rc=0

  log "INFO" "Resetting ownership and permissions for '$TARGET_DIR' (user: ${TARGET_USER:-<none>})"

  # Валидация
  if [[ -z "$TARGET_DIR" || ! -e "$TARGET_DIR" || ! -d "$TARGET_DIR" ]]; then
    log "ERROR" "Target directory is invalid: '$TARGET_DIR'"
    return 1
  fi
  if [[ "$TARGET_DIR" == "/" ]]; then
    log "ERROR" "Refusing to operate on root '/'"
    return 1
  fi

  # Пытаемся сменить владельца (если пользователь указан и существует)
  if [[ -n "$TARGET_USER" ]] && id -u "$TARGET_USER" &>/dev/null; then
    local MAIN_GROUP
    if getent group "$TARGET_USER" &>/dev/null; then
      MAIN_GROUP="$TARGET_USER"
    else
      MAIN_GROUP="$(id -gn "$TARGET_USER")"
    fi

    if chown -hR -- "$TARGET_USER:$MAIN_GROUP" "$TARGET_DIR"; then
      log "INFO" "Ownership set to $TARGET_USER:$MAIN_GROUP"
    else
      log "ERROR" "Failed to set ownership to $TARGET_USER:$MAIN_GROUP"
      rc=1
    fi
  else
    if [[ -n "$TARGET_USER" ]]; then
      log "WARN" "User '$TARGET_USER' not found. Ownership not changed."
      rc=1
    else
      log "INFO" "No user provided. Ownership not changed."
    fi
  fi

  # Права применяем ВСЕГДА, вне зависимости от результата chown
  if chmod -R u=rwX,go=rX -- "$TARGET_DIR"; then
    log "INFO" "Permissions reset to u=rwX,go=rX for '$TARGET_DIR'"
  else
    log "ERROR" "Failed to reset permissions for '$TARGET_DIR'"
    rc=1
  fi

  # Итог
  if (( rc == 0 )); then
    log "OK" "Ownership and permissions successfully reset for '$TARGET_DIR'"
  else
    log "WARN" "Completed with warnings/errors. See log above."
  fi
  return $rc
}

# Нормализация USER_SSH: убираем управляющие символы/пробелы
sanitize_user_ssh() {
  local target_user="${1:-$USER_SSH}"
  if [[ -n "${target_user:-}" ]]; then
    target_user="${target_user//$'\r'/}"
    target_user="${target_user//$'\n'/}"
    target_user="${target_user//$'\t'/}"
    target_user="${target_user//[[:space:]]/}"
  fi
  echo "$target_user"
}

# Обёртка для применения к двум каталогам
reset_all_permissions() {
  local target_user
  target_user=$(sanitize_user_ssh "${1:-$USER_SSH}")
  local rc=0

  reset_permissions "$SCRIPT_DIR" "$target_user" || rc=1
  reset_permissions "$DOCKER_DIR" "$target_user" || rc=1

  return $rc
}

exit_script() {
  if reset_all_permissions "$USER_SSH"; then
    log "INFO" "Script completed."
    exit 0
  else
    log "WARN" "Script completed, but resetting permissions failed."
    exit 0
  fi
}

exit_error() {
  # $1 = error message
  log "ERROR" "${1:-Unknown error}"
  if ! reset_all_permissions "$USER_SSH"; then
    log "WARN" "Reset permissions failed during error exit."
  fi
  exit 1
}

reboot_system() {
  # Подтверждение с таймаутом
  read -r -t 10 -p "Reboot now? [y/N] (auto-cancel in 10s): " answer || {
    log "INFO" "Timeout reached, reboot canceled."
    return 0
  }

  case "$answer" in
    [yY]|[yY][eE][sS])
      if ! reset_all_permissions "$USER_SSH"; then
        log "WARN" "Proceeding to reboot despite failing to reset permissions."
      fi
      log "INFO" "Rebooting..."
      /sbin/reboot
      exit 0
      ;;
    *)
      log "INFO" "Reboot canceled."
      return 0
      ;;
  esac
}

# === Checks ===
check_root() {
  [[ $EUID -ne 0 ]] && exit_error "Root privileges are required."
}

# ================================================================================
# Функция: ensure_templates
# При первом запуске создаёт $TEMPLATE_DIR и загружает из GitHub все файлы шаблонов
# ================================================================================
ensure_templates() {
  if [[ ! -d "$TEMPLATE_DIR" ]]; then
    mkdir -p "$TEMPLATE_DIR" \
      && log "OK" "Created template dir: $TEMPLATE_DIR" \
      || exit_error "Cannot create template dir: $TEMPLATE_DIR"

    download_repo_dir "script/template" "$TEMPLATE_DIR" \
      || exit_error "Cannot fetch templates"

    log "OK" "Templates loaded into $TEMPLATE_DIR"
  else
    log "DEBUG" "$TEMPLATE_DIR already exists, skipping templates download"
  fi
}

download_repo_dir() {
  local repo_path="${1:?Repository subdir is required (e.g.: docker-proxy)}"
  local target="${2:?Local destination path is required}"
  local repo_owner="${GITHUB_REPO_OWNER:?GITHUB_REPO_OWNER is required}"
  local repo_name="${GITHUB_REPO_NAME:?GITHUB_REPO_NAME is required}"
  local branch="${GITHUB_BRANCH:-$(detect_github_branch)}"
  local auth_token="${GITHUB_TOKEN:-}"
  local repo_url="https://github.com/${repo_owner}/${repo_name}.git"

  # Build authenticated URL if token is provided (warning: visible in process list).
  # Prefer using a credential helper in production environments.
  if [[ -n "$auth_token" ]]; then
    repo_url="https://${repo_owner}:${auth_token}@github.com/${repo_owner}/${repo_name}.git"
  fi

  log "INFO" "Fetching '$repo_path' from '$repo_owner/$repo_name@$branch' into '$target'"

  # Create destination
  mkdir -p "$target" || { log "ERROR" "Failed to create destination: $target"; return 1; }

  # If git is available, prefer sparse-checkout
  if command -v git &>/dev/null; then
    local tmp; tmp="$(mktemp -d)" || { log "ERROR" "Cannot create temp dir"; return 1; }
    # Always clean up temp dir
    local cleanup
    cleanup() {
      [[ -n "${tmp:-}" && -d "$tmp" ]] && rm -rf "$tmp"
    }
    trap cleanup RETURN

    pushd "$tmp" >/dev/null || { log "ERROR" "Cannot cd to temp dir"; return 1; }

    # Init minimal repo
    git init -q || { log "ERROR" "git init failed"; return 1; }
    git remote add origin "$repo_url" || { log "ERROR" "git remote add failed"; return 1; }

    # Enable sparse checkout (support both modern and legacy commands)
    git config core.sparseCheckout true
    if git sparse-checkout -h &>/dev/null; then
      # Modern flow (git >= 2.25): use 'set'
      git sparse-checkout init --cone || { log "ERROR" "sparse-checkout init failed"; return 1; }
      git sparse-checkout set "$repo_path" || { log "ERROR" "sparse-checkout set failed"; return 1; }
    else
      # Legacy flow: write pattern directly
      echo "$repo_path/" > .git/info/sparse-checkout
    fi

    # Shallow fetch of the branch
    if ! git pull --depth=1 origin "$branch" -q; then
      log "ERROR" "git pull failed"
      return 1
    fi
    popd >/dev/null || true

    # Verify that the requested path actually exists in the pulled tree
    if [[ ! -d "$tmp/$repo_path" ]]; then
      log "ERROR" "Subdirectory '$repo_path' not found in repo '$repo_owner/$repo_name' on branch '$branch'"
      return 1
    fi

    # Copy files preserving attrs; verbose warning on partial copy
    if ! cp -a "$tmp/$repo_path/." "$target/"; then
      log "WARN" "Failed to copy all files from '$repo_path'"
    fi

  else
    # Fallback: download repo tarball and extract only the needed subdir
    log "WARN" "git not found; falling back to tarball download (may be larger)"
    local archive_url="https://codeload.github.com/${repo_owner}/${repo_name}/tar.gz/${branch}"
    local curl_args=(-LfsS)
    if [[ -n "$auth_token" ]]; then
      curl_args+=(-H "Authorization: token ${auth_token}")
    fi

    local tarball; tarball="$(mktemp)" || { log "ERROR" "Cannot allocate tarball temp file"; return 1; }
    local cleanup_tarball
    cleanup_tarball() { [[ -f "$tarball" ]] && rm -f "$tarball"; }
    trap cleanup_tarball RETURN

    if ! curl "${curl_args[@]}" -o "$tarball" "$archive_url"; then
      log "ERROR" "Failed to download tarball"
      return 1
    fi

    # GitHub tarball contains top-level dir '<repo_name>-<branch>/...'
    # Extract only the requested subdir if present
    local top_dir="${repo_name}-${branch}"
    if ! tar -tzf "$tarball" "${top_dir}/${repo_path}/" &>/dev/null; then
      log "ERROR" "Subdirectory '$repo_path' not found in tarball"
      return 1
    fi

    # Extract to temp and then copy to target to avoid polluting target with top_dir
    local tmp; tmp="$(mktemp -d)" || { log "ERROR" "Cannot create temp dir"; return 1; }
    local cleanup2
    cleanup2() { [[ -d "$tmp" ]] && rm -rf "$tmp"; }
    trap cleanup2 RETURN

    tar -xzf "$tarball" -C "$tmp" "${top_dir}/${repo_path}/" || { log "ERROR" "Failed to extract tarball"; return 1; }
    if ! cp -a "$tmp/${top_dir}/${repo_path}/." "$target/"; then
      log "WARN" "Failed to copy all files from tarball subdir"
    fi
  fi

  # Make all .sh files executable (non-fatal)
  log "INFO" "Marking *.sh as executable under '$target'"
  find "$target" -type f -name '*.sh' -exec chmod +x {} \; || log "WARN" "chmod on scripts failed"

  log "OK" "Directory '$target' is ready"
  return 0
}

# === ensure_lib_loaded ===
# Просто подключает модуль из $LIB_DIR и логирует
ensure_lib_loaded() {
  local file="$1"
  local local_path="$LIB_DIR/$file"

  if [[ ! -f "$local_path" ]]; then
    exit_error "Module not found: $file in $LIB_DIR"
  fi

  source "$local_path" \
    && log "OK" "Module loaded: $file" \
    || exit_error "Failed to source module: $file"

  LOADED_MODULES+=("$file")
}

# === load_all_modules ===
# Если в $LIB_DIR нет NN_*.sh, то клонируем через git sparse-checkout только папку script/modules,
# копируем её содержимое в $LIB_DIR и удаляем временный клон. После этого source каждого файла.
load_all_modules() {
  mkdir -p "$LIB_DIR"

  # проверяем, есть ли уже локальные модули вида NN_*.sh
  if ! compgen -G "$LIB_DIR"/[0-9][0-9]_*.sh > /dev/null; then
    log "INFO" "Fetching modules via git sparse-checkout"
    download_repo_dir "script/modules" "$LIB_DIR" \
      || exit_error "Failed to fetch modules"
  else
    log "DEBUG" "Local modules already exist, skipping git fetch"
  fi

  # теперь source всех модулей
  LOADED_MODULES=()
  for path in "$LIB_DIR"/[0-9][0-9]_*.sh; do
    [[ -f "$path" ]] || continue
    ensure_lib_loaded "$(basename "$path")"
  done

  if (( ${#LOADED_MODULES[@]} > 0 )); then
    log "INFO" "Modules loaded: ${LOADED_MODULES[*]}"
  else
    log "WARN" "No modules found in $LIB_DIR"
  fi
}

# === Initialization ===
initialize_script() {
  [[ -f "$LOG_FILE" ]] && rm -f "$LOG_FILE"
  check_root
  ensure_templates
  load_all_modules
  check_LOG_FILE
  ensure_directory_exists "$LOGS_DIR"
  ensure_file_exists "$LOG_FILE"
  check_system_resources
  check_required_commands
  install_packages
  envfile_script
  yq_install
  type check_required_commands &>/dev/null || exit_error "Missing function: check_required_commands (module not loaded?)"
  reset_all_permissions
}

initialize_script
main_menu "$@"
