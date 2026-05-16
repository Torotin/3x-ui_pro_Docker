#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
INSTALLER="$ROOT_DIR/script/install.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_contains() {
	local needle=$1 file=$2 message=$3
	grep -Fq -- "$needle" "$file" || fail "$message; missing: $needle"
}

assert_not_contains() {
	local needle=$1 file=$2 message=$3
	! grep -Fq -- "$needle" "$file" || fail "$message; unexpected: $needle"
}

make_fixture() {
	tmpdir=$(mktemp -d)
	export INSTALL_MOCK=1
	export INSTALL_NONINTERACTIVE=1
	export INSTALL_ROOT="$tmpdir/root"
	export INSTALL_STATE_DIR="$tmpdir/state"
	export INSTALL_COMMAND_LOG="$tmpdir/commands.log"
	export INSTALL_LOG_FILE="$tmpdir/install.log"
	export INSTALL_REPO_ROOT="$ROOT_DIR"
	export INSTALL_REPO_URL="file://$ROOT_DIR"
	export INSTALL_TEST_OS_RELEASE="$tmpdir/os-release"
	export WEBDOMAIN=example.test
	export USER_WEB=admin
	export PASS_WEB=secret
	export USER_SSH=deployer
	export PASS_SSH=secret
	export SSH_PBK=ssh-ed25519-mock
	export PORT_REMOTE_SSH=22022
	unset INSTALL_MOCK_REMOTE_VERSION INSTALL_MOCK_REMOTE_CHANGELOG HT_PASS_ENCODED ADGUARD_ADMIN_HASH
	mkdir -p "$INSTALL_ROOT" "$INSTALL_STATE_DIR"
	cat >"$INSTALL_TEST_OS_RELEASE" <<'OS'
ID=ubuntu
VERSION_CODENAME=noble
OS
	: >"$INSTALL_COMMAND_LOG"
}

run_installer() {
	"$INSTALLER" "$@" >"$tmpdir/stdout" 2>"$tmpdir/stderr"
}

test_doctor_is_mock_only_and_reports_supported_os() {
	make_fixture
	run_installer doctor
	assert_contains "doctor: checking installer, dependencies and stack status" "$tmpdir/stdout" "doctor must describe expanded checks"
	assert_contains "OK: OS is Debian/Ubuntu compatible" "$tmpdir/stdout" "doctor must report supported OS"
	assert_contains "OK: commands:" "$tmpdir/stdout" "doctor must summarize command checks by default"
	assert_contains "WARN: stack checks skipped in mock mode" "$tmpdir/stdout" "doctor must skip stack checks in mock mode"
	assert_contains "doctor: OK" "$tmpdir/stdout" "doctor must report success on Ubuntu fixture"
	assert_not_contains "OK: command available: bash" "$tmpdir/stdout" "doctor must not spam individual successful commands by default"
	assert_contains "doctor.command command -v apt-get" "$INSTALL_COMMAND_LOG" "doctor must check required commands through runner in mock mode"
	assert_contains "doctor.command command -v docker" "$INSTALL_COMMAND_LOG" "doctor must check Docker command through runner in mock mode"
	assert_not_contains "apt-get install" "$INSTALL_COMMAND_LOG" "doctor must not install apt packages"
	assert_not_contains "systemctl restart" "$INSTALL_COMMAND_LOG" "doctor must not restart services"
	assert_not_contains "/etc/" "$INSTALL_COMMAND_LOG" "doctor must not mutate /etc"
}

test_doctor_verbose_keeps_detailed_success_output() {
	make_fixture
	run_installer doctor --verbose
	assert_contains "OK: command available: bash" "$tmpdir/stdout" "doctor --verbose must show individual successful command checks"
	assert_contains "OK: path exists:" "$tmpdir/stdout" "doctor --verbose must show individual successful path checks"
	assert_contains "doctor: OK" "$tmpdir/stdout" "doctor --verbose must still report success"
}

test_exit_resets_script_and_project_permissions() {
	make_fixture
	run_installer doctor
	assert_contains "permissions.owner chown -hR deployer:deployer $ROOT_DIR/script" "$INSTALL_COMMAND_LOG" "exit hook must reset script ownership"
	assert_contains "permissions.owner chown -hR deployer:deployer $INSTALL_ROOT" "$INSTALL_COMMAND_LOG" "exit hook must reset project ownership"
	assert_contains "permissions.dirs find $ROOT_DIR/script -type d -exec chmod u=rwx\\,go=rx" "$INSTALL_COMMAND_LOG" "exit hook must reset directory permissions"
	assert_contains "permissions.files find $INSTALL_ROOT -type f -exec chmod u=rwX\\,go=rX" "$INSTALL_COMMAND_LOG" "exit hook must reset file permissions"
}

test_run_dispatches_named_steps_without_eval() {
	make_fixture
	run_installer run env compose
	assert_contains "env.render" "$INSTALL_COMMAND_LOG" "run env must dispatch env command"
	assert_contains "compose.validate" "$INSTALL_COMMAND_LOG" "run compose must dispatch compose command"
	assert_not_contains "eval" "$INSTALL_COMMAND_LOG" "dispatcher must not use eval"
}

test_env_reports_permission_problem_before_backup() {
	make_fixture
	export INSTALL_MOCK=0
	export INSTALL_EFFECTIVE_UID=1000
	export INSTALL_ROOT="/opt/docker-proxy"
	export INSTALL_STATE_DIR="/opt/docker-proxy/install-state"
	if run_installer run env; then
		fail "env must fail early when non-root user targets /opt"
	fi
	assert_contains "run with sudo or set INSTALL_ROOT/INSTALL_STATE_DIR" "$tmpdir/stderr" "env must explain how to fix write permissions"
	assert_not_contains "cp:" "$tmpdir/stderr" "env must not fail with raw cp permission errors"
}

test_env_preserves_existing_state_defaults() {
	make_fixture
	unset WEBDOMAIN USER_SSH CROWDSEC_API_KEY_FIREWALL HT_PASS_ENCODED ADGUARD_ADMIN_HASH
	cat >"$INSTALL_STATE_DIR/install.env" <<'ENV'
WEBDOMAIN=state.example.test
USER_SSH="state-user"
CROWDSEC_API_KEY_FIREWALL=state-firewall-key
ENV
	run_installer run env
	assert_contains "WEBDOMAIN=state.example.test" "$INSTALL_STATE_DIR/install.env" "env must preserve existing domain when no override is provided"
	assert_contains 'USER_SSH="state-user"' "$INSTALL_STATE_DIR/install.env" "env must preserve existing SSH user when no override is provided"
	assert_contains "CROWDSEC_API_KEY_FIREWALL=state-firewall-key" "$INSTALL_STATE_DIR/install.env" "env must preserve existing crowdsec key when no override is provided"
}

