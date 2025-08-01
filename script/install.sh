#!/bin/bash
# ./install.sh — Main installation script

# === Parameters and Variables ===
LOGLEVEL="DEBUG"
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
GITHUB_REPO_NAME="${REPO_OWNER:-3x-ui_pro_Docker}"
LOADED_MODULES=()

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
exit_error() {
  log "ERROR" "$1"
  exit 1
}

exit_script() {
  chmod -f -R 777 "$PROJECT_ROOT"
  log "INFO" "Script completed."
  exit 0
}

# === Checks ===
check_root() {
  [[ $EUID -ne 0 ]] && exit_error "Root privileges are required."
}

check_LOG_FILE() {
  if [[ -z "${LOG_FILE:-}" || ! -f "$LOG_FILE" || ! -w "$LOG_FILE" ]]; then
    mkdir -p "$LOGS_DIR" || exit_error "Cannot create logs directory: $LOGS_DIR"
    LOG_FILE="$LOGS_DIR/${LOG_NAME}.log"
    touch "$LOG_FILE" || exit_error "Cannot create log file: $LOG_FILE"
    log "WARN" "Using fallback log file: $LOG_FILE"
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
}

download_repo_dir() {
  local repo_path="${1:?Не задан путь в репозитории (например: docker-proxy)}"
  local target="${2:?Не задан локальный путь назначения}"
  local repo_owner="${GITHUB_REPO_OWNER:?Не задан GITHUB_REPO_OWNER}"
  local repo_name="${GITHUB_REPO_NAME:?Не задан GITHUB_REPO_NAME}"
  local branch="${GITHUB_BRANCH:-main}"
  local auth_token="${GITHUB_TOKEN:-}"
  local repo_url

  # Сборка URL
  if [[ -n "$auth_token" ]]; then
    repo_url="https://${auth_token}@github.com/${repo_owner}/${repo_name}.git"
  else
    repo_url="https://github.com/${repo_owner}/${repo_name}.git"
  fi

  log "INFO" "Клонирую папку '$repo_path' из '$repo_owner/$repo_name' через git sparse-checkout → '$target'"

  # Проверка наличия git
  if ! command -v git &>/dev/null; then
    log "ERROR" "git не установлен, невозможно скачать через git"
    return 1
  fi

  # Временная папка
  local tmp
  tmp=$(mktemp -d) || { log "ERROR" "Не удалось создать временную папку"; return 1; }

  # sparse-checkout
  pushd "$tmp" >/dev/null || { log "ERROR" "Не удалось перейти в $tmp"; rm -rf "$tmp"; return 1; }
  git init -q
  git remote add origin "$repo_url"
  git config core.sparseCheckout true
  echo "$repo_path/" > .git/info/sparse-checkout
  if ! git pull --depth=1 origin "$branch" -q; then
    log "ERROR" "git pull не удался"
    popd >/dev/null
    rm -rf "$tmp"
    return 1
  fi
  popd >/dev/null

  # Копирование
  mkdir -p "$target" \
    || { log "ERROR" "Не удалось создать каталог назначения: $target"; rm -rf "$tmp"; return 1; }
  cp -a "$tmp/$repo_path/." "$target/" \
    || log "WARN" "Не удалось скопировать все файлы из $repo_path"

  rm -rf "$tmp"

  # +x для .sh файлов
  log "INFO" "Назначаю +x всем .sh-файлам в '$target'"
  find "$target" -type f -name '*.sh' -exec chmod +x -v {} \;
  log "OK" "Папка '$target' успешно загружена через git"
  return 0
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

# === Массив шагов ===
declare -A INSTALL_STEPS=(
  ["0"]="auto_full:Automatic full install"
  ["1"]="update_and_upgrade_packages:System update"
  ["2"]="docker_install;docker_create_network traefik-proxy external:Docker. (Re)Install"
  ["3"]="ensure_docker_dir;download_repo_dir "docker-proxy" "${DOCKER_DIR}";generate_env_file "$DOCKER_ENV_TEMPLATE" "$DOCKER_ENV_FILE":Docker. Generate docker dir"
  ["4"]="user_create:Create user"
  ["5"]="firewall_config:Configure firewall"
  ["6"]="sshd_config:Configure SSH"
  ["7"]="network_config_modify:Network optimization"
  ["8"]="docker compose --env-file "$DOCKER_ENV_FILE" -f "$DOCKER_COMPOSE_FILE" up -d:Docker. Run Compose"
  ["9"]="msg_final:Final message"
  ["x"]="exit_script:Exit"
)

ensure_docker_dir() {
  if [[ ! -d "$DOCKER_DIR" ]]; then
    mkdir -p "$DOCKER_DIR" || exit_error "Failed to create directory: $DOCKER_DIR"
    log "INFO" "Docker directory created: $DOCKER_DIR"
  else
    log "INFO" "$DOCKER_DIR already exists"
  fi
}

# === Menu display ===
show_menu() {
  echo "Select steps to execute (1,3 5 7 or 1-6):"

  local sorted_keys
  IFS=$'\n' sorted_keys=($(printf "%s\n" "${!INSTALL_STEPS[@]}" | sort -V))  # поддержка и чисел, и 'x'

  for key in "${sorted_keys[@]}"; do
    IFS=":" read -r func desc <<< "${INSTALL_STEPS[$key]}"
    printf " %3s) %-30s\n" "$key" "$desc"
  done
  echo -n "> "
}

parse_step_selection() {
  local raw_input="$1"
  local expanded=()
  raw_input="$(echo "$raw_input" | tr ',' ' ' | xargs)"

  IFS=' ' read -r -a tokens <<< "$raw_input"

  for token in "${tokens[@]}"; do
    if [[ "$token" =~ ^[0-9]+-[0-9]+$ ]]; then
      local start="${token%-*}"
      local end="${token#*-}"
      if [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && $start -le $end ]]; then
        for ((i=start; i<=end; i++)); do
          expanded+=("$i")
        done
      fi
    elif [[ "$token" =~ ^[0-9]+$ ]]; then
      expanded+=("$token")
    elif [[ "$token" =~ ^[a-zA-Z]+$ ]]; then
      expanded+=("$token")
    fi
  done

  for item in "${expanded[@]}"; do
    echo "$item"
  done
}

