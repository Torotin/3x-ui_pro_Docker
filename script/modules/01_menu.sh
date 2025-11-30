#!/bin/bash
# lib/01_menu.sh — Menu utility functions

install_steps_init() {
  # Глобально объявляем ассоциативный массив (вариант 2 — достаточно этого):
  declare -gA INSTALL_STEPS=(
    ["0"]='auto_full:Automatic full install'
    ["1"]='update_and_upgrade_packages:System update'
    ["2"]='docker_install;docker_create_network traefik-proxy external subnet=172.18.0.0/24:Docker. (Re)Install'
    ["3"]='ensure_docker_dir;download_repo_dir "docker-proxy" "${DOCKER_DIR}";:Docker. Generate docker dir'
    ["4"]='generate_env_file "'$DOCKER_ENV_TEMPLATE'" "'$DOCKER_ENV_FILE'":Docker. Generate docker env-file'
    ["5"]='user_create:Create user'
    ["6"]='firewall_config:Configure firewall'
    ["7"]='sshd_config:Configure SSH'
    ["8"]='network_config_modify:Network optimization'
    ["9"]='docker_compose_restart:Docker. Compose (re)start'
    ["10"]='msg_final:Final message'
    ["x"]='exit_script:Exit'
    ["r"]='reboot_system:Reboot'
  )
}

show_menu() {
  install_steps_init
  echo "Select steps to execute (1,3 5 7 or 1-6):"

  local sorted_keys
  IFS=$'\n' read -r -d '' -a sorted_keys < <(printf "%s\n" "${!INSTALL_STEPS[@]}" | sort -V && printf '\0')

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

check_args() {
  # Если переданы аргументы — воспринимаем их как список шагов и сразу выполняем
  if (( $# > 0 )); then
    log "INFO" "Запуск в неинтерактивном режиме: шаги = $*"
    # Разбор указанных шагов (в том числе диапазонов) функцией parse_step_selection
    selected=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && selected+=("$line")
    done < <(parse_step_selection "$*")

    for key in "${selected[@]}"; do
      key="$(echo "$key" | xargs)"
      entry="${INSTALL_STEPS[$key]:-}"
      if [[ -z "$entry" ]]; then
        log "WARN" "Unknown or missing step: $key"
        continue
      fi

      IFS=':' read -r cmds desc <<< "$entry"
      log "SEP"
      log "TITLE" "Step $key: $desc"
      IFS=';' read -r -a cmd_array <<< "$cmds"
      for cmd in "${cmd_array[@]}"; do
        cmd="${cmd#"${cmd%%[![:space:]]*}"}"
        cmd="${cmd%"${cmd##*[![:space:]]}"}"
        if [[ -n "$(type -t "${cmd%% *}")" ]]; then
          log "INFO" "Executing: $cmd"
          eval "$cmd"
        else
          log "WARN" "Command or function '${cmd%% *}' not found, skipping."
        fi
      done
    done
    exit_script
  fi
}


main_menu() {
  if [[ -z "${CI:-}" ]] && tty -s; then clear; fi
  log "INFO" "Starting installation script..."
  initialize_script
  check_args "$@"

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