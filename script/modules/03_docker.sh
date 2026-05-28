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
	install_docker_remove_legacy_compose
	install_docker_install_packages
	install_docker_configure_daemon
	install_docker_journald_policy
	run_cmd docker.service.enable systemctl enable docker
	run_cmd docker.service.reset_failed systemctl reset-failed docker docker.socket || true
	run_cmd docker.socket.start systemctl start docker.socket || true
	run_cmd docker.service.restart systemctl restart docker
	install_docker_validate
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

install_docker_remove_legacy_compose() {
	run_cmd docker.legacy-compose.remove env DEBIAN_FRONTEND=noninteractive apt-get remove -y docker-compose || true
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
	local storage_opts=""
	local features_block=""
	if install_docker_overlay2_size_limit_enabled; then
		storage_opts='  "storage-opts": [
    "overlay2.size=20G"
  ],'
	fi
	if install_docker_containerd_snapshotter_enabled; then
		features_block='  "features": {
    "containerd-snapshotter": true
  },'
	fi
	if [[ "${DOCKER_ENABLE_IPV6:-1}" == "1" ]]; then
		cat <<JSON
{
  "live-restore": true,
  "storage-driver": "overlay2",
${storage_opts:+$storage_opts
}${features_block:+$features_block
}  "ipv6": true,
  "fixed-cidr-v6": "$ipv6_subnet",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3",
    "compress": "true",
    "mode": "non-blocking",
    "max-buffer-size": "4m"
  }
}
JSON
	else
		cat <<JSON
{
  "live-restore": true,
  "storage-driver": "overlay2",
${storage_opts:+$storage_opts
}${features_block:+$features_block
}  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3",
    "compress": "true",
    "mode": "non-blocking",
    "max-buffer-size": "4m"
  }
}
JSON
	fi
}

install_docker_containerd_snapshotter_enabled() {
	# Docker 29 with containerd-snapshotter reports/uses "overlayfs" as the
	# storage driver, which is incompatible with the required explicit overlay2
	# daemon policy. Keep this feature opt-in only for operators who knowingly
	# adjust the storage-driver policy for their Docker Engine version.
	[[ "${DOCKER_ENABLE_CONTAINERD_SNAPSHOTTER:-0}" == "1" ]]
}

install_docker_overlay2_size_limit_enabled() {
	[[ "${DOCKER_ENABLE_OVERLAY2_SIZE_LIMIT:-0}" == "1" ]] || return 1
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		[[ "${INSTALL_MOCK_DOCKER_QUOTA_SUPPORTED:-0}" == "1" ]]
		return
	fi
	install_docker_backing_fs_supports_project_quota
}

install_docker_backing_fs_supports_project_quota() {
	local docker_root=/var/lib/docker source fstype options
	read -r source fstype options < <(findmnt -n -T "$docker_root" -o SOURCE,FSTYPE,OPTIONS 2>/dev/null || true)
	[[ -n "${source:-}" && -n "${fstype:-}" ]] || return 1
	case "$fstype" in
	ext2 | ext3 | ext4)
		command -v tune2fs >/dev/null 2>&1 || return 1
		local features
		features=$(tune2fs -l "$source" 2>/dev/null | awk -F: 'tolower($1) ~ /filesystem features/ {print tolower($2)}')
		grep -Eq '(^|[[:space:]])project($|[[:space:]])' <<<"$features" && grep -Eq '(^|[[:space:]])quota($|[[:space:]])' <<<"$features"
		;;
	xfs)
		grep -Eq '(^|,)(pquota|prjquota)(,|$)' <<<"$options"
		;;
	*) return 1 ;;
	esac
}

install_docker_journald_policy() {
	local conf_file="${INSTALL_DOCKER_JOURNALD_CONFIG:-/etc/systemd/journald.conf.d/docker-proxy.conf}"
	local conf
	conf=$(cat <<'CONF'
[Journal]
SystemMaxUse=200M
SystemKeepFree=500M
RuntimeMaxUse=100M
RuntimeKeepFree=200M
MaxRetentionSec=7day
Compress=yes
CONF
)
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd docker.journald.dir install -d -m 0755 "$(dirname "$conf_file")"
		run_cmd docker.journald.write printf '%s\n' "$conf"
		run_cmd docker.journald.restart systemctl try-restart systemd-journald
		return 0
	fi
	[[ -f "$conf_file" ]] && backup_file "$conf_file"
	run_cmd docker.journald.dir install -d -m 0755 "$(dirname "$conf_file")"
	local tmp
	tmp=$(mktemp)
	printf '%s\n' "$conf" >"$tmp"
	run_cmd docker.journald.write install -m 0644 "$tmp" "$conf_file"
	rm -f "$tmp"
	run_cmd docker.journald.restart systemctl try-restart systemd-journald || run_cmd docker.journald.restart.fallback systemctl restart systemd-journald
}

