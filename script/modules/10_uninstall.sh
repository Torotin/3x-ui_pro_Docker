#!/usr/bin/env bash
# Project uninstall command domain.

uninstall_usage() {
	cat <<'USAGE'
Usage:
  install.sh uninstall --plan
  install.sh uninstall --apply --yes [--purge-docker-data] [--purge-firewall]
    [--purge-docker-engine] [--purge-ssh] [--purge-network]
    [--purge-amneziawg-configs] [--remove-project-root]

Default apply stops the compose stack. Purge flags remove additional project-owned
state and installer-managed system changes.
USAGE
}

install_uninstall_command() {
	install_load_state_env
	local mode=plan
	local purge_docker=0 purge_docker_engine=0 purge_firewall=0 purge_ssh=0 purge_network=0 purge_amneziawg=0 remove_root=0
	local -a original_args=("$@")
	while (($# > 0)); do
		case "$1" in
		--plan) mode=plan ;;
		--apply) mode=apply ;;
		--yes) ;;
		--purge-docker-data) purge_docker=1 ;;
		--purge-docker-engine)
			purge_docker=1
			purge_docker_engine=1
			;;
		--purge-firewall) purge_firewall=1 ;;
		--purge-ssh) purge_ssh=1 ;;
		--purge-network) purge_network=1 ;;
		--purge-amneziawg-configs) purge_amneziawg=1 ;;
		--remove-project-root) remove_root=1 ;;
		-h | --help)
			uninstall_usage
			return 0
			;;
		*) die "unknown uninstall option: $1" ;;
		esac
		shift
	done

	if [[ "$mode" == "plan" ]]; then
		uninstall_print_plan "$purge_docker" "$purge_docker_engine" "$purge_firewall" "$purge_ssh" "$purge_network" "$purge_amneziawg" "$remove_root"
		return 0
	fi

	require_apply_confirmation "${original_args[@]}"
	uninstall_apply "$purge_docker" "$purge_docker_engine" "$purge_firewall" "$purge_ssh" "$purge_network" "$purge_amneziawg" "$remove_root"
}

uninstall_print_plan() {
	local purge_docker=$1 purge_docker_engine=$2 purge_firewall=$3 purge_ssh=$4 purge_network=$5 purge_amneziawg=$6 remove_root=$7
	run_cmd uninstall.plan printf 'project uninstall plan\n'
	cat <<PLAN
Uninstall plan for $INSTALL_ROOT
- Stop compose stack via compose.d/run-compose.sh down --remove-orphans.
PLAN
	if ((purge_docker)); then
		cat <<'PLAN'
- Remove compose volumes and prune Docker resources labeled as the docker-proxy project.
- Remove external project networks traefik-proxy and dns-net if Docker allows it.
PLAN
	fi
	if ((purge_docker_engine)); then
		cat <<'PLAN'
- Remove Docker engine packages and Docker/containerd data directories.
PLAN
	fi
	if ((purge_firewall)); then
		cat <<'PLAN'
- Delete installer-known UFW allow rules for configured PORT_REMOTE_* values, 80/tcp, 443/tcp, 443/udp.
PLAN
	fi
	if ((purge_ssh)); then
		cat <<'PLAN'
- Restore the latest sshd_config backup created by the installer, validate with sshd -t, then restart ssh.
PLAN
	fi
	if ((purge_network)); then
		cat <<'PLAN'
- Restore the latest 99-xray.conf backup or remove the installer sysctl file, then reload sysctl.
PLAN
	fi
	if ((purge_amneziawg)); then
		cat <<PLAN
- Remove AmneziaWG sensitive server/client configs under $INSTALL_ROOT/amneziawg.
PLAN
	fi
	if ((remove_root)); then
		cat <<PLAN
- Remove project root: $INSTALL_ROOT
PLAN
	fi
}

uninstall_apply() {
	local purge_docker=$1 purge_docker_engine=$2 purge_firewall=$3 purge_ssh=$4 purge_network=$5 purge_amneziawg=$6 remove_root=$7
	uninstall_down_compose "$purge_docker"
	if ((purge_docker)); then
		uninstall_purge_docker_data
	fi
	if ((purge_docker_engine)); then
		install_docker_remove_engine
	fi
	if ((purge_firewall)); then
		uninstall_purge_firewall
	fi
	if ((purge_ssh)); then
		uninstall_restore_ssh
	fi
	if ((purge_network)); then
		uninstall_restore_network
	fi
	if ((purge_amneziawg)); then
		uninstall_purge_amneziawg_configs
	fi
	if ((remove_root)); then
		uninstall_remove_project_root
	fi
}