test_state_loader_preserves_literal_dollars() {
	make_fixture
	unset HT_PASS_ENCODED ADGUARD_ADMIN_HASH
	cat >"$INSTALL_STATE_DIR/install.env" <<'ENV'
HT_PASS_ENCODED="user:$$2y$$hash"
ENV
	source "$ROOT_DIR/script/modules/00_common.sh"
	install_load_state_env
	assert_contains 'HT_PASS_ENCODED="user:$$2y$$hash"' "$INSTALL_STATE_DIR/install.env" "env loader must preserve literal dollar signs"
	[[ "$HT_PASS_ENCODED" == 'user:$$2y$$hash' ]] || fail "state loader must not shell-expand dollar signs: $HT_PASS_ENCODED"
	source "$ROOT_DIR/script/modules/02_env.sh"
	generate_adguard_hash_from_htpasswd
	[[ "$ADGUARD_ADMIN_HASH" == '$2y$hash' ]] || fail "AdGuard hash must unescape doubled dollars: $ADGUARD_ADMIN_HASH"
}

test_env_prints_rendered_paths() {
	make_fixture
	run_installer run env
	assert_contains "rendered:" "$tmpdir/stdout" "env must print rendered paths header"
	assert_contains "- $INSTALL_STATE_DIR/install.env" "$tmpdir/stdout" "env must print install state env path"
	assert_contains "- $INSTALL_ROOT/compose.d/.env" "$tmpdir/stdout" "env must print compose env path"
}

test_env_detects_public_ips_when_missing() {
	make_fixture
	unset PUBLIC_IPV4 PUBLIC_IPV6
	run_installer run env
	assert_contains "PUBLIC_IPV4=198.51.100.10" "$INSTALL_STATE_DIR/install.env" "env must detect public IPv4"
	assert_contains "PUBLIC_IPV6=2001:db8::10" "$INSTALL_STATE_DIR/install.env" "env must detect public IPv6"
	assert_contains "ip.detect.ipv4" "$INSTALL_COMMAND_LOG" "env must route IPv4 detection through runner"
	assert_contains "ip.detect.ipv6" "$INSTALL_COMMAND_LOG" "env must route IPv6 detection through runner"
}

test_env_generates_adguard_hash_from_htpasswd() {
	make_fixture
	mkdir -p "$tmpdir/bin"
	cat >"$tmpdir/bin/htpasswd" <<'BASH'
#!/usr/bin/env bash
if [[ "$1" == "-nBb" ]]; then
	printf '%s:$2y$05$abc\n' "$2"
	exit 0
fi
if [[ "$1" == "-vb" ]]; then
	exit 0
fi
exit 2
BASH
	chmod +x "$tmpdir/bin/htpasswd"
	unset HT_PASS_ENCODED ADGUARD_ADMIN_HASH
	export INSTALL_MOCK=0
	source "$ROOT_DIR/script/modules/00_common.sh"
	source "$ROOT_DIR/script/modules/02_env.sh"
	PATH="$tmpdir/bin:$PATH" generate_htpasswd_if_needed
	[[ "$HT_PASS_ENCODED" == 'admin:$$2y$$05$$abc' ]] || fail "HT_PASS_ENCODED mismatch: $HT_PASS_ENCODED"
	[[ "$ADGUARD_ADMIN_HASH" == '$2y$05$abc' ]] || fail "ADGUARD_ADMIN_HASH mismatch: $ADGUARD_ADMIN_HASH"
}

test_env_writes_escaped_htpasswd_to_compose_env_for_labels() {
	make_fixture
	run_installer run env
	assert_contains 'HT_PASS_ENCODED="admin:$$2y$$05$$mockhash"' "$INSTALL_STATE_DIR/install.env" "install state must keep shell-safe escaped bcrypt dollars"
	assert_contains 'HT_PASS_ENCODED="admin:$$2y$$05$$mockhash"' "$INSTALL_ROOT/compose.d/.env" "compose env must keep escaped bcrypt dollars so Docker Compose emits raw Docker labels"
}

test_env_regenerates_stale_htpasswd_when_password_changes() {
	make_fixture
	mkdir -p "$tmpdir/bin"
	cat >"$tmpdir/bin/htpasswd" <<'BASH'
#!/usr/bin/env bash
if [[ "$1" == "-nBb" ]]; then
	printf '%s:$2y$05$new\n' "$2"
	exit 0
fi
if [[ "$1" == "-vb" ]]; then
	if grep -Fq '$2y$05$new' "$2" && [[ "$4" == "new-secret" ]]; then
		exit 0
	fi
	exit 1
fi
exit 2
BASH
	chmod +x "$tmpdir/bin/htpasswd"
	export HT_PASS_ENCODED='admin:$$2y$$05$$old'
	export ADGUARD_ADMIN_HASH='$2y$05$old'
	export PASS_WEB='new-secret'
	export INSTALL_MOCK=0
	source "$ROOT_DIR/script/modules/00_common.sh"
	source "$ROOT_DIR/script/modules/02_env.sh"
	PATH="$tmpdir/bin:$PATH" generate_htpasswd_if_needed
	[[ "$HT_PASS_ENCODED" == 'admin:$$2y$$05$$new' ]] || fail "stale HT_PASS_ENCODED must be regenerated: $HT_PASS_ENCODED"
	[[ "$ADGUARD_ADMIN_HASH" == '$2y$05$new' ]] || fail "stale ADGUARD_ADMIN_HASH must be regenerated: $ADGUARD_ADMIN_HASH"
}

test_env_regenerates_existing_hash_when_verify_is_unsupported() {
	make_fixture
	mkdir -p "$tmpdir/bin"
	cat >"$tmpdir/bin/htpasswd" <<'BASH'
#!/usr/bin/env bash
if [[ "$1" == "-nBb" ]]; then
	printf '%s:$2y$05$new\n' "$2"
	exit 0
fi
if [[ "$1" == "-vb" ]]; then
	printf 'usage: htpasswd [-nBb] user password\n' >&2
	exit 1
fi
exit 2
BASH
	chmod +x "$tmpdir/bin/htpasswd"
	export HT_PASS_ENCODED='admin:$$2y$$05$$old'
	export ADGUARD_ADMIN_HASH='$2y$05$old'
	export PASS_WEB='new-secret'
	export INSTALL_MOCK=0
	source "$ROOT_DIR/script/modules/00_common.sh"
	source "$ROOT_DIR/script/modules/02_env.sh"
	PATH="$tmpdir/bin:$PATH" generate_htpasswd_if_needed
	[[ "$HT_PASS_ENCODED" == 'admin:$$2y$$05$$new' ]] || fail "existing hash must be regenerated when verification is unsupported: $HT_PASS_ENCODED"
	[[ "$ADGUARD_ADMIN_HASH" == '$2y$05$new' ]] || fail "AdGuard hash must follow regenerated htpasswd hash: $ADGUARD_ADMIN_HASH"
}