auto_full() {
  log "INFO" "Running all steps (auto mode)..."

  # Собираем только цифровые шаги, кроме "0"
  local keys=()
  for key in "${!INSTALL_STEPS[@]}"; do
    [[ "$key" =~ ^[0-9]+$ ]] || continue
    [[ "$key" == "0" ]] && continue
    keys+=("$key")
  done

  # Сортируем по возрастанию
  IFS=$'\n' keys_sorted=($(sort -n <<<"${keys[*]}"))
  unset IFS

  for key in "${keys_sorted[@]}"; do
    entry="${INSTALL_STEPS[$key]}"
    IFS=':' read -r cmds desc <<< "$entry"

    log "SEP"
    log "TITLE" "Step $key: $desc"

    # Разбиваем на отдельные команды по ';'
    IFS=';' read -r -a cmd_array <<< "$cmds"
    for cmd in "${cmd_array[@]}"; do
      # Тримим пробелы
      cmd="${cmd#"${cmd%%[![:space:]]*}"}"
      cmd="${cmd%"${cmd##*[![:space:]]}"}"

      # Отделяем имя команды/функции
      cmd_name="${cmd%% *}"

      if [[ -n "$(type -t "$cmd_name")" ]]; then
        log "INFO" "Executing: $cmd"
        eval "$cmd"
      else
        log "WARN" "Command or function '$cmd_name' not found, skipping."
      fi
    done
  done

  echo -e "\nAll steps complete. Press Enter to return to menu..."
  read -r
}


main() {
  if [[ -z "${CI:-}" ]] && tty -s; then clear; fi
  log "INFO" "Starting installation script..."
  initialize_script

  while true; do
    if [[ -z "${CI:-}" ]] && tty -s; then clear; fi

    show_menu
    read -r input

    selected=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && selected+=("$line")
    done < <(parse_step_selection "$input")

    for key in "${selected[@]}"; do
      key="$(echo "$key" | xargs)"  # очистка пробелов

      entry="${INSTALL_STEPS[$key]:-}"
      if [[ -z "$entry" ]]; then
        log "WARN" "Unknown or missing step: $key"
        continue
      fi

      # разбиваем на команды и описание
      IFS=':' read -r cmds desc <<< "$entry"

      log "SEP"
      log "TITLE" "Step $key: $desc"

      # разбиваем cmds по ';' и выполняем каждую
      IFS=';' read -r -a cmd_array <<< "$cmds"
      for cmd in "${cmd_array[@]}"; do
        # убираем ведущие/хвостовые пробелы
        cmd="${cmd#"${cmd%%[![:space:]]*}"}"
        cmd="${cmd%"${cmd##*[![:space:]]}"}"
        [[ -z "$cmd" ]] && continue

        # проверяем, существует ли команда/функция
        cmd_name="${cmd%% *}"
        if [[ -n "$(type -t "$cmd_name")" ]]; then
          log "INFO" "Executing: $cmd"
          eval "$cmd"
        else
          log "WARN" "Command or function '$cmd_name' not found, skipping."
        fi
      done

      # если шаг — выход, прерываем main
      if [[ "$cmds" == *"exit_script"* ]]; then
        return
      fi
    done

    echo -e "\nPress Enter to return to the menu..."
    read -r
    clear
  done
}

main "$@"