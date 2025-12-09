#!/bin/bash
# lib/02_docker.sh
# Enhanced Docker management functions: install, uninstall, clear, compose, and network setup.

# === Глобальные переменные проекта ===
: "${PROJECT_ROOT:=/mnt/share}"
: "${BACKUP_DIR:=${PROJECT_ROOT}/backup}"
: "${TEMPLATE_DIR:=${PROJECT_ROOT}/template}"
: "${DOCKER_DAEMON_FILE:=/etc/docker/daemon.json}"
: "${DOCKER_NETWORK_NAME:=my-ipv6-network}"
: "${DOCKER_IPV6_SUBNET:=fd00:dead:beef::/64}"

# --- Ensure Docker directory exists ---
ensure_docker_dir() {
  if [[ ! -d "$DOCKER_DIR" ]]; then
    mkdir -p "$DOCKER_DIR" || exit_error "Failed to create directory: $DOCKER_DIR"
    log "INFO" "Docker directory created: $DOCKER_DIR"
  else
    log "INFO" "$DOCKER_DIR already exists"
  fi
}

# --- Get Linux distribution ---
get_linux_distro() {
    lsb_release -si | tr '[:upper:]' '[:lower:]'
}

# --- Docker Repository Setup ---
docker_install_repo() {
    local distro
    distro=$(get_linux_distro)
    case "$distro" in
        ubuntu|debian)
            log "INFO" "Setting up Docker repository for Ubuntu/Debian."
            mkdir -p /etc/apt/keyrings
            if [ -f /etc/apt/keyrings/docker.gpg ]; then
                log "INFO" "Key file /etc/apt/keyrings/docker.gpg exists. Removing before download."
                rm -f /etc/apt/keyrings/docker.gpg || log "ERROR" "Failed to remove old key file."
            fi
            curl -fsSL "https://download.docker.com/linux/$distro/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg || log "ERROR" "Failed to set up Docker GPG key."
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$distro $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
            apt update &>/dev/null || log "ERROR" "Failed to update packages after repo setup."
            ;;
        centos|fedora)
            log "INFO" "Setting up Docker repository for CentOS/Fedora."
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || log "ERROR" "Failed to add Docker repo."
            ;;
        *)
            log "ERROR" "Distribution $distro not supported."
            exit 1
            ;;
    esac
}

# --- Docker Uninstall and Cleanup ---
docker_uninstall() {
    log "INFO" "Starting Docker uninstall."
    if command_exists docker; then
        docker_clear
    else
        log "INFO" "Docker not installed. Skipping removal."
    fi

    local distro
    distro=$(get_linux_distro)
    case "$distro" in
        ubuntu|debian)
            log "INFO" "Removing Docker packages."
            apt remove -y docker-ce docker-ce-cli containerd.io &>/dev/null || log "ERROR" "Failed to remove Docker."
            ;;
        centos|fedora)
            log "INFO" "Removing Docker packages via yum."
            yum remove -y docker-ce docker-ce-cli containerd.io &>/dev/null || log "ERROR" "Failed to remove Docker."
            ;;
        *)
            log "ERROR" "Distribution $distro not supported."
            exit 1
            ;;
    esac

    log "INFO" "Removing Docker data."
    rm -rf /var/lib/docker /var/lib/containerd &>/dev/null || log "ERROR" "Failed to remove Docker data."
}

docker_clear() {
    log "INFO" "Starting full Docker cleanup."
    if ! command_exists docker; then
        log "WARN" "Docker command not available. Skipping cleanup."
        return 1
    fi

    # Stop all containers
    local containers
    containers=$(docker ps -aq)
    if [ -n "$containers" ]; then
        log "INFO" "Stopping all containers..."
        docker stop $containers &>/dev/null || log "INFO" "Some containers could not be stopped."
        log "INFO" "Removing all containers..."
        docker rm $containers &>/dev/null || log "INFO" "Some containers could not be removed."
    else
        log "INFO" "No containers to stop or remove."
    fi

    # Remove all images
    local images
    images=$(docker images -q)
    if [ -n "$images" ]; then
        log "INFO" "Removing all images..."
        docker rmi $images --force &>/dev/null || log "INFO" "Some images could not be removed."
    else
        log "INFO" "No images to remove."
    fi

    # Remove all volumes
    local volumes
    volumes=$(docker volume ls -q)
    if [ -n "$volumes" ]; then
        log "INFO" "Removing all volumes..."
        docker volume rm $volumes &>/dev/null || log "INFO" "Some volumes could not be removed."
    else
        log "INFO" "No volumes to remove."
    fi

    # Remove all custom networks
    local networks
    networks=$(docker network ls --filter type=custom -q)
    if [ -n "$networks" ]; then
        log "INFO" "Removing all custom networks..."
        docker network rm $networks &>/dev/null || log "INFO" "Some networks could not be removed."
    else
        log "INFO" "No custom networks to remove."
    fi

    # Prune system
    log "INFO" "Pruning Docker system (cache, temp data)..."
    docker system prune -a --volumes --force &>/dev/null || log "ERROR" "Error during Docker system prune."

    # Restart Docker
    log "INFO" "Restarting Docker service..."
    systemctl restart docker &>/dev/null || log "ERROR" "Failed to restart Docker service."

    log "INFO" "Docker cleanup complete."
}