test_adguard_update_pass_uses_precomputed_hash() {
	make_fixture
	mkdir -p "$tmpdir/bin"
	cat >"$tmpdir/bin/yq" <<'BASH'
#!/usr/bin/env bash
echo "unexpected yq call" >"$YQ_LOG"
exit 99
BASH
	chmod +x "$tmpdir/bin/yq"
	local conf="$tmpdir/AdGuardHome.yaml"
	cat >"$conf" <<'YAML'
users:
  - name: ""
    password: ""
auth_attempts: 5
YAML
	YQ_LOG="$tmpdir/yq.log" PATH="$tmpdir/bin:/usr/bin:/bin" ADGUARD_CONF="$conf" USER_WEB=admin PASS_WEB=secret HT_PASS_ENCODED='admin:$$2y$$05$$abc' \
		"$ROOT_DIR/docker-proxy/adguard/update-pass.sh" >"$tmpdir/adguard.out" 2>"$tmpdir/adguard.err"
	assert_contains '  - name: "admin"' "$conf" "AdGuard password updater must preserve username"
	assert_contains '    password: "$2y$05$abc"' "$conf" "AdGuard password updater must derive raw hash from escaped htpasswd"
	assert_not_contains "Installing apache2-utils" "$tmpdir/adguard.out" "AdGuard password updater must not install htpasswd when hash is precomputed"
	[[ ! -f "$tmpdir/yq.log" ]] || fail "AdGuard password updater must not call yq"
}

test_adguard_update_pass_updates_yaml_without_yq() {
	make_fixture
	mkdir -p "$tmpdir/bin"
	cat >"$tmpdir/bin/awk" <<'BASH'
#!/usr/bin/env bash
exec /usr/bin/awk "$@"
BASH
	chmod +x "$tmpdir/bin/awk"
	local conf="$tmpdir/AdGuardHome.yaml"
	cat >"$conf" <<'YAML'
http:
  address: 0.0.0.0:80
users:
  - name: ""
    password: ""
auth_attempts: 5
YAML
	PATH="$tmpdir/bin:/usr/bin:/bin" ADGUARD_CONF="$conf" USER_WEB=admin PASS_WEB=secret HT_PASS_ENCODED='admin:$$2y$$05$$abc' \
		"$ROOT_DIR/docker-proxy/adguard/update-pass.sh" >"$tmpdir/adguard.out" 2>"$tmpdir/adguard.err"
	assert_contains '  - name: "admin"' "$conf" "AdGuard password updater must write user without yq"
	assert_contains '    password: "$2y$05$abc"' "$conf" "AdGuard password updater must write raw hash without yq"
	assert_contains "auth_attempts: 5" "$conf" "AdGuard password updater must keep following YAML keys"
	assert_not_contains "Installing yq" "$tmpdir/adguard.out" "AdGuard password updater must not install yq at container startup"
}

test_state_loader_keeps_explicit_values_over_state() {
	make_fixture
	export USER_SSH=explicit-user
	cat >"$INSTALL_STATE_DIR/install.env" <<'ENV'
USER_SSH="state-user"
ENV
	run_installer run user
	assert_contains "user.ensure useradd -m -d /home/explicit-user -s /bin/bash explicit-user" "$INSTALL_COMMAND_LOG" "explicit env must override state env"
}

test_destructive_steps_require_explicit_flags() {
	make_fixture
	if run_installer run docker firewall ssh; then
		fail "destructive steps without opt-in must fail"
	fi
	assert_contains "requires explicit opt-in" "$tmpdir/stderr" "destructive guard must explain opt-in"
	assert_not_contains "docker system prune" "$INSTALL_COMMAND_LOG" "docker data wipe must be blocked"
	assert_not_contains "ufw --force reset" "$INSTALL_COMMAND_LOG" "firewall reset must be blocked"
	assert_not_contains "systemctl restart ssh" "$INSTALL_COMMAND_LOG" "ssh restart must be blocked"
}

test_destructive_steps_use_mock_runner_when_explicit() {
	make_fixture
	run_installer run docker --destroy-docker-data
	assert_contains "docker.repo.gpg printf" "$INSTALL_COMMAND_LOG" "docker install must log Docker repo GPG pipeline safely in mock mode"
	assert_contains "download.docker.com/linux/ubuntu" "$INSTALL_COMMAND_LOG" "docker repo must target detected Debian/Ubuntu OS"
	assert_contains "docker.repo.write printf %s\\\\n deb\\ \\[arch=amd64\\ signed-by=/etc/apt/keyrings/docker.gpg\\]\\ https://download.docker.com/linux/ubuntu\\ noble\\ stable" "$INSTALL_COMMAND_LOG" "docker repo write must log exact source line"
	assert_contains "WARNING: Docker data will be destroyed" "$tmpdir/stdout" "docker destructive reinstall must warn about data loss"
	assert_not_contains "docker.containers.remove" "$INSTALL_COMMAND_LOG" "docker wipe must use Docker prune instead of hand-removing containers"
	assert_contains "docker.system.prune" "$INSTALL_COMMAND_LOG" "explicit docker command must be routed through runner"
	assert_contains "docker.daemon.write" "$INSTALL_COMMAND_LOG" "docker install must write daemon config through runner"
	assert_contains "docker.daemon.json.validate printf python3\\ -m\\ json.tool\\ %s\\\\n /etc/docker/daemon.json" "$INSTALL_COMMAND_LOG" "docker install must log daemon.json validation in mock mode"
	assert_contains "docker.service.enable systemctl enable docker" "$INSTALL_COMMAND_LOG" "docker install must enable Docker service"
	assert_not_contains "docker.service.enable systemctl enable --now docker" "$INSTALL_COMMAND_LOG" "docker install must not start service before daemon restart"
	assert_contains "docker.service.reset_failed systemctl reset-failed docker docker.socket" "$INSTALL_COMMAND_LOG" "docker install must clear failed service/socket state before restart"
	assert_contains "docker.socket.start systemctl start docker.socket" "$INSTALL_COMMAND_LOG" "docker install must start socket before dockerd fd activation restart"
	assert_contains "docker.service.restart systemctl restart docker" "$INSTALL_COMMAND_LOG" "docker install must restart Docker after daemon config"
	run_installer run firewall --apply --yes
	run_installer run ssh --apply --yes
	assert_contains "firewall.apply" "$INSTALL_COMMAND_LOG" "explicit firewall command must be routed through runner"
	assert_contains "ufw default allow routed" "$INSTALL_COMMAND_LOG" "firewall must allow Docker bridge routed traffic"
	assert_contains "ufw allow 22022/tcp" "$INSTALL_COMMAND_LOG" "firewall must preserve configured SSH port"
	assert_contains "ssh.apply bash -c" "$INSTALL_COMMAND_LOG" "ssh apply must render config through shell redirection"
	assert_contains "ssh.detect" "$INSTALL_COMMAND_LOG" "ssh apply must detect the active SSH systemd unit"
	assert_contains "ssh.reload systemctl reload ssh" "$INSTALL_COMMAND_LOG" "ssh apply must reload SSH before restart fallback"
	assert_contains "ssh.listener.check" "$INSTALL_COMMAND_LOG" "ssh apply must verify the configured SSH port listener"
	assert_not_contains "ssh.restart systemctl restart ssh" "$INSTALL_COMMAND_LOG" "ssh apply must not restart when reload and listener check succeed"
}

