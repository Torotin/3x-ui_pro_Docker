#!/usr/bin/env bash
# Wizard/menu runtime. The wizard delegates to the same dispatcher as CLI run.

install_wizard_print_menu() {
	if [[ -t 1 ]]; then
		printf '\033[H\033[2J'
	fi
	cat <<'MENU'
Available steps:
  1. apt       Select APT mirror and update OS packages
  2. env       Render installer and compose env files
  3. docker    Install/prepare Docker resources
  4. user      Create or update service user
  5. firewall  Apply firewall policy
  6. ssh       Apply SSH policy
  7. network   Apply sysctl/network tuning
  8. compose   Validate/start compose stack
  9. final     Render final summary
  x. Exit
MENU
}

install_wizard_print_status() {
	local status=${WIZARD_LAST_STATUS:-No operation yet}
	printf '\nLast operation: %s\n\n' "$status"
}

wizard_normalize_step() {
	case "$1" in
	1) printf 'apt\n' ;;
	2) printf 'env\n' ;;
	3) printf 'docker\n' ;;
	4) printf 'user\n' ;;
	5) printf 'firewall\n' ;;
	6) printf 'ssh\n' ;;
	7) printf 'network\n' ;;
	8) printf 'compose\n' ;;
	9) printf 'final\n' ;;
	*) printf '%s\n' "$1" ;;
	esac
}

wizard_execute_step() {
	local label=$1
	shift
	local output_file="$INSTALL_STATE_DIR/wizard-last-${label}.log"
	local rc
	printf '\nRunning %s...\n\n' "$label"
	set +e
	if [[ "$label" == "compose" ]]; then
		"$@" 2>&1 | tee "$output_file" | wizard_filter_compose_output
		rc=${PIPESTATUS[0]}
	else
		"$@" 2>&1 | tee "$output_file"
		rc=${PIPESTATUS[0]}
	fi
	set -e
	if ((rc == 0)); then
		WIZARD_LAST_STATUS="OK $label"
		printf '\nLast operation: OK %s\nLog: %s\n' "$label" "$output_file"
		wizard_wait_continue
		return 0
	fi
	WIZARD_LAST_STATUS="FAILED $label"
	printf '\nLast operation: FAILED %s\nLog: %s\n' "$label" "$output_file"
	wizard_wait_continue
	return "$rc"
}

wizard_wait_continue() {
	local _
	printf '\nPress Enter to continue...'
	read -r _ || true
}

wizard_filter_compose_output() {
	awk '
		/^[[:space:]]*[[:xdigit:]]{12,}[[:space:]]+(Pulling fs layer|Downloading|Download complete|Extracting|Pull complete)[[:space:]]/ {
			if (!pulling) {
				print "Pulling Docker images..."
				pulling=1
			}
			next
		}
		/^ Image .* Pulling$/ {
			if (!pulling) {
				print "Pulling Docker images..."
				pulling=1
			}
			next
		}
		/^ Image .* Pulled$/ {
			if (!pulled) {
				print "Docker images pulled"
				pulled=1
			}
			next
		}
		/\[run-compose\] Проверяем конфигурацию: / {
			print "Validating compose configuration..."
			next
		}
		/\[run-compose\] Попытка [0-9]+\/[0-9]+: / {
			line=$0
			sub(/^.*\[run-compose\] /, "", line)
			sub(/: docker compose .*$/, "", line)
			print "Starting compose stack: " line
			next
		}
		/\[run-compose\] Каталог с compose-файлами:/ {next}
		/\[run-compose\] Используем env-файл:/ {next}
		{print}
	'
}

wizard_offer_self_update() {
	local branch result_file tmp local_version remote_version available answer
	branch=$(config_get update.branch "$INSTALL_DEFAULT_BRANCH")
	result_file=$(mktemp)
	if ! (install_self_update_prepare "$branch" "$result_file"); then
		rm -f "$result_file"
		log WARN "self-update check failed"
		return 0
	fi
	install_self_update_load_result "$result_file"
	rm -f "$result_file"
	tmp=$SELF_UPDATE_TMP
	local_version=$SELF_UPDATE_LOCAL_VERSION
	remote_version=$SELF_UPDATE_REMOTE_VERSION
	available=$SELF_UPDATE_AVAILABLE
	if [[ "$available" != "1" ]]; then
		printf 'Update check: installer is up to date (%s)\n' "$local_version"
		rm -rf "$tmp"
		return 0
	fi
	printf 'Update available: %s -> %s\n' "$local_version" "$remote_version"
	install_print_changelog_range "$tmp/script/CHANGELOG.md" "$local_version" "$remote_version"
	rm -rf "$tmp"
	printf 'Run self-update now? [y/N] '
	read -r answer || answer=n
	case "$answer" in
	y | Y | yes | YES) install_self_update_command --branch "$branch" --yes ;;
	*) log INFO "self-update skipped" >/dev/null ;;
	esac
}

wizard_confirm() {
	local prompt=$1 answer
	printf '%s [y/N] ' "$prompt"
	read -r answer || answer=n
	case "$answer" in
	y | Y | yes | YES) return 0 ;;
	*) return 1 ;;
	esac
}

wizard_dispatch_step() {
	local input=$1
	case "$input" in
	apt)
		if wizard_confirm "Select fastest APT mirror and update OS packages?"; then
			wizard_execute_step apt dispatch_step apt --apply --yes
		else
			WIZARD_LAST_STATUS="SKIPPED apt"
			printf '\nAPT mirror/update skipped\n'
			wizard_wait_continue
		fi
		;;
	docker)
		if wizard_confirm "Destroy Docker data and reinstall Docker?"; then
			wizard_execute_step docker dispatch_step docker --destroy-docker-data
		else
			WIZARD_LAST_STATUS="SKIPPED docker"
			printf '\nDocker wipe/reinstall skipped\n'
			wizard_wait_continue
		fi
		;;
	firewall | ssh | network)
		if wizard_confirm "Apply $input system changes?"; then
			wizard_execute_step "$input" dispatch_step "$input" --apply --yes
		else
			WIZARD_LAST_STATUS="SKIPPED $input"
			printf '\n%s apply skipped\n' "$input"
			wizard_wait_continue
		fi
		;;
	user)
		install_load_state_env
		if [[ -z "${USER_SSH:-}" ]]; then
			printf 'SSH username: '
			read -r USER_SSH || USER_SSH=
			export USER_SSH
		fi
		wizard_execute_step user dispatch_step user
		;;
	env | compose | final)
		wizard_execute_step "$input" dispatch_step "$input"
		;;
	*)
		WIZARD_LAST_STATUS="INVALID $input"
		printf '\nUnknown menu item: %s\n' "$input"
		wizard_wait_continue
		return 0
		;;
	esac
}

install_wizard() {
	wizard_offer_self_update
	install_require_required_env wizard

	while true; do
		install_wizard_print_menu
		printf '> '
		install_wizard_print_status
		local input
		read -r input || break
		[[ -z "$input" ]] && continue
		[[ "$input" == "x" ]] && break
		input=$(wizard_normalize_step "$input")
		if ! wizard_dispatch_step "$input"; then
			log WARN "wizard step failed: $input"
		fi
	done
}