install_docker_validate() {
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd docker.validate.info timeout --kill-after=10s 30s docker info
		run_cmd docker.validate.df docker system df
		run_cmd docker.validate.driver_status timeout --kill-after=10s 30s docker info --format '{{json .DriverStatus}}'
		return 0
	fi
	local logging_driver storage_driver live_restore driver_status driver_status_text
	logging_driver=$(timeout --kill-after=10s 30s docker info --format '{{.LoggingDriver}}' 2>/dev/null || true)
	storage_driver=$(timeout --kill-after=10s 30s docker info --format '{{.Driver}}' 2>/dev/null || true)
	live_restore=$(timeout --kill-after=10s 30s docker info --format '{{.LiveRestoreEnabled}}' 2>/dev/null || true)
	run_cmd docker.validate.info timeout --kill-after=10s 30s docker info
	run_cmd docker.validate.df docker system df
	driver_status=$(run_cmd docker.validate.driver_status timeout --kill-after=10s 30s docker info --format '{{json .DriverStatus}}' 2>/dev/null || true)
	driver_status_text=$(timeout --kill-after=10s 30s docker info --format '{{.DriverStatus}}' 2>/dev/null || true)
	[[ "$logging_driver" == "json-file" ]] || die "Docker validation failed: Logging Driver is $logging_driver, expected json-file"
	[[ "$storage_driver" == "overlay2" ]] || die "Docker validation failed: Storage Driver is $storage_driver, expected overlay2"
	[[ "$live_restore" == "true" ]] || die "Docker validation failed: Live Restore is $live_restore, expected true"
	grep -Eqi 'Backing Filesystem[^[:alnum:]]+(extfs|xfs)' <<<"$driver_status $driver_status_text" || die "Docker validation failed: Backing Filesystem must be extfs or xfs"
	grep -Eqi 'Supports d_type[^[:alnum:]]+true' <<<"$driver_status $driver_status_text" || die "Docker validation failed: Supports d_type must be true"
	grep -Eqi 'Native Overlay Diff[^[:alnum:]]+true' <<<"$driver_status $driver_status_text" || die "Docker validation failed: Native Overlay Diff must be true"
}

install_docker_purge_data_dirs() {
	run_cmd docker.data.remove rm -rf -- /var/lib/docker /var/lib/containerd
}

install_docker_remove_engine() {
	install_docker_remove_maintenance_timer
	install_docker_stop_services
	run_cmd docker.remove.packages env DEBIAN_FRONTEND=noninteractive apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-compose docker-ce-rootless-extras
	install_docker_purge_data_dirs
}