test_firewall_preserves_current_ssh_port_for_rollback() {
	make_fixture
	export SSH_CONNECTION="198.51.100.20 54321 203.0.113.10 22"
	run_installer run firewall --apply --yes
	assert_contains "ufw allow 22/tcp comment CURRENT_SSH_PORT" "$INSTALL_COMMAND_LOG" "firewall must preserve active SSH port before SSH policy changes"
	assert_contains "ufw allow 22022/tcp comment PORT_REMOTE_SSH" "$INSTALL_COMMAND_LOG" "firewall must still allow configured target SSH port"
}

test_ssh_rejects_invalid_port_before_apply() {
	make_fixture
	export PORT_REMOTE_SSH=not-a-port
	if run_installer run ssh --apply --yes; then
		fail "ssh step must reject non-numeric PORT_REMOTE_SSH"
	fi
	assert_contains "PORT_REMOTE_SSH must be numeric" "$tmpdir/stderr" "ssh step must explain invalid port"
	assert_not_contains "ssh.apply" "$INSTALL_COMMAND_LOG" "ssh step must not render config with invalid port"
}

test_ssh_restarts_when_listener_check_fails_after_reload() {
	make_fixture
	export INSTALL_MOCK_SSH_LISTENER_READY=0
	run_installer run ssh --apply --yes
	assert_contains "ssh.reload systemctl reload ssh" "$INSTALL_COMMAND_LOG" "ssh apply must reload before fallback"
	assert_contains "ssh.listener.check" "$INSTALL_COMMAND_LOG" "ssh apply must check configured listener"
	assert_contains "ssh.restart systemctl restart ssh" "$INSTALL_COMMAND_LOG" "ssh apply must restart when listener check fails"
}

test_ssh_listener_mock_uses_realistic_address_pattern() {
	make_fixture
	run_installer run ssh --apply --yes
	assert_contains '\[\^\[:space:\]\]\*:\$1' "$INSTALL_COMMAND_LOG" "ssh listener check must match address-prefixed sockets"
}

test_ssh_auth_mode_follows_optional_public_key() {
	make_fixture
	local rendered="$tmpdir/sshd_config"
	export INSTALL_MOCK=0
	export INSTALL_SSHD_CONFIG="$rendered"
	source "$ROOT_DIR/script/modules/07_ssh.sh"

	export SSH_PBK=ssh-ed25519-mock
	install_ssh_set_auth_mode
	install_render_sshd_config "$ROOT_DIR/script/template/sshd_config.template" "$rendered"
	assert_contains "PubkeyAuthentication yes" "$rendered" "ssh with public key must enable pubkey auth"
	assert_contains "PasswordAuthentication no" "$rendered" "ssh with public key must disable password auth"

	export SSH_PBK=
	install_ssh_set_auth_mode
	install_render_sshd_config "$ROOT_DIR/script/template/sshd_config.template" "$rendered"
	assert_contains "PubkeyAuthentication no" "$rendered" "ssh without public key must disable pubkey auth"
	assert_contains "PasswordAuthentication yes" "$rendered" "ssh without public key must enable password auth"
}

test_docker_install_handles_missing_docker_binary() {
	make_fixture
	export INSTALL_MOCK_DOCKER_PRESENT=0
	run_installer run docker --destroy-docker-data
	assert_contains "Docker command not found; installing Docker engine" "$tmpdir/stdout" "docker install must explain fresh install path"
	assert_not_contains "docker.containers.stop" "$INSTALL_COMMAND_LOG" "fresh install must not call docker before it exists"
	assert_contains "docker.repo.update" "$INSTALL_COMMAND_LOG" "fresh install must update Docker repo before package install"
	assert_contains "docker.install.packages" "$INSTALL_COMMAND_LOG" "fresh install must install Docker packages"
	assert_contains "docker.data.remove rm -rf -- /var/lib/docker /var/lib/containerd" "$INSTALL_COMMAND_LOG" "docker data purge must use rm -rf --"
}

test_network_apply_uses_runner() {
	make_fixture
	run_installer run network --apply --yes
	assert_contains "network.apply" "$INSTALL_COMMAND_LOG" "network apply must use runner"
	assert_contains "network.sysctl" "$INSTALL_COMMAND_LOG" "network sysctl must use runner"
}

test_docker_repo_and_daemon_config_are_safe() {
	make_fixture
	export DOCKER_ENABLE_IPV6=0
	run_installer run docker --destroy-docker-data
	assert_contains "docker.repo.gpg printf" "$INSTALL_COMMAND_LOG" "docker repo key install must log a non-executing pipeline in mock mode"
	assert_contains "curl -fsSL %s | gpg --dearmor -o %s" "$INSTALL_COMMAND_LOG" "docker repo key install must show the intended pipeline"
	assert_contains "docker.repo.update apt-get update" "$INSTALL_COMMAND_LOG" "docker repo update must not pass -y"
	assert_not_contains "docker.repo.update apt-get update -y" "$INSTALL_COMMAND_LOG" "docker repo update must not use unsupported -y"
	assert_contains "docker.daemon.backup printf backup\\ %s\\\\n /etc/docker/daemon.json" "$INSTALL_COMMAND_LOG" "docker daemon mock backup must not copy a missing host file"
	assert_contains "docker.daemon.json.validate printf python3\\ -m\\ json.tool\\ %s\\\\n /etc/docker/daemon.json" "$INSTALL_COMMAND_LOG" "docker daemon mock validation must log validation target without reading it"
	assert_not_contains "fixed-cidr-v6" "$INSTALL_COMMAND_LOG" "docker daemon config must allow disabling IPv6"
	assert_not_contains "docker.network.remove docker network rm docker-proxy_default" "$INSTALL_COMMAND_LOG" "docker network creation must not auto-delete compose default network"
}