# --- Docker Installation ---
docker_install() {
    log "INFO" "Starting Docker installation."

    if command_exists docker; then
        log "INFO" "Docker already installed. Removing..."
        docker_clear
        docker_uninstall
    else
        log "INFO" "Docker not found. Proceeding with installation..."
    fi

    local distro
    distro=$(get_linux_distro)
    case "$distro" in
        ubuntu|debian)
            log "INFO" "🔄 Updating package list..."
            apt-get update -qq >/dev/null || exit_error "Error updating packages!"

            log "INFO" "📦 Installing dependencies..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            ca-certificates curl gnupg lsb-release >/dev/null || \
            exit_error "Failed to install dependencies!"

            log "INFO" "⚙ Setting up Docker repository..."
            docker_install_repo
            docker_install_packages
            ;;

        centos|fedora|rocky|almalinux|amazonlinux)
            log "INFO" "🔄 Installing yum-utils and setting up repository..."
            yum install -y -q yum-utils >/dev/null || \
              exit_error "Failed to install yum-utils!"
            docker_install_repo
            docker_install_packages
            ;;

        *)
            exit_error "Distribution '$distro' not supported."
            ;;
    esac

    log "INFO" "🚀 Enabling Docker to start on boot..."
    if systemctl enable --now docker >/dev/null 2>&1; then
        log "INFO" "Docker started and enabled at boot."
    else
        log "ERROR" "Error starting Docker!"
        systemctl status docker --no-pager -l
        exit 1
    fi

    log "INFO" "Docker installed successfully!"
}

docker_install_packages() {
    local distro
    distro=$(get_linux_distro)
    case "$distro" in
        ubuntu|debian)
            log "INFO" "Installing Docker and related components for Ubuntu/Debian."
            apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin &>/dev/null || log "ERROR" "Failed to install Docker."
            ;;
        centos|fedora)
            log "INFO" "Installing Docker and related components for CentOS/Fedora."
            yum install -y docker-ce docker-ce-cli containerd.io &>/dev/null || log "ERROR" "Failed to install Docker."
            ;;
        *)
            log "ERROR" "Distribution $distro not supported."
            exit 1
            ;;
    esac
}

# --- Docker IPv6 Setup ---
docker_setup_ipv6() {
    log "INFO" "Configuring IPv6 for Docker."
    local daemon_file="$DOCKER_DAEMON_FILE"
    if [ -f "$daemon_file" ]; then
        log "WARN" "$daemon_file exists. Creating backup."
        cp "$daemon_file" "${daemon_file}.bak.$(date +"%Y%m%d%H%M%S")"
    fi
    mkdir -p "$(dirname "$daemon_file")"
    cat > "$daemon_file" <<EOF
{
  "ipv6": true,
  "fixed-cidr-v6": "fd00:dead:aaaa::/64"
}
EOF
    log "INFO" "Restarting Docker to apply IPv6 settings."
    systemctl restart docker || log "ERROR" "Failed to restart Docker service."
}
#!/bin/bash

