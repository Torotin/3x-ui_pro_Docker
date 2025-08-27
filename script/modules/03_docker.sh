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

# --- Docker Compose Helpers ---
docker_compose_generate() {
    local target_file="${1:-$DOCKER_COMPOSE_FILE}"
    if [[ -z "$target_file" ]]; then
        exit_error "Error: docker-compose.yml path not specified."
    fi
    if [[ -f "$target_file" ]]; then
        log "INFO" "docker-compose file already exists: $target_file"
        return 0
    fi
    local dir
    dir="$(dirname "$target_file")"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" || exit_error "Failed to create directory: $dir"
        log "INFO" "Created directory: $dir"
    fi
    touch "$target_file" || exit_error "Failed to create file: $target_file"
    log "WARN" "Created new empty docker-compose.yml: $target_file"
    # Optionally, add base structure:
    # echo "version: '3.8'" > "$target_file"
    # echo "services:" >> "$target_file"
}

docker_compose_key_remove() {
    local compose_file="$DOCKER_COMPOSE_FILE"
    local section="$1"
    local entry_name="$2"
    local key_path="$3"

    if [[ ! -f "$compose_file" ]]; then
        log "ERROR" "File $compose_file not found!"
        return 1
    fi

    log "DEBUG" "Args: compose_file=$compose_file, section=$section, entry_name=$entry_name, key_path=$key_path"

    if [[ -z "$section" ]]; then
        log "ERROR" "Missing section argument. Skipping call."
        return 1
    fi

    if [[ -z "$entry_name" ]]; then
        log "INFO" "Removing section $section from $compose_file"
        yq eval "del(.$section)" -i "$compose_file"
        log "INFO" "Section $section removed."
        return
    fi

    if ! yq eval ". | has(\"$section\")" "$compose_file" | grep -q "true"; then
        log "WARN" "Section $section missing, skipping removal."
        return
    fi
    if ! yq eval ".$section | has(\"$entry_name\")" "$compose_file" | grep -q "true"; then
        log "WARN" "Entry $entry_name missing in $section, skipping removal."
        return
    fi

    if [[ -z "$key_path" ]]; then
        log "INFO" "Removing $entry_name from section $section in $compose_file"
        yq eval "del(.$section.$entry_name)" -i "$compose_file"
        log "INFO" "Entry $entry_name removed from $section"
    else
        if ! yq eval ".$section.$entry_name | has(\"$key_path\")" "$compose_file" | grep -q "true"; then
            log "WARN" "Key $key_path not found in $entry_name ($section), skipping removal."
            return
        fi
        log "INFO" "Removing key $key_path from $entry_name ($section) in $compose_file"
        yq eval "del(.$section.$entry_name.$key_path)" -i "$compose_file"
        log "INFO" "Key $key_path removed from $entry_name ($section)"
    fi

    if [[ "$(yq eval ".$section | keys | length" "$compose_file")" -eq 0 ]]; then
        log "INFO" "Section $section is empty, removing."
        yq eval "del(.$section)" -i "$compose_file"
    fi

    yq eval 'with_entries(select(.value != {}))' -i "$compose_file"
}

docker_compose_key_update() {
    local compose_file="$DOCKER_COMPOSE_FILE"
    local section="$1"
    local entry_name="$2"
    local key_path="$3"
    local new_value="$4"
    local env_value="$5"

    if [[ ! -f "$compose_file" ]]; then
        log "ERROR" "File $compose_file not found!"
        return 1
    fi

    log "DEBUG" "Args: compose_file=$compose_file, section=$section, entry_name=$entry_name, key_path=$key_path, new_value=$new_value"

    # Ensure section exists
    if ! yq eval "has(\"$section\")" "$compose_file" | grep -q "true"; then
        log "INFO" "Creating section '$section'."
        yq eval -i ".[\"$section\"] = {}" "$compose_file"
    fi
    # Ensure entry exists
    if ! yq eval ".[\"$section\"] | has(\"$entry_name\")" "$compose_file" | grep -q "true"; then
        log "INFO" "Creating entry '$entry_name'."
        yq eval -i ".[\"$section\"][\"$entry_name\"] = {}" "$compose_file"
    fi

    # Handle array keys
    if [[ "$key_path" =~ \[[0-9]+\]$ || "$key_path" =~ \[\+\]$ ]]; then
        local array_key="${key_path%%\[*}"
        if ! yq eval ".[\"$section\"][\"$entry_name\"] | has(\"$array_key\")" "$compose_file" | grep -q "true"; then
            log "INFO" "Creating array '$array_key'."
            yq eval -i ".[\"$section\"][\"$entry_name\"][\"$array_key\"] = []" "$compose_file"
        fi
        if [[ "$key_path" == "environment[+]" ]]; then
            if [[ -z "$env_value" ]]; then
                log "WARN" "Variable '$new_value' cannot be added to $key_path: value is empty!"
                return 1
            fi
            new_value="$new_value=$env_value"
        fi
        if [[ "$new_value" == "true" ]]; then
            yq eval -i ".[\"$section\"][\"$entry_name\"][\"$array_key\"] += [$new_value]" "$compose_file"
        else
            yq eval -i ".[\"$section\"][\"$entry_name\"][\"$array_key\"] += [\"$new_value\"]" "$compose_file"
        fi
        log "INFO" "Added to ${section}.${entry_name}.${array_key} → $new_value"
    elif [[ "$key_path" == "command" ]]; then
        local NEW_VALUE
        export NEW_VALUE="$new_value"
        yq eval -i ".[\"$section\"][\"$entry_name\"][\"$key_path\"] = [\"sh\", \"-c\", strenv(NEW_VALUE)]" "$compose_file"
        log "INFO" "Updated: $key_path in $entry_name ($section) → (multiline command)"
        awk '{gsub("- \\|-", "- |")}1' "$compose_file" > "${compose_file}.tmp" && mv "${compose_file}.tmp" "$compose_file"
        log "INFO" "Fixed YAML: replaced '- |-' with '- |'"
    else
        if [[ "$key_path" == "environment[+]" ]]; then
            if [[ -z "$env_value" ]]; then
                log "WARN" "Variable '$new_value' cannot be added to $key_path: value is empty!"
                return 1
            fi
            new_value="$new_value=$env_value"
        fi
        if [[ "$new_value" == "true" ]]; then
            yq eval -i ".[\"$section\"][\"$entry_name\"][\"$key_path\"] = $new_value" "$compose_file"
        else
            yq eval -i ".[\"$section\"][\"$entry_name\"][\"$key_path\"] = \"$new_value\"" "$compose_file"
        fi
        log "INFO" "Updated: $key_path in $entry_name ($section) → $new_value"
    fi
}