test_uninstall_plan_is_non_destructive() {
	make_fixture
	run_installer uninstall --plan
	assert_contains "Uninstall plan" "$tmpdir/stdout" "uninstall plan must be visible"
	assert_contains "uninstall.plan" "$INSTALL_COMMAND_LOG" "uninstall plan must be routed through runner"
	assert_not_contains "compose.down" "$INSTALL_COMMAND_LOG" "plan must not stop compose"
	assert_not_contains "rm -rf" "$INSTALL_COMMAND_LOG" "plan must not remove files"
	assert_not_contains "ufw --force reset" "$INSTALL_COMMAND_LOG" "plan must not reset firewall"
}

test_uninstall_apply_requires_confirmation() {
	make_fixture
	if run_installer uninstall --apply; then
		fail "uninstall apply without --yes must fail in non-interactive mode"
	fi
	assert_contains "--apply requires explicit opt-in with --yes" "$tmpdir/stderr" "uninstall apply must require confirmation"
	assert_not_contains "compose.down" "$INSTALL_COMMAND_LOG" "unconfirmed uninstall must not stop compose"
}

test_uninstall_apply_uses_mock_runner_and_explicit_purge_flags() {
	make_fixture
	unset PORT_REMOTE_SSH
	cat >"$INSTALL_STATE_DIR/install.env" <<'ENV'
PORT_REMOTE_SSH="22022"
PORT_REMOTE_TEST="2443"
ENV
	run_installer uninstall --apply --yes --purge-docker-data --purge-firewall --purge-ssh --purge-network --remove-project-root
	assert_contains "compose.down" "$INSTALL_COMMAND_LOG" "uninstall must stop compose through runner"
	assert_contains "docker.volume.prune" "$INSTALL_COMMAND_LOG" "docker data purge must be explicit"
	assert_contains "firewall.purge" "$INSTALL_COMMAND_LOG" "firewall purge must be explicit"
	assert_contains "ufw delete allow 22022/tcp" "$INSTALL_COMMAND_LOG" "firewall purge must load PORT_REMOTE_SSH from install-state"
	assert_contains "ufw delete allow 2443/tcp" "$INSTALL_COMMAND_LOG" "firewall purge must load all PORT_REMOTE_* values from install-state"
	assert_contains "ssh.restore" "$INSTALL_COMMAND_LOG" "ssh purge must be explicit"
	assert_contains "network.restore" "$INSTALL_COMMAND_LOG" "network purge must be explicit"
	assert_contains "project.remove" "$INSTALL_COMMAND_LOG" "project root removal must be explicit"
}

test_uninstall_can_remove_docker_engine_with_explicit_flag() {
	make_fixture
	run_installer uninstall --apply --yes --purge-docker-engine
	assert_contains "docker.remove.packages" "$INSTALL_COMMAND_LOG" "docker engine purge must remove packages"
	assert_contains "docker.data.remove" "$INSTALL_COMMAND_LOG" "docker engine purge must remove Docker data dirs"
}

test_self_update_check_persists_branch_without_applying() {
	make_fixture
	export INSTALL_MOCK_REMOTE_VERSION=0.3.0
	export INSTALL_MOCK_REMOTE_CHANGELOG=$'# Журнал изменений установщика\n\n## 0.3.0 - 2026-05-10\n- Новая проверка\n\n## 0.2.0 - 2026-05-09\n- Текущая версия'
	run_installer self-update --branch feature/install --check
	assert_contains "update.branch=feature/install" "$INSTALL_STATE_DIR/config" "branch must be persisted"
	assert_contains "self-update.check" "$INSTALL_COMMAND_LOG" "self-update check must be routed through runner"
	assert_contains "self-update: update available: 0.2.0 -> 0.3.0" "$tmpdir/stdout" "check must report newer remote version"
	assert_contains "## 0.3.0" "$tmpdir/stdout" "check must print newer changelog section"
	assert_not_contains "## 0.2.0" "$tmpdir/stdout" "check must not print current version changelog section"
	assert_not_contains "self-update.apply" "$INSTALL_COMMAND_LOG" "check must not apply files"
}

test_self_update_apply_tolerates_diff_changes() {
	make_fixture
	export INSTALL_MOCK_REMOTE_VERSION=0.3.0
	run_installer self-update --branch feature/install --yes
	assert_contains "self-update.diff" "$INSTALL_COMMAND_LOG" "self-update must record diff"
	assert_contains "self-update.apply" "$INSTALL_COMMAND_LOG" "self-update must continue to apply when diff reports changes"
	assert_contains "self-update: applied feature/install (0.2.0 -> 0.3.0)" "$tmpdir/stdout" "self-update must print applied version range"
}

test_self_update_equal_version_does_not_apply_without_force() {
	make_fixture
	run_installer self-update --branch feature/install --yes
	assert_contains "self-update: up to date (0.2.0)" "$tmpdir/stdout" "equal version must be treated as up to date"
	assert_not_contains "self-update.apply" "$INSTALL_COMMAND_LOG" "equal version must not apply without --force"
}

test_self_update_force_applies_equal_version() {
	make_fixture
	run_installer self-update --branch feature/install --yes --force
	assert_contains "self-update.apply" "$INSTALL_COMMAND_LOG" "force must apply even when versions are equal"
	assert_contains "self-update: applied feature/install (0.2.0 -> 0.2.0)" "$tmpdir/stdout" "force apply must print version range"
}

test_wizard_offers_update_and_uses_same_dispatcher() {
	make_fixture
	printf 'env\n\nx\n' | "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "Update check: installer is up to date (0.2.0)" "$tmpdir/stdout" "wizard must report up-to-date installer without update prompt"
	assert_not_contains "Run self-update now?" "$tmpdir/stdout" "wizard must not prompt when no newer version exists"
	assert_contains "env.render" "$INSTALL_COMMAND_LOG" "wizard env selection must use command dispatcher"
}

test_wizard_offers_update_only_when_newer_version_exists() {
	make_fixture
	export INSTALL_MOCK_REMOTE_VERSION=0.3.0
	export INSTALL_MOCK_REMOTE_CHANGELOG=$'# Журнал изменений установщика\n\n## 0.3.0 - 2026-05-10\n- Новая версия wizard\n\n## 0.2.0 - 2026-05-09\n- Текущая версия'
	printf 'n\nx\n' | "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "Update available: 0.2.0 -> 0.3.0" "$tmpdir/stdout" "wizard must show newer installer version"
	assert_contains "## 0.3.0" "$tmpdir/stdout" "wizard must show newer changelog section"
	assert_not_contains "## 0.2.0" "$tmpdir/stdout" "wizard must not show current changelog section"
	assert_contains "Run self-update now?" "$tmpdir/stdout" "wizard must prompt only for newer version"
	assert_not_contains "self-update.apply" "$INSTALL_COMMAND_LOG" "declined wizard update must not apply"
}

