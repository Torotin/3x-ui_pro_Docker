#!/usr/bin/env bash
# Docker command domain.

install_docker_command() {
	require_opt_in --destroy-docker-data "$@"
	printf 'WARNING: Docker data will be destroyed\n'
	install_docker_setup_repository
	if install_docker_available; then
		printf 'Docker found; destroying existing Docker data\n'
		install_docker_wipe
	else
		printf 'Docker command not found; installing Docker engine\n'
	fi
	install_docker_stop_services
	install_docker_purge_data_dirs
	install_docker_install_packages
	install_docker_configure_daemon
	run_cmd docker.service.enable systemctl enable docker
	run_cmd docker.service.reset_failed systemctl reset-failed docker docker.socket || true
	run_cmd docker.socket.start systemctl start docker.socket || true
	run_cmd docker.service.restart systemctl restart docker
	install_docker_networks
}

install_docker_available() {
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		[[ "${INSTALL_MOCK_DOCKER_PRESENT:-1}" == "1" ]]
		return
	fi
	command -v docker >/dev/null 2>&1
}

install_docker_os_id() {
	local id
	id=$(apt_os_id)
	case "$id" in
	ubuntu | debian) printf '%s\n' "$id" ;;
	*) die "unsupported Docker OS: $id" ;;
	esac
}

install_docker_setup_repository() {
	local os_id codename arch source_line keyring=/etc/apt/keyrings/docker.gpg source_file=/etc/apt/sources.list.d/docker.list
	os_id=$(install_docker_os_id)
	codename=$(apt_os_codename)
	[[ -n "$codename" ]] || die "could not detect OS codename for Docker repository"
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		arch="${INSTALL_MOCK_ARCH:-amd64}"
	else
		arch=$(dpkg --print-architecture)
	fi
	source_line="deb [arch=$arch signed-by=$keyring] https://download.docker.com/linux/$os_id $codename stable"
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd docker.repo.prereqs env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg lsb-release
		run_cmd docker.repo.keyrings install -d -m 0755 /etc/apt/keyrings
		install_docker_write_repo_key "$os_id" "$keyring"
		run_cmd docker.repo.write printf '%s\n' "$source_line"
		run_cmd docker.repo.update apt-get update
		printf 'Docker APT repository configured for %s %s\n' "$os_id" "$codename"
		return 0
	fi
	run_cmd docker.repo.prereqs env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg lsb-release
	run_cmd docker.repo.keyrings install -d -m 0755 /etc/apt/keyrings
	run_cmd docker.repo.key.remove rm -f "$keyring"
	install_docker_write_repo_key "$os_id" "$keyring"
	run_cmd docker.repo.key.chmod chmod a+r "$keyring"
	local tmp
	tmp=$(mktemp)
	printf '%s\n' "$source_line" >"$tmp"
	run_cmd docker.repo.write install -m 0644 "$tmp" "$source_file"
	rm -f "$tmp"
	run_cmd docker.repo.update apt-get update
	printf 'Docker APT repository configured for %s %s\n' "$os_id" "$codename"
}

install_docker_write_repo_key() {
	local os_id=$1 keyring=$2 url
	url="https://download.docker.com/linux/$os_id/gpg"
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd docker.repo.gpg printf 'curl -fsSL %s | gpg --dearmor -o %s\n' "$url" "$keyring"
		return 0
	fi
	runner_log docker.repo.gpg bash -c 'curl -fsSL "$1" | gpg --dearmor -o "$2"' _ "$url" "$keyring"
	curl -fsSL "$url" | gpg --dearmor -o "$keyring"
}

