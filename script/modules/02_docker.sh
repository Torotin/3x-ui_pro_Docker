#!/bin/bash
# lib/02_docker.sh
# Enhanced Docker management functions: install, uninstall, clear, compose, and network setup.

# === Глобальные переменные проекта ===
: "${PROJECT_ROOT:=/mnt/share}"
: "${BACKUP_DIR:=${PROJECT_ROOT}/backup}"
: "${TEMPLATE_DIR:=${PROJECT_ROOT}/template}"
: "${DOCKER_COMPOSE_FILE:=${PROJECT_ROOT}/docker/docker-compose.yml}"
: "${DOCKER_DAEMON_FILE:=/etc/docker/daemon.json}"
: "${DOCKER_NETWORK_NAME:=my-ipv6-network}"
: "${DOCKER_IPV6_SUBNET:=fd00:dead:beef::/64}"

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

    # Если уже есть — ничего не делаем
    if docker network inspect "$name" &>/dev/null; then
        log "INFO" "Network '$name' already exists, skipping creation."
        return 0
    fi

    # Если external — просто создаём «пустую» сеть под этим именем
    if [[ "$is_external" == true ]]; then
        log "INFO" "Creating external network '$name'..."
        docker network create "$name" \
            && log "INFO" "External network '$name' created." \
            || { log "ERROR" "Failed to create external network '$name'"; exit 1; }
        return 0
    fi

    # Для остального собираем аргументы
    local args=()
    $is_ipv6    && args+=(--ipv6)
    [[ -n "$subnet" ]] && args+=(--subnet "$subnet")

    log "INFO" "Creating network '$name' ${is_ipv6:+(with IPv6)} ${subnet:+subnet $subnet}..."
    docker network create "${args[@]}" "$name" \
        && log "INFO" "Network '$name' created." \
        || { log "ERROR" "Failed to create network '$name'"; exit 1; }
}