test_wizard_menu_accepts_numbered_choices() {
	make_fixture
	printf '2\n\nx\n' | "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "1. apt" "$tmpdir/stdout" "wizard must show apt as first numbered step"
	assert_contains "2. env" "$tmpdir/stdout" "wizard must show numbered menu"
	assert_contains "env.render" "$INSTALL_COMMAND_LOG" "wizard must dispatch numbered choices"
}

test_wizard_removes_html_and_shows_last_status() {
	make_fixture
	printf '2\n\n9\n\nx\n' | "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "Last operation: OK env" "$tmpdir/stdout" "wizard must show final status for previous operation"
	assert_contains "9. final" "$tmpdir/stdout" "wizard final step must be menu item 9"
	assert_not_contains "html" "$tmpdir/stdout" "wizard must not show removed html step"
	assert_contains "final.summary" "$INSTALL_COMMAND_LOG" "wizard must dispatch final as menu item 8"
}

test_wizard_rejects_unknown_menu_choice_without_exit() {
	make_fixture
	printf '99\n\nx\n' | "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "Last operation: INVALID 99" "$tmpdir/stdout" "wizard must report invalid menu choices"
	assert_contains "Unknown menu item: 99" "$tmpdir/stdout" "wizard must explain invalid menu choice"
	assert_contains "Available steps:" "$tmpdir/stdout" "wizard must continue after invalid menu choice"
}

test_wizard_streams_output_and_waits_for_enter() {
	make_fixture
	printf '7\ny\n\nx\n' | "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "Running network..." "$tmpdir/stdout" "wizard must start step output immediately"
	assert_contains "net.ipv4.tcp_keepalive_time" "$tmpdir/stdout" "wizard must stream step output to the console"
	assert_contains "Press Enter to continue..." "$tmpdir/stdout" "wizard must pause after completed operation"
	assert_contains "Log: $INSTALL_STATE_DIR/wizard-last-network.log" "$tmpdir/stdout" "wizard must keep log link after streamed output"
}

test_wizard_apt_step_streams_and_uses_confirmation() {
	make_fixture
	printf '1\ny\n\nx\n' | "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "Running apt..." "$tmpdir/stdout" "wizard must show step start before apt output"
	assert_contains "Press Enter to continue..." "$tmpdir/stdout" "wizard must wait after apt step"
	assert_contains "apt.update" "$INSTALL_COMMAND_LOG" "apt wizard step must run apt update through runner"
	assert_contains "apt.upgrade" "$INSTALL_COMMAND_LOG" "apt wizard step must run apt upgrade through runner"
}

test_wizard_compose_output_filter_removes_pull_noise() {
	make_fixture
	source "$ROOT_DIR/script/modules/01_menu.sh"
	wizard_filter_compose_output >"$tmpdir/filtered-compose.out" <<'OUT'
[2026-05-08 23:52:53] [run-compose] Каталог с compose-файлами: /opt/docker-proxy/compose.d
[2026-05-08 23:52:53] [run-compose] Используем env-файл: /opt/docker-proxy/compose.d/.env
[2026-05-08 23:52:53] [run-compose] Проверяем конфигурацию: docker compose --project-name docker-proxy --env-file /opt/docker-proxy/compose.d/.env -f /opt/docker-proxy/compose.d/00-base.yml config
[2026-05-08 23:52:55] [run-compose] Попытка 1/3: docker compose --project-name docker-proxy --env-file /opt/docker-proxy/compose.d/.env -f /opt/docker-proxy/compose.d/00-base.yml up -d
 Image torotin/caddy-l4:latest Pulling
 59fccd767ac6 Pulling fs layer 0B
 a57ae2b1d9eb Downloading 10.49MB
 59fccd767ac6 Pull complete 0B
 Image torotin/caddy-l4:latest Pulled
 Container caddy Starting
 Container caddy Healthy
OUT
	assert_contains "Validating compose configuration..." "$tmpdir/filtered-compose.out" "compose filter must keep concise validation status"
	assert_contains "Starting compose stack: Попытка 1/3" "$tmpdir/filtered-compose.out" "compose filter must keep concise attempt status"
	assert_contains "Pulling Docker images..." "$tmpdir/filtered-compose.out" "compose filter must summarize image pulls"
	assert_contains "Docker images pulled" "$tmpdir/filtered-compose.out" "compose filter must summarize pulled images"
	assert_contains "Container caddy Healthy" "$tmpdir/filtered-compose.out" "compose filter must keep container status"
	assert_not_contains "docker compose --project-name" "$tmpdir/filtered-compose.out" "compose filter must hide full compose command"
	assert_not_contains "Downloading 10.49MB" "$tmpdir/filtered-compose.out" "compose filter must hide layer download spam"
	assert_not_contains "Pulling fs layer" "$tmpdir/filtered-compose.out" "compose filter must hide layer pull spam"
}

test_html_step_is_removed_from_cli_dispatch() {
	make_fixture
	if run_installer run html; then
		fail "removed html step must fail"
	fi
	assert_contains "unknown step: html" "$tmpdir/stderr" "removed html step must be rejected"
}

test_wizard_collects_required_variables_before_menu() {
	make_fixture
	unset WEBDOMAIN USER_SSH PASS_SSH USER_WEB PASS_WEB SSH_PBK
	printf 'wizard.example.test\nwizard-user\nwizard-pass\nweb-user\nweb-pass\n\nx\n' | "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "Required installer variables" "$tmpdir/stdout" "wizard must collect required variables before menu"
	assert_contains "Web domain" "$tmpdir/stdout" "wizard must prompt for WEBDOMAIN"
	assert_contains "SSH username" "$tmpdir/stdout" "wizard must prompt for USER_SSH"
	assert_contains "SSH password" "$tmpdir/stdout" "wizard must prompt for PASS_SSH"
	assert_contains "Web username" "$tmpdir/stdout" "wizard must prompt for USER_WEB"
	assert_contains "Web password" "$tmpdir/stdout" "wizard must prompt for PASS_WEB"
	assert_contains "SSH public key" "$tmpdir/stdout" "wizard must offer optional SSH public key"
	assert_contains "1. apt" "$tmpdir/stdout" "wizard must show menu after required prompts"
}

