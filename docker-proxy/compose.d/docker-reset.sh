#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=false
ASSUME_YES=false
SHOW_MENU=false
declare -a ACTIONS=()

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME [options] [actions...]

Actions:
  containers   Remove all containers
  images       Remove all images
  volumes      Remove all volumes
  cache        Prune Docker build cache
  networks     Remove user-defined networks
  all          containers + images + volumes + cache (keeps networks)
  everything   containers + images + volumes + cache + networks

Options:
  -m, --menu    Show interactive menu
  -y, --yes     Do not ask for confirmation
  -n, --dry-run Print commands without executing them
  -h, --help    Show this help

Examples:
  $SCRIPT_NAME --menu
  $SCRIPT_NAME --yes all
  $SCRIPT_NAME --dry-run containers images
EOF
}

log() {
  echo "[reset-docker-hard] $*"
}

die() {
  echo "[reset-docker-hard] ERROR: $*" >&2
  exit 1
}

add_action() {
  local action="$1"

  case "$action" in
    containers|images|volumes|cache|networks)
      ACTIONS+=("$action")
      ;;
    all)
      ACTIONS+=(containers images volumes cache)
      ;;
    everything)
      ACTIONS+=(containers images volumes cache networks)
      ;;
    *)
      die "Unknown action: $action"
      ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--menu)
        SHOW_MENU=true
        ;;
      -y|--yes)
        ASSUME_YES=true
        ;;
      -n|--dry-run)
        DRY_RUN=true
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          add_action "$1"
          shift
        done
        return
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        add_action "$1"
        ;;
    esac
    shift
  done
}

contains_action() {
  local needle="$1"
  local action

  for action in "${ACTIONS[@]}"; do
    [[ "$action" == "$needle" ]] && return 0
  done
  return 1
}

dedupe_actions() {
  local unique=()
  local action

  for action in containers images volumes cache networks; do
    if contains_action "$action"; then
      unique+=("$action")
    fi
  done

  ACTIONS=("${unique[@]}")
}

toggle_action() {
  local action="$1"
  local next=()
  local current
  local found=false

  for current in "${ACTIONS[@]}"; do
    if [[ "$current" == "$action" ]]; then
      found=true
      continue
    fi
    next+=("$current")
  done

  if [[ "$found" == "false" ]]; then
    next+=("$action")
  fi

  ACTIONS=("${next[@]}")
  dedupe_actions
}

show_selected() {
  if [[ ${#ACTIONS[@]} -eq 0 ]]; then
    echo "Selected: none"
  else
    echo "Selected: ${ACTIONS[*]}"
  fi
}

clear_menu_screen() {
  if [[ -t 0 && -t 1 ]]; then
    clear
  fi
}

menu_mark() {
  local action="$1"

  if contains_action "$action"; then
    printf '[x]'
  else
    printf '[ ]'
  fi
}

menu() {
  while true; do
    clear_menu_screen
    echo "Docker reset menu"
    printf "1) %s Toggle containers removal\n" "$(menu_mark containers)"
    printf "2) %s Toggle images removal\n" "$(menu_mark images)"
    printf "3) %s Toggle volumes removal\n" "$(menu_mark volumes)"
    printf "4) %s Toggle build cache prune\n" "$(menu_mark cache)"
    printf "5) %s Toggle networks removal\n" "$(menu_mark networks)"
    echo "6) Select all except networks"
    echo "7) Select everything"
    echo "8) Clear selection"
    echo "9) Run selected actions"
    echo "0) Exit"
    show_selected
    printf "Choose: "
    read -r choice

    case "$choice" in
      1) toggle_action containers ;;
      2) toggle_action images ;;
      3) toggle_action volumes ;;
      4) toggle_action cache ;;
      5) toggle_action networks ;;
      6) ACTIONS=(containers images volumes cache) ;;
      7) ACTIONS=(containers images volumes cache networks) ;;
      8) ACTIONS=() ;;
      9) break ;;
      0) exit 0 ;;
      *) echo "Unknown choice: $choice" ;;
    esac
  done
}

confirm() {
  if [[ "$ASSUME_YES" == "true" ]]; then
    return
  fi

  echo
  echo "WARNING: selected actions will DELETE Docker resources."
  show_selected
  echo "Press Enter or type yes to continue. Type no or press Ctrl+C to cancel."
  read -r answer

  case "${answer,,}" in
    ""|y|yes|д|да)
      return
      ;;
    n|no|н|нет)
      die "Cancelled"
      ;;
    *)
      die "Cancelled"
      ;;
  esac
}

run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

ensure_docker_running() {
  log "Stopping Docker services..."
  run_cmd systemctl stop docker.socket 2>/dev/null || true
  run_cmd systemctl stop docker.service 2>/dev/null || true
  run_cmd systemctl stop containerd.service 2>/dev/null || true

  log "Starting Docker temporarily for cleanup..."
  run_cmd systemctl start containerd.service 2>/dev/null || true
  run_cmd systemctl start docker.service
}

remove_containers() {
  mapfile -t items < <(docker ps -aq)
  if [[ ${#items[@]} -eq 0 ]]; then
    log "No containers to remove"
    return
  fi

  log "Removing containers: ${#items[@]}"
  run_cmd docker rm -f "${items[@]}"
}

remove_images() {
  mapfile -t items < <(docker images -aq)
  if [[ ${#items[@]} -eq 0 ]]; then
    log "No images to remove"
    return
  fi

  log "Removing images: ${#items[@]}"
  run_cmd docker rmi -f "${items[@]}"
}

remove_volumes() {
  mapfile -t items < <(docker volume ls -q)
  if [[ ${#items[@]} -eq 0 ]]; then
    log "No volumes to remove"
    return
  fi

  log "Removing volumes: ${#items[@]}"
  run_cmd docker volume rm "${items[@]}"
}

remove_networks() {
  mapfile -t items < <(docker network ls --filter type=custom --format '{{.Name}}')
  if [[ ${#items[@]} -eq 0 ]]; then
    log "No user-defined networks to remove"
    return
  fi

  log "Removing user-defined networks: ${#items[@]}"
  run_cmd docker network rm "${items[@]}"
}

prune_cache() {
  log "Cleaning build cache..."
  run_cmd docker builder prune -a -f
}

run_actions() {
  local total="${#ACTIONS[@]}"
  local index=1
  local action

  for action in "${ACTIONS[@]}"; do
    log "[$index/$total] Running action: $action"
    case "$action" in
      containers) remove_containers ;;
      images) remove_images ;;
      volumes) remove_volumes ;;
      cache) prune_cache ;;
      networks) remove_networks ;;
    esac
    index=$((index + 1))
  done
}

parse_args "$@"

if [[ "$SHOW_MENU" == "true" || ${#ACTIONS[@]} -eq 0 ]]; then
  menu
fi

dedupe_actions
[[ ${#ACTIONS[@]} -gt 0 ]] || die "No actions selected"

confirm
ensure_docker_running
run_actions

echo
if contains_action networks; then
  log "Docker cleanup finished. Current networks:"
else
  log "Docker cleanup finished. Networks preserved:"
fi
run_cmd docker network ls
