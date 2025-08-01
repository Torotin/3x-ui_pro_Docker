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
DOCKER_COMPOSE_FILE="$DOCKER_DIR/docker-compose.yml"
DOCKER_ENV_FILE="$DOCKER_DIR/.env"
DOCKER_ENV_TEMPLATE="$TEMPLATE_DIR/docker.env.template"
LOADED_MODULES=()
GITHUB_REPO_RAW="${GITHUB_REPO_RAW:-}"
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
  check_LOG_FILE
  ensure_directory_exists "$LOGS_DIR"
  ensure_file_exists "$LOG_FILE"
  check_system_resources
  check_required_commands
  install_packages
  yq_install
  type check_required_commands &>/dev/null || exit_error "Missing function: check_required_commands (module not loaded?)"
}

# === Load Modules ===
# Utility functions to load shell script modules from local or remote sources.

# Ensure a library module is loaded, fetching from remote if not present locally.
ensure_lib_loaded() {
  local file="$1"
  local local_path="$LIB_DIR/$file"
  local remote_url="${GITHUB_REPO_RAW}/modules/$file"

  # Try to source locally first
  if [[ -f "$local_path" ]]; then
    if source "$local_path"; then
      log "OK" "Module loaded locally: $file"
    else
      exit_error "Failed to source: $file"
    fi

  # If not found locally, try to fetch from remote
  elif [[ -n "$GITHUB_REPO_RAW" ]]; then
    mkdir -p "$LIB_DIR"
    if curl -fsSL "$remote_url" -o "$local_path"; then
      if source "$local_path"; then
        log "OK" "Module loaded from GitHub: $file"
      else
        exit_error "Failed to source downloaded: $file"
      fi
    else
      exit_error "Failed to fetch: $file"
    fi

  # If neither, fail
  else
    exit_error "Module $file not found and no remote repo defined."
  fi

  # Track loaded modules
  LOADED_MODULES+=("$file")
}

# Load all modules matching the pattern 00_*.sh to 10_*.sh in $LIB_DIR
load_all_modules() {
  shopt -s nullglob
  local found_modules=0
  for module in "$LIB_DIR"/{00..10}_*.sh; do
    ensure_lib_loaded "$(basename "$module")"
    ((found_modules++))
  done
  shopt -u nullglob

  if (( found_modules > 0 )); then
    log "INFO" "Modules loaded:"
    for mod in "${LOADED_MODULES[@]}"; do
      log "OK" " - $mod"
    done
  else
    log "WARN" "No modules found in $LIB_DIR"
  fi
}

# main() {
#     if [[ -z "${CI:-}" ]] && tty -s; then clear; fi
#     log "INFO" "Starting installation script..."
#     check_root
#     # === LOAD ALL MODULES ===
#     load_all_modules
#     # === INITIALIZATION ===
#     initialize_script
#     # === SYSTEM UPDATE ===
#     update_and_upgrade_packages
#     # === PROCESS .env ===
#     envfile_script
#     # === DOCKER INSTALLATION ===
#     docker_install
#     # docker_setup_ipv6
#     # docker_create_ipv6_network
#     # Ensure DOCKER_DIR exists
#     if [[ ! -d "$DOCKER_DIR" ]]; then
#       mkdir -p "$DOCKER_DIR" || exit_error "Failed to create Docker directory: $DOCKER_DIR"
#       log "INFO" "Created Docker directory: $DOCKER_DIR"
#     fi
#     # === CONFIG GENERATION ===
#     generate_env_file "$DOCKER_ENV_TEMPLATE" "$DOCKER_ENV_FILE"
#     # docker_compose_generate
#     # === NETWORK OPTIMIZATION ===
#     network_config_modify
#     # === USER SETUP ===
#     #user_create
#     # === FIREWALL ===
#     #firewall_config
#     # === SSH CONFIGURATION ===
#     #sshd_config
#     # === HTML TEMPLATE ===
#     # random_html
#     # === FINALIZATION ===
#     msg_final
#     exit_script
# }


# === Массив шагов ===
declare -A INSTALL_STEPS=(
  ["0"]="auto_full:Automatic full install"
  ["1"]="update_and_upgrade_packages:System update"
  ["2"]="docker_install;docker_create_network traefik-proxy external:Docker. Install"
  ["3"]="ensure_docker_dir;generate_env_docker:Docker. Generate .env file"
  ["4"]="user_create:Create user"
  ["5"]="firewall_config:Configure firewall"
  ["6"]="sshd_config:Configure SSH"
  ["7"]="network_config_modify:Network optimization"
  ["8"]="msg_final:Final message"
  ["x"]="exit_script:Exit"
)

# === Steps that require parameters ===
generate_env_docker() {
  generate_env_file "$DOCKER_ENV_TEMPLATE" "$DOCKER_ENV_FILE"
}

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
  echo "Select steps to execute (e.g., 1 3 5 7 or 1-6):"

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
  local tokens=()
  local expanded=()

  read -r -a tokens <<< "$(echo "$raw_input" | tr ',' ' ')"

  for token in "${tokens[@]}"; do
    token="$(echo "$token" | xargs)"
    if [[ "$token" =~ ^[0-9]+$ ]]; then
      expanded+=("$token")
    elif [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      for ((i=${BASH_REMATCH[1]}; i<=${BASH_REMATCH[2]}; i++)); do
        expanded+=("$i")
      done
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
  check_root
  load_all_modules
  initialize_script
  envfile_script

  while true; do
    if [[ -z "${CI:-}" ]] && tty -s; then clear; fi

    show_menu
    read -r input

    mapfile -t selected < <(parse_step_selection "$input")

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