#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

: "${INSTALL_REPO_ROOT:=$PROJECT_ROOT}"
: "${INSTALL_ROOT:=/opt/docker-proxy}"
: "${INSTALL_STATE_DIR:=$SCRIPT_DIR/install-state}"
: "${INSTALL_LEGACY_STATE_DIR:=$INSTALL_ROOT/install-state}"
: "${INSTALL_LOG_FILE:=$INSTALL_STATE_DIR/install.log}"
: "${INSTALL_COMMAND_LOG:=$INSTALL_STATE_DIR/commands.log}"
: "${INSTALL_REPO_URL:=https://github.com/Torotin/3x-ui_pro_Docker.git}"
: "${INSTALL_DEFAULT_BRANCH:=main}"
: "${INSTALL_NONINTERACTIVE:=0}"
: "${INSTALL_MOCK:=0}"

export INSTALL_REPO_ROOT INSTALL_ROOT INSTALL_STATE_DIR INSTALL_LEGACY_STATE_DIR INSTALL_LOG_FILE
export INSTALL_COMMAND_LOG INSTALL_REPO_URL INSTALL_DEFAULT_BRANCH
export INSTALL_NONINTERACTIVE INSTALL_MOCK SCRIPT_DIR PROJECT_ROOT

# shellcheck source=script/modules/00_common.sh
. "$SCRIPT_DIR/modules/00_common.sh"
# shellcheck source=script/modules/01_menu.sh
. "$SCRIPT_DIR/modules/01_menu.sh"
# shellcheck source=script/modules/02_env.sh
. "$SCRIPT_DIR/modules/02_env.sh"
# shellcheck source=script/modules/03_docker.sh
. "$SCRIPT_DIR/modules/03_docker.sh"
# shellcheck source=script/modules/04_apt.sh
. "$SCRIPT_DIR/modules/04_apt.sh"
# shellcheck source=script/modules/04_network.sh
. "$SCRIPT_DIR/modules/04_network.sh"
# shellcheck source=script/modules/05_user.sh
. "$SCRIPT_DIR/modules/05_user.sh"
# shellcheck source=script/modules/06_firewall.sh
. "$SCRIPT_DIR/modules/06_firewall.sh"
# shellcheck source=script/modules/07_ssh.sh
. "$SCRIPT_DIR/modules/07_ssh.sh"
# shellcheck source=script/modules/09_finalize.sh
. "$SCRIPT_DIR/modules/09_finalize.sh"
# shellcheck source=script/modules/10_uninstall.sh
. "$SCRIPT_DIR/modules/10_uninstall.sh"

usage() {
	cat <<'USAGE'
Usage:
  install.sh doctor
  install.sh wizard
  install.sh run <step...> [--destroy-docker-data] [--apply] [--yes]
  install.sh self-update [--branch <branch>] [--check] [--yes] [--force]
  install.sh uninstall [--plan|--apply --yes] [--purge-docker-data]
    [--purge-docker-engine] [--purge-firewall] [--purge-ssh]
    [--purge-network] [--remove-project-root]

Steps:
  apt env docker user firewall ssh network compose final uninstall
USAGE
}

dispatch_step() {
	local step=$1
	shift || true
	case "$step" in
	apt) install_apt_command "$@" ;;
	env) install_env_command "$@" ;;
	docker) install_docker_command "$@" ;;
	user) install_user_command "$@" ;;
	firewall) install_firewall_command "$@" ;;
	ssh) install_ssh_command "$@" ;;
	network) install_network_command "$@" ;;
	compose) install_compose_command "$@" ;;
	final) install_final_command "$@" ;;
	uninstall) install_uninstall_command "$@" ;;
	doctor) install_doctor_command "$@" ;;
	self-update) install_self_update_command "$@" ;;
	*) die "unknown step: $step" ;;
	esac
}

run_steps() {
	(($# > 0)) || die "run requires at least one step"
	local -a steps=()
	local -a opts=()
	local arg
	for arg in "$@"; do
		case "$arg" in
		--*) opts+=("$arg") ;;
		*) steps+=("$arg") ;;
		esac
	done
	((${#steps[@]} > 0)) || die "run requires at least one step"
	for arg in "${steps[@]}"; do
		dispatch_step "$arg" "${opts[@]}"
	done
}

main() {
	local cmd=${1:-}
	[[ -n "$cmd" ]] || {
		usage
		exit 2
	}
	shift || true
	install_prepare_state
	install_enable_exit_permissions_reset
	case "$cmd" in
	doctor) install_doctor_command "$@" ;;
	wizard) install_wizard "$@" ;;
	run)
		install_require_required_env batch
		run_steps "$@"
		;;
	self-update) install_self_update_command "$@" ;;
	uninstall) install_uninstall_command "$@" ;;
	-h | --help | help)
		usage
		;;
	*) die "unknown command: $cmd" ;;
	esac
}

main "$@"