install_docker_install_packages() {
	run_cmd docker.install.packages env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_stop_services() {
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd docker.service.stop systemctl stop docker containerd
		return 0
	fi
	run_cmd docker.service.stop systemctl stop docker containerd || true
}

install_docker_configure_daemon() {
	local daemon_file="${INSTALL_DOCKER_DAEMON_CONFIG:-/etc/docker/daemon.json}"
	local config
	config=$(install_docker_daemon_json)
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd docker.daemon.backup printf 'backup %s\n' "$daemon_file"
		run_cmd docker.daemon.write printf '%s\n' "$config"
		printf '%s\n' "$config" | python3 -m json.tool >/dev/null || die "invalid Docker daemon JSON"
		run_cmd docker.daemon.json.validate printf 'python3 -m json.tool %s\n' "$daemon_file"
		return 0
	fi
	[[ -f "$daemon_file" ]] && backup_file "$daemon_file"
	run_cmd docker.daemon.dir install -d -m 0755 "$(dirname "$daemon_file")"
	local tmp
	tmp=$(mktemp)
	printf '%s\n' "$config" >"$tmp"
	run_cmd docker.daemon.json.validate python3 -m json.tool "$tmp" >/dev/null
	run_cmd docker.daemon.write install -m 0644 "$tmp" "$daemon_file"
	rm -f "$tmp"
	run_cmd docker.daemon.json.validate python3 -m json.tool "$daemon_file" >/dev/null
	printf 'Docker daemon configured: %s\n' "$daemon_file"
}

install_docker_daemon_json() {
	local ipv6_subnet="${DOCKER_IPV6_SUBNET:-fd00:dead:aaaa::/64}"
	if [[ "${DOCKER_ENABLE_IPV6:-1}" == "1" ]]; then
		cat <<JSON
{
  "ipv6": true,
  "fixed-cidr-v6": "$ipv6_subnet",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
JSON
	else
		cat <<JSON
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
JSON
	fi
}

install_docker_purge_data_dirs() {
	run_cmd docker.data.remove rm -rf -- /var/lib/docker /var/lib/containerd
}

install_docker_remove_engine() {
	install_docker_stop_services
	run_cmd docker.remove.packages env DEBIAN_FRONTEND=noninteractive apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
	install_docker_purge_data_dirs
}

install_docker_wipe() {
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd docker.system.prune docker system prune -a --volumes --force
		return 0
	fi
	if command -v docker >/dev/null 2>&1; then
		run_cmd docker.system.prune docker system prune -a --volumes --force || true
	fi
}

install_docker_networks() {
	local traefik_subnet="${TRAEFIK_NET_SUBNET:-172.18.0.0/24}"
	local dns_subnet="${DNS_NET_SUBNET:-172.19.0.0/24}"
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd docker.network.ensure docker network create --subnet "$traefik_subnet" traefik-proxy
		run_cmd docker.network.ensure docker network create --subnet "$dns_subnet" dns-net
		return 0
	fi
	install_docker_ensure_network traefik-proxy "$traefik_subnet"
	install_docker_ensure_network dns-net "$dns_subnet"
}

install_docker_network_subnet_matches() {
	local name=$1 subnet=$2
	docker network inspect "$name" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | grep -Fq "$subnet"
}

install_docker_network_is_unused() {
	local name=$1
	[[ "$(docker network inspect "$name" --format '{{len .Containers}}' 2>/dev/null || printf 1)" == "0" ]]
}

install_docker_ensure_network() {
	local name=$1 subnet=$2
	if docker network inspect "$name" >/dev/null 2>&1; then
		if install_docker_network_subnet_matches "$name" "$subnet"; then
			return 0
		fi
		if install_docker_network_is_unused "$name"; then
			run_cmd docker.network.remove docker network rm "$name"
		else
			die "Docker network $name exists with unexpected subnet and has attached containers"
		fi
	fi
	if ! run_cmd docker.network.ensure docker network create --subnet "$subnet" "$name"; then
		die "failed to create Docker network $name with subnet $subnet"
	fi
}

install_compose_command() {
	local runner="$INSTALL_ROOT/compose.d/run-compose.sh"
	local lock_file="$INSTALL_STATE_DIR/docker-proxy-compose.lock"
	local compose_dir="$INSTALL_ROOT/compose.d"
	local compose_env="$compose_dir/.env"
	local compose_env_unset=(-u HT_PASS_ENCODED -u ADGUARD_ADMIN_HASH -u URI_SUB_PATH -u URI_JSON_PATH -u URI_CLASH_PATH -u URI_VLESS_XHTTP)
	install_project_files
	install_docker_maintenance_timer
	if [[ ! -f "$compose_env" ]]; then
		install_env_command
	fi
	install_docker_networks
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd compose.validate env "${compose_env_unset[@]}" "COMPOSE_DIR=$compose_dir" "ENV_FILE=$compose_env" "LOCK_FILE=$lock_file" "$runner" validate
		return 0
	fi
	[[ -x "$runner" ]] || die "compose runner not found or not executable: $runner"
	run_cmd compose.validate env "${compose_env_unset[@]}" "COMPOSE_DIR=$compose_dir" "ENV_FILE=$compose_env" "LOCK_FILE=$lock_file" "$runner" validate
	run_cmd compose.up env "${compose_env_unset[@]}" "COMPOSE_DIR=$compose_dir" "ENV_FILE=$compose_env" "LOCK_FILE=$lock_file" "$runner" up
}

install_docker_maintenance_timer() {
	local service_file="${INSTALL_DOCKER_MAINTENANCE_SERVICE:-/etc/systemd/system/docker-proxy-maintenance.service}"
	local timer_file="${INSTALL_DOCKER_MAINTENANCE_TIMER:-/etc/systemd/system/docker-proxy-maintenance.timer}"
	local maintenance_script="$INSTALL_ROOT/compose.d/docker-maintenance.sh"
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd docker.maintenance.service.write printf '%s\n' "$service_file"
		run_cmd docker.maintenance.timer.write printf '%s\n' "$timer_file"
		run_cmd docker.maintenance.reload systemctl daemon-reload
		run_cmd docker.maintenance.enable systemctl enable --now "$(basename "$timer_file")"
		return 0
	fi
	[[ -x "$maintenance_script" ]] || die "Docker maintenance script not found or not executable: $maintenance_script"
	[[ -f "$service_file" ]] && backup_file "$service_file"
	[[ -f "$timer_file" ]] && backup_file "$timer_file"
	run_cmd docker.maintenance.dir install -d -m 0755 "$(dirname "$service_file")"
	local service_tmp timer_tmp
	service_tmp=$(mktemp)
	timer_tmp=$(mktemp)
	cat >"$service_tmp" <<SERVICE
[Unit]
Description=Prune unused Docker artifacts for docker-proxy
Documentation=file://$maintenance_script
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
Environment=DOCKER_MAINTENANCE_IMAGE_UNTIL=168h
Environment=DOCKER_MAINTENANCE_CONTAINER_UNTIL=168h
Environment=DOCKER_MAINTENANCE_BUILDER_UNTIL=168h
ExecStart=$maintenance_script prune
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
SERVICE
	cat >"$timer_tmp" <<'TIMER'
[Unit]
Description=Daily Docker maintenance for docker-proxy

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
Unit=docker-proxy-maintenance.service

[Install]
WantedBy=timers.target
TIMER
	run_cmd docker.maintenance.service.write install -m 0644 "$service_tmp" "$service_file"
	run_cmd docker.maintenance.timer.write install -m 0644 "$timer_tmp" "$timer_file"
	rm -f "$service_tmp" "$timer_tmp"
	run_cmd docker.maintenance.reload systemctl daemon-reload
	run_cmd docker.maintenance.enable systemctl enable --now "$(basename "$timer_file")"
}

install_project_files() {
	local runner="$INSTALL_ROOT/compose.d/run-compose.sh"
	[[ -x "$runner" ]] && return 0
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd project.sync rsync -a --exclude compose.d/.env "$INSTALL_REPO_ROOT/docker-proxy/" "$INSTALL_ROOT/"
		return 0
	fi
	require_writable_target "$INSTALL_ROOT" "project root"
	mkdir -p "$INSTALL_ROOT"
	if [[ -d "$INSTALL_REPO_ROOT/docker-proxy/compose.d" ]]; then
		run_cmd project.sync rsync -a --exclude compose.d/.env "$INSTALL_REPO_ROOT/docker-proxy/" "$INSTALL_ROOT/"
	else
		install_project_files_from_repo
	fi
	[[ -x "$runner" ]] || chmod +x "$runner" 2>/dev/null || true
	[[ -x "$runner" ]] || die "compose runner not found or not executable after project sync: $runner"
	printf 'project files ready: %s\n' "$INSTALL_ROOT"
}

install_project_files_from_repo() {
	local branch tmp
	branch=$(config_get update.branch "$INSTALL_DEFAULT_BRANCH")
	tmp=$(mktemp -d)
	run_cmd project.fetch git clone --depth 1 --branch "$branch" "$INSTALL_REPO_URL" "$tmp"
	[[ -d "$tmp/docker-proxy/compose.d" ]] || {
		rm -rf "$tmp"
		die "docker-proxy directory not found in repository branch: $branch"
	}
	run_cmd project.sync rsync -a --exclude compose.d/.env "$tmp/docker-proxy/" "$INSTALL_ROOT/"
	rm -rf "$tmp"
}