test_wizard_persists_required_variables_before_env_step() {
	make_fixture
	unset WEBDOMAIN USER_SSH PASS_SSH USER_WEB PASS_WEB SSH_PBK
	printf 'persist.example.test\npersist-ssh\nssh-pass\npersist-web\nweb-pass\nssh-ed25519 persist-key\nx\n' | "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains 'WEBDOMAIN="persist.example.test"' "$INSTALL_STATE_DIR/install.env" "wizard must persist WEBDOMAIN immediately"
	assert_contains 'USER_SSH="persist-ssh"' "$INSTALL_STATE_DIR/install.env" "wizard must persist USER_SSH immediately"
	assert_contains 'PASS_SSH="ssh-pass"' "$INSTALL_STATE_DIR/install.env" "wizard must persist PASS_SSH immediately"
	assert_contains 'USER_WEB="persist-web"' "$INSTALL_STATE_DIR/install.env" "wizard must persist USER_WEB immediately"
	assert_contains 'PASS_WEB="web-pass"' "$INSTALL_STATE_DIR/install.env" "wizard must persist PASS_WEB immediately"
	assert_contains 'SSH_PBK="ssh-ed25519 persist-key"' "$INSTALL_STATE_DIR/install.env" "wizard must persist optional SSH key immediately"
}

test_batch_requires_ssh_and_web_credentials() {
	make_fixture
	unset USER_SSH PASS_SSH USER_WEB PASS_WEB
	if run_installer run env; then
		fail "batch run must require SSH/Web credentials"
	fi
	assert_contains "USER_SSH is required" "$tmpdir/stderr" "batch must require USER_SSH first"
}

test_apt_detects_country_specific_mirror_list() {
	make_fixture
	export APT_COUNTRY=RU
	run_installer run apt --apply --yes
	assert_contains "RU.txt" "$INSTALL_COMMAND_LOG" "apt must use country-specific mirror list"
}

test_apt_installs_required_dependencies() {
	make_fixture
	run_installer run apt --apply --yes
	assert_contains "apt.install.deps" "$INSTALL_COMMAND_LOG" "apt must install required dependencies"
	assert_contains "ca-certificates curl gnupg lsb-release apache2-utils gettext-base" "$INSTALL_COMMAND_LOG" "apt dependencies must include installer requirements"
	assert_contains "mc perl openssl lsof ufw jq gzip cron sqlite3 git tcpdump net-tools traceroute whois idn iproute2 rsync sudo openssh-client psmisc unattended-upgrades" "$INSTALL_COMMAND_LOG" "apt dependencies must include legacy utility list"
	assert_contains "apt.locks.wait" "$INSTALL_COMMAND_LOG" "apt must wait for apt/dpkg locks"
	assert_contains "apt.timer.enable" "$INSTALL_COMMAND_LOG" "apt must enable unattended-upgrades timers"
	assert_contains "apt.unattended.dry-run" "$INSTALL_COMMAND_LOG" "apt must validate unattended-upgrades"
}

test_apt_falls_back_when_selected_mirror_update_fails() {
	make_fixture
	export INSTALL_MOCK_APT_UPDATE_FAIL_ONCE=1
	run_installer run apt --apply --yes
	assert_contains "apt.update.fail apt-get update -y" "$INSTALL_COMMAND_LOG" "apt must detect failed update attempt"
	assert_contains "apt.sources.fallback printf fallback\\ mirror\\ %s\\\\n http://archive.ubuntu.com/ubuntu/" "$INSTALL_COMMAND_LOG" "apt must switch to fallback mirror"
	assert_contains "apt.lists.clean rm -rf /var/lib/apt/lists" "$INSTALL_COMMAND_LOG" "apt must clear stale package lists before retry"
	assert_contains "apt.update apt-get update -y" "$INSTALL_COMMAND_LOG" "apt must retry update after fallback"
	assert_contains "apt.install.deps" "$INSTALL_COMMAND_LOG" "apt must install dependencies only after retry"
}

test_wizard_skips_docker_wipe_when_user_declines() {
	make_fixture
	printf 'docker\nn\n\nx\n' | "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "Docker wipe/reinstall skipped" "$tmpdir/stdout" "wizard must keep running when docker wipe is declined"
	assert_contains "Press Enter to continue..." "$tmpdir/stdout" "wizard must pause after skipped operation"
	assert_not_contains "docker.system.prune" "$INSTALL_COMMAND_LOG" "wizard must not wipe Docker when user declines"
}

test_wizard_confirms_apply_steps() {
	make_fixture
	printf 'firewall\ny\n\nssh\ny\n\nnetwork\ny\n\nx\n' | "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "firewall.apply" "$INSTALL_COMMAND_LOG" "wizard must pass apply confirmation to firewall"
	assert_contains "ssh.apply" "$INSTALL_COMMAND_LOG" "wizard must pass apply confirmation to ssh"
	assert_contains "network.apply" "$INSTALL_COMMAND_LOG" "wizard must pass apply confirmation to network"
}

test_wizard_prompts_for_missing_user() {
	make_fixture
	unset USER_SSH PASS_SSH USER_WEB PASS_WEB SSH_PBK
	printf 'wizard-user\nwizard-pass\nweb-user\nweb-pass\n\nuser\n\nx\n' | "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "SSH username" "$tmpdir/stdout" "wizard must prompt for missing USER_SSH"
	assert_contains "user.ensure useradd -m -d /home/wizard-user -s /bin/bash wizard-user" "$INSTALL_COMMAND_LOG" "wizard must pass prompted user to user step"
}

test_user_loads_rendered_state_env() {
	make_fixture
	unset USER_SSH PASS_SSH
	cat >"$INSTALL_STATE_DIR/install.env" <<'ENV'
USER_SSH="state-user"
PASS_SSH="state-pass"
ENV
	run_installer run user
	assert_contains "user.ensure useradd -m -d /home/state-user -s /bin/bash state-user" "$INSTALL_COMMAND_LOG" "user step must load USER_SSH from install-state"
	assert_contains "user.password chpasswd \\<stdin\\>" "$INSTALL_COMMAND_LOG" "user step must feed chpasswd through stdin"
}

