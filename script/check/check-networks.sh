#!/bin/bash
# Быстрая проверка docker-сетей и подсетей на пересечения/наличие.
# Требуется: docker в PATH. Опционально jq для наглядности.

set -euo pipefail

NEEDED=(
  "traefik-proxy:172.18.0.0/24"
  "dns-net:172.19.0.0/24"
)

log() {
  printf '[check-networks] %s\n' "$*" >&2
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log "ERROR: docker не найден в PATH"
    exit 1
  fi
}

network_subnets() {
  local net="$1"
  docker network inspect "$net" --format '{{range .IPAM.Config}}{{if .Subnet}}{{.Subnet}} {{end}}{{end}}' 2>/dev/null
}

list_all_subnets() {
  docker network ls -q \
    | xargs -r docker network inspect --format '{{.Name}} {{range .IPAM.Config}}{{if .Subnet}}{{.Subnet}} {{end}}{{end}}'
}

main() {
  ensure_docker

  log "Все сети и их подсети:"
  list_all_subnets || true
  echo

  for item in "${NEEDED[@]}"; do
    IFS=":" read -r name subnet <<<"$item"
    local_subnets="$(network_subnets "$name")"

    if [[ -z "$local_subnets" ]]; then
      log "WARN: сеть '$name' не найдена. Ожидаемая подсеть: $subnet"
      continue
    fi

    log "INFO: сеть '$name' найдена. Подсети: $local_subnets"
    if ! grep -qw "$subnet" <<<"$local_subnets"; then
      log "WARN: у сети '$name' нет ожидаемой подсети $subnet"
    fi
  done

  echo
  log "Поиск других сетей с теми же подсетями:"
  for item in "${NEEDED[@]}"; do
    IFS=":" read -r name subnet <<<"$item"
    matches=$(list_all_subnets | grep -w "$subnet" | grep -v "^$name " || true)
    if [[ -n "$matches" ]]; then
      log "WARN: подсеть $subnet также используется сетью(ями):"
      echo "$matches"
    fi
  done
}

main "$@"