install_docker_remove_maintenance_timer() {
	local service_file="${INSTALL_DOCKER_MAINTENANCE_SERVICE:-/etc/systemd/system/docker-proxy-maintenance.service}"
	local timer_file="${INSTALL_DOCKER_MAINTENANCE_TIMER:-/etc/systemd/system/docker-proxy-maintenance.timer}"
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd docker.maintenance.disable systemctl disable --now "$(basename "$timer_file")"
		run_cmd docker.maintenance.service.remove rm -f "$service_file"
		run_cmd docker.maintenance.timer.remove rm -f "$timer_file"
		run_cmd docker.maintenance.reload systemctl daemon-reload
		return 0
	fi
	run_cmd docker.maintenance.disable systemctl disable --now "$(basename "$timer_file")" || true
	run_cmd docker.maintenance.service.remove rm -f "$service_file"
	run_cmd docker.maintenance.timer.remove rm -f "$timer_file"
	run_cmd docker.maintenance.reload systemctl daemon-reload
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
	install_docker_maintenance_script
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

install_docker_maintenance_script() {
	local maintenance_script="$INSTALL_ROOT/compose.d/docker-maintenance.sh"
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd docker.maintenance.script.chmod chmod +x "$maintenance_script"
		return 0
	fi
	[[ -f "$maintenance_script" ]] || die "Docker maintenance script not found: $maintenance_script"
	run_cmd docker.maintenance.script.chmod chmod +x "$maintenance_script"
	[[ -x "$maintenance_script" ]] || die "Docker maintenance script not executable: $maintenance_script"
}

install_docker_maintenance_timer() {
	local service_file="${INSTALL_DOCKER_MAINTENANCE_SERVICE:-/etc/systemd/system/docker-proxy-maintenance.service}"
	local timer_file="${INSTALL_DOCKER_MAINTENANCE_TIMER:-/etc/systemd/system/docker-proxy-maintenance.timer}"
	local maintenance_script="$INSTALL_ROOT/compose.d/docker-maintenance.sh"
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd docker.maintenance.service.write printf '%s\n' "$(install_docker_maintenance_service_unit "$maintenance_script")"
		run_cmd docker.maintenance.timer.write printf '%s\n' "$(install_docker_maintenance_timer_unit)"
		run_cmd docker.maintenance.service.write printf '%s\n' "$service_file"
		run_cmd docker.maintenance.timer.write printf '%s\n' "$timer_file"
		run_cmd docker.maintenance.reload systemctl daemon-reload
		run_cmd docker.maintenance.enable systemctl enable "$(basename "$timer_file")"
		run_cmd docker.maintenance.start systemctl start "$(basename "$timer_file")"
		run_cmd docker.maintenance.list systemctl list-timers --all "$(basename "$timer_file")"
		printf 'Docker maintenance timer installed and active\n'
		return 0
	fi
	[[ -x "$maintenance_script" ]] || die "Docker maintenance script not found or not executable: $maintenance_script"
	[[ -f "$service_file" ]] && backup_file "$service_file"
	[[ -f "$timer_file" ]] && backup_file "$timer_file"
	run_cmd docker.maintenance.dir install -d -m 0755 "$(dirname "$service_file")"
	local service_tmp timer_tmp
	service_tmp=$(mktemp)
	timer_tmp=$(mktemp)
	install_docker_maintenance_service_unit "$maintenance_script" >"$service_tmp"
	install_docker_maintenance_timer_unit >"$timer_tmp"
	run_cmd docker.maintenance.service.write install -m 0644 "$service_tmp" "$service_file"
	run_cmd docker.maintenance.timer.write install -m 0644 "$timer_tmp" "$timer_file"
	rm -f "$service_tmp" "$timer_tmp"
	run_cmd docker.maintenance.reload systemctl daemon-reload
	run_cmd docker.maintenance.enable systemctl enable "$(basename "$timer_file")"
	run_cmd docker.maintenance.start systemctl start "$(basename "$timer_file")"
	run_cmd docker.maintenance.list systemctl list-timers --all "$(basename "$timer_file")"
	printf 'Docker maintenance timer installed and active\n'
}

install_docker_maintenance_service_unit() {
	local maintenance_script=$1
	cat <<SERVICE
[Unit]
Description=Docker maintenance and containerd cleanup
Documentation=file://$maintenance_script
After=docker.service containerd.service
Requires=docker.service
RequiresMountsFor=/var/lib/docker /var/lib/containerd

[Service]
Type=oneshot
Environment=PATH=/usr/sbin:/usr/bin:/sbin:/bin
Environment=LC_ALL=C
ExecStartPre=/usr/bin/test -x $maintenance_script
ExecStart=$maintenance_script
Nice=19
IOSchedulingClass=best-effort
IOSchedulingPriority=7
TimeoutStartSec=15min
TimeoutStopSec=5min
OOMScoreAdjust=500
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
ReadWritePaths=/run /tmp /var/tmp /var/log /var/lib/docker /var/lib/containerd /var/lib/apt /var/cache/apt /run/log/journal /var/log/journal
SERVICE
}

install_docker_maintenance_timer_unit() {
	cat <<'TIMER'
[Unit]
Description=Daily Docker maintenance for docker-proxy

[Timer]
OnCalendar=daily
RandomizedDelaySec=45m
AccuracySec=15m
Persistent=true
Unit=docker-proxy-maintenance.service

[Install]
WantedBy=timers.target
TIMER
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