uninstall_down_compose() {
	local purge_docker=$1 runner="$INSTALL_ROOT/compose.d/run-compose.sh"
	if ((purge_docker)); then
		run_cmd compose.down "$runner" down --remove-orphans --volumes --rmi local
	else
		run_cmd compose.down "$runner" down --remove-orphans
	fi
}

uninstall_purge_docker_data() {
	local project="${COMPOSE_PROJECT_NAME:-docker-proxy}"
	run_cmd docker.volume.prune docker volume prune --force --filter "label=com.docker.compose.project=$project"
	run_cmd docker.network.prune docker network prune --force --filter "label=com.docker.compose.project=$project"
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd docker.network.remove docker network rm traefik-proxy dns-net
		return 0
	fi
	local network
	for network in traefik-proxy dns-net; do
		if docker network inspect "$network" >/dev/null 2>&1; then
			if ! run_cmd docker.network.remove docker network rm "$network"; then
				log WARN "could not remove Docker network: $network"
			fi
		fi
	done
}

uninstall_purge_firewall() {
	local port_var port_value
	for port_var in $(compgen -v PORT_REMOTE_); do
		port_value=${!port_var}
		[[ "$port_value" =~ ^[0-9]+$ ]] || continue
		if ! run_cmd firewall.purge ufw delete allow "${port_value}/tcp"; then
			log WARN "could not delete UFW rule for $port_var=$port_value"
		fi
	done
	local rule
	for rule in 80/tcp 443/tcp 443/udp; do
		if ! run_cmd firewall.purge ufw delete allow "$rule"; then
			log WARN "could not delete UFW rule: $rule"
		fi
	done
}

latest_backup_for() {
	local prefix=$1 backup_dir=${2:-$INSTALL_STATE_DIR/backups}
	find "$backup_dir" -maxdepth 1 -type f -name "${prefix}.bak.*" 2>/dev/null | LC_ALL=C sort | tail -n 1
}

uninstall_restore_ssh() {
	local target="${INSTALL_SSHD_CONFIG:-/etc/ssh/sshd_config}" backup
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd ssh.restore cp backup "$target"
		run_cmd ssh.validate sshd -t -f "$target"
		install_ssh_reload_service
		return 0
	fi
	backup=$(latest_backup_for "$(basename "$target")")
	[[ -n "$backup" ]] || die "no ssh backup found for $target"
	run_cmd ssh.restore cp -- "$backup" "$target"
	run_cmd ssh.validate sshd -t -f "$target" || die "restored sshd_config failed validation"
	install_ssh_reload_service
}

uninstall_restore_network() {
	local target="${INSTALL_SYSCTL_CONF:-/etc/sysctl.d/99-xray.conf}" backup
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd network.restore rm -f "$target"
		run_cmd network.sysctl sysctl --system
		return 0
	fi
	backup=$(latest_backup_for "$(basename "$target")")
	if [[ -n "$backup" ]]; then
		run_cmd network.restore cp -- "$backup" "$target"
		run_cmd network.sysctl sysctl -p "$target"
	else
		run_cmd network.restore rm -f -- "$target"
		run_cmd network.sysctl sysctl --system
	fi
}

uninstall_remove_project_root() {
	[[ -n "$INSTALL_ROOT" && "$INSTALL_ROOT" == /* && "$INSTALL_ROOT" != "/" ]] || die "refusing unsafe INSTALL_ROOT: $INSTALL_ROOT"
	run_cmd project.remove rm -rf -- "$INSTALL_ROOT"
}

uninstall_purge_amneziawg_configs() {
	[[ -n "$INSTALL_ROOT" && "$INSTALL_ROOT" == /* && "$INSTALL_ROOT" != "/" ]] || die "refusing unsafe INSTALL_ROOT: $INSTALL_ROOT"
	run_cmd amneziawg.configs.remove rm -rf -- "$INSTALL_ROOT/amneziawg/server" "$INSTALL_ROOT/amneziawg/clients"
}