test_user_configures_ssh_sudo_groups_and_aliases() {
	make_fixture
	run_installer run user
	assert_contains "user.ssh.dir install -d -m 0700" "$INSTALL_COMMAND_LOG" "user step must prepare .ssh"
	assert_contains "user.ssh.keygen ssh-keygen -t ed25519" "$INSTALL_COMMAND_LOG" "user step must generate ED25519 key"
	assert_contains "user.ssh.authorized.add printf" "$INSTALL_COMMAND_LOG" "user step must add provided SSH public key"
	assert_contains "user.groups usermod -aG sudo\\,docker deployer" "$INSTALL_COMMAND_LOG" "user step must add sudo/docker groups"
	assert_contains "user.sudoers.write" "$INSTALL_COMMAND_LOG" "user step must configure sudoers"
	assert_contains "user.aliases.install" "$INSTALL_COMMAND_LOG" "user step must install bash aliases"
	assert_contains "user.home.chown chown -R deployer:deployer /home/deployer" "$INSTALL_COMMAND_LOG" "user step must restore home ownership"
}

test_compose_uses_installer_state_lock() {
	make_fixture
	run_installer run compose
	assert_contains "project.sync" "$INSTALL_COMMAND_LOG" "compose step must sync project files when runner is missing"
	assert_contains "env.render" "$INSTALL_COMMAND_LOG" "compose step must render env when compose env is missing"
	assert_contains "docker.network.ensure" "$INSTALL_COMMAND_LOG" "compose step must ensure external Docker networks"
	assert_contains "COMPOSE_DIR=$INSTALL_ROOT/compose.d" "$INSTALL_COMMAND_LOG" "compose step must pass explicit compose directory"
	assert_contains "ENV_FILE=$INSTALL_ROOT/compose.d/.env" "$INSTALL_COMMAND_LOG" "compose step must pass explicit compose env file"
	assert_contains "LOCK_FILE=$INSTALL_STATE_DIR/docker-proxy-compose.lock" "$INSTALL_COMMAND_LOG" "compose step must avoid shared /tmp lock file"
	assert_contains "compose.validate env -u HT_PASS_ENCODED -u ADGUARD_ADMIN_HASH -u URI_SUB_PATH -u URI_JSON_PATH -u URI_CLASH_PATH -u URI_VLESS_XHTTP" "$INSTALL_COMMAND_LOG" "compose validation must not inherit transformed values from installer environment"
}

test_final_summary_prints_details() {
	make_fixture
	run_installer run final
	assert_contains "INSTALLATION SUMMARY" "$tmpdir/stdout" "final step must print summary"
	assert_contains "Domain           : example.test" "$tmpdir/stdout" "final summary must include domain"
	assert_contains "Target           : deployer@127.0.0.1:22022" "$tmpdir/stdout" "final summary must include SSH target"
	assert_contains "Homepage         : https://example.test/" "$tmpdir/stdout" "final summary must include service URLs"
	assert_contains "Traefik Dashboard: https://example.test/dashboard/#/" "$tmpdir/stdout" "final summary must include dashboard suffix even when URI is missing"
	assert_contains "Compose validate : $INSTALL_ROOT/compose.d/run-compose.sh validate" "$tmpdir/stdout" "final summary must include operational commands"
	assert_contains "Summary saved: $INSTALL_STATE_DIR/install.summary" "$tmpdir/stdout" "final summary must print saved summary path"
	assert_contains "INSTALLATION SUMMARY" "$INSTALL_STATE_DIR/install.summary" "final step must persist summary file"
	assert_contains "Password         : configured, not printed" "$INSTALL_STATE_DIR/install.summary" "final summary must not print web password"
	assert_not_contains "$PASS_WEB" "$INSTALL_STATE_DIR/install.summary" "final summary must not leak web password"
	assert_not_contains "$PASS_SSH" "$INSTALL_STATE_DIR/install.summary" "final summary must not leak SSH password"
}

test_doctor_rejects_unsupported_os() {
	make_fixture
	cat >"$INSTALL_TEST_OS_RELEASE" <<'OS'
ID=fedora
VERSION_ID=40
OS
	if run_installer doctor; then
		fail "doctor must reject unsupported OS"
	fi
	assert_contains "unsupported OS" "$tmpdir/stderr" "doctor must explain unsupported OS"
}

test_doctor_is_mock_only_and_reports_supported_os
test_doctor_verbose_keeps_detailed_success_output
test_exit_resets_script_and_project_permissions
test_run_dispatches_named_steps_without_eval
test_env_reports_permission_problem_before_backup
test_env_preserves_existing_state_defaults
test_state_loader_preserves_literal_dollars
test_env_prints_rendered_paths
test_env_detects_public_ips_when_missing
test_env_generates_adguard_hash_from_htpasswd
test_env_writes_escaped_htpasswd_to_compose_env_for_labels
test_env_regenerates_stale_htpasswd_when_password_changes
test_env_regenerates_existing_hash_when_verify_is_unsupported
test_adguard_update_pass_uses_precomputed_hash
test_adguard_update_pass_updates_yaml_without_yq
test_state_loader_keeps_explicit_values_over_state
test_destructive_steps_require_explicit_flags
test_destructive_steps_use_mock_runner_when_explicit
test_firewall_preserves_current_ssh_port_for_rollback
test_ssh_rejects_invalid_port_before_apply
test_ssh_restarts_when_listener_check_fails_after_reload
test_ssh_listener_mock_uses_realistic_address_pattern
test_docker_install_handles_missing_docker_binary
test_network_apply_uses_runner
test_uninstall_plan_is_non_destructive
test_uninstall_apply_requires_confirmation
test_uninstall_apply_uses_mock_runner_and_explicit_purge_flags
test_uninstall_can_remove_docker_engine_with_explicit_flag
test_self_update_check_persists_branch_without_applying
test_self_update_apply_tolerates_diff_changes
test_self_update_equal_version_does_not_apply_without_force
test_self_update_force_applies_equal_version
test_wizard_offers_update_and_uses_same_dispatcher
test_wizard_offers_update_only_when_newer_version_exists
test_wizard_menu_accepts_numbered_choices
test_wizard_removes_html_and_shows_last_status
test_wizard_rejects_unknown_menu_choice_without_exit
test_wizard_streams_output_and_waits_for_enter
test_wizard_apt_step_streams_and_uses_confirmation
test_wizard_compose_output_filter_removes_pull_noise
test_html_step_is_removed_from_cli_dispatch
test_wizard_collects_required_variables_before_menu
test_wizard_persists_required_variables_before_env_step
test_batch_requires_ssh_and_web_credentials
test_apt_detects_country_specific_mirror_list
test_apt_installs_required_dependencies
test_apt_falls_back_when_selected_mirror_update_fails
test_wizard_skips_docker_wipe_when_user_declines
test_wizard_confirms_apply_steps
test_wizard_prompts_for_missing_user
test_user_loads_rendered_state_env
test_user_configures_ssh_sudo_groups_and_aliases
test_compose_uses_installer_state_lock
test_final_summary_prints_details
test_doctor_rejects_unsupported_os

printf 'test_installer_cli.bash: OK\n'