# Создаёт Docker-сеть с нужными опциями, если её ещё нет
# Usage:
#   docker_create_network NAME [external] [ipv6] [subnet=<CIDR>]
# 1) Создаём внешнюю сеть traefik-proxy (для docker-compose external: true)
# docker_create_network traefik-proxy external
# 2) Создаём свою сеть с IPv6 и подсетью
#    Имя, которое задаётся в переменной DOCKER_NETWORK_NAME
#    и подсеть — в DOCKER_IPV6_SUBNET
# docker_create_network "$DOCKER_NETWORK_NAME" ipv6 subnet="$DOCKER_IPV6_SUBNET"
docker_create_network() {
    local name="$1"; shift
    local is_external=false
    local is_ipv6=false
    local subnet=""

    # Разбираем ключи
    for opt in "$@"; do
        case "$opt" in
            external)   is_external=true ;;
            ipv6)       is_ipv6=true ;;
            subnet=*)   subnet="${opt#subnet=}" ;;
            *)          log "WARN" "Unknown option '$opt' for docker_create_network" ;;
        esac
    done

    # Проверяем наличие docker
    if ! command_exists docker; then
        log "ERROR" "docker is not installed or not in PATH"
        exit 1
    fi

    # Если уже есть — ничего не делаем, но сверяем подсеть (если задана)
    if docker network inspect "$name" &>/dev/null; then
        log "INFO" "Network '$name' already exists, skipping creation."
        if [[ -n "$subnet" ]]; then
          local existing_subnets
          existing_subnets=$(docker network inspect "$name" --format '{{range .IPAM.Config}}{{if .Subnet}}{{.Subnet}} {{end}}{{end}}' 2>/dev/null)
          if ! grep -qw "$subnet" <<<"$existing_subnets"; then
            log "WARN" "Network '$name' exists, but expected subnet '$subnet' not found (have: $existing_subnets)"
          fi
        fi
        return 0
    fi

    # Предварительная проверка на совпадение подсетей с другими сетями (чтобы не словить invalid pool request)
    if [[ -n "$subnet" ]]; then
      local overlap
      overlap=$(docker network ls -q | xargs -r docker network inspect --format '{{.Name}} {{range .IPAM.Config}}{{if .Subnet}}{{.Subnet}} {{end}}{{end}}' 2>/dev/null | grep -w "$subnet" || true)
      if [[ -n "$overlap" ]]; then
        log "ERROR" "Подсеть $subnet уже используется сетями: $(echo "$overlap" | awk '{print $1}' | tr '\n' ' ')"
        log "ERROR" "Создание сети '$name' остановлено во избежание конфликта (invalid pool request). Удалите/измените конфликтующие сети или задайте другой subnet."
        exit 1
      fi
    fi

    # Если external — создаём сеть, учитывая подсеть/IPv6, если заданы
    if [[ "$is_external" == true ]]; then
        local args=()
        local ipv6_label=""
        $is_ipv6    && args+=(--ipv6) && ipv6_label="(with IPv6)"
        [[ -n "$subnet" ]] && args+=(--subnet "$subnet")

        log "INFO" "Creating external network '$name' ${ipv6_label} ${subnet:+subnet $subnet}..."
        if docker network create "${args[@]}" "$name"; then
            log "INFO" "External network '$name' created."
            local inspect
            inspect=$(docker network inspect "$name" 2>/dev/null)
            log "INFO" "Network '$name' inspect: $inspect"
        else
            log "ERROR" "Failed to create external network '$name'"
            exit 1
        fi
        return 0
    fi

    # Для остального собираем аргументы
    local args=()
    local ipv6_label=""
    $is_ipv6    && args+=(--ipv6) && ipv6_label="(with IPv6)"
    [[ -n "$subnet" ]] && args+=(--subnet "$subnet")

    log "INFO" "Creating network '$name' ${ipv6_label} ${subnet:+subnet $subnet}..."
    if docker network create "${args[@]}" "$name"; then
        log "INFO" "Network '$name' created."
        local inspect
        inspect=$(docker network inspect "$name" 2>/dev/null)
        log "INFO" "Network '$name' inspect: $inspect"
    else
        log "ERROR" "Failed to create network '$name'"
        exit 1
    fi
}

docker_run_compose() {
    local runner="${DOCKER_DIR}/compose.d/run-compose.sh"
    local env_file="${DOCKER_ENV_FILE:-${DOCKER_DIR}/.env}"

    if [[ ! -f "$runner" ]]; then
        log "ERROR" "run-compose.sh not found at: $runner. Execute step 3 (generate docker dir) first."
        return 1
    fi

    if [[ ! -x "$runner" ]]; then
        chmod +x "$runner" || log "WARN" "Failed to make $runner executable"
    fi

    if [[ -f "$env_file" ]]; then
        log "INFO" "Using env file: $env_file"
    else
        log "WARN" "Env file not found at: $env_file (will rely on script defaults)"
    fi

    log "INFO" "Running compose stack via: $runner"
    ENV_FILE="$env_file" "$runner" "$@"
}

# docker_compose_restart() {
#   local env_file="${DOCKER_ENV_FILE:?DOCKER_ENV_FILE is not set}"
#   local compose_file="${DOCKER_COMPOSE_FILE:?DOCKER_COMPOSE_FILE is not set}"

#   log "INFO" "Restarting Docker stack using compose file '$compose_file' and env '$env_file'"

#   if [[ ! -f "$compose_file" ]]; then
#     log "ERROR" "Compose file not found: $compose_file"
#     return 1
#   fi
#   if ! command -v docker &>/dev/null; then
#     log "ERROR" "docker not found in PATH"
#     return 1
#   fi

#   # Корректно останавливаем и чистим orphans
#   if ! docker compose --env-file "$env_file" -f "$compose_file" down --remove-orphans; then
#     log "ERROR" "docker compose down failed"
#     return 1
#   else
#     log "INFO" "docker compose down succeeded"
#   fi

#   # Не обязательно, но полезно: подтянуть обновления образов (можно убрать, если не нужно)
#   log "INFO" "Pulling latest images..."
#   if ! docker compose --env-file "$env_file" -f "$compose_file" pull --quiet; then
#     log "WARN" "docker compose pull failed — продолжаю без обновления образов"
#   else
#     log "INFO" "docker compose pull succeeded"
#   fi

#   # Поднимаем стек заново
#   log "INFO" "Starting Docker stack using compose file '$compose_file' and env '$env_file'"
#   if docker compose --env-file "$env_file" -f "$compose_file" up -d --force-recreate; then
#     log "OK" "Docker stack restarted"
#     return 0
#   else
#     log "ERROR" "docker compose up failed"
#     return 1
#   fi
# }
