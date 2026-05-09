#!/usr/bin/env bash
# Final summary and self-update command domain.

install_final_command() {
	install_load_state_env
	install_prepare_summary_env
	local template="$SCRIPT_DIR/template/install.summary.template"
	local output="$INSTALL_STATE_DIR/install.summary"
	[[ -f "$template" ]] || die "summary template not found: $template"
	command -v envsubst >/dev/null 2>&1 || die "envsubst is required to render final summary"
	mkdir -p "$(dirname "$output")"
	export SUMMARY_OUTPUT_FILE="$output"
	envsubst <"$template" >"$output"
	run_cmd final.summary printf 'installation summary rendered\n'
	cat "$output"
	printf 'Summary saved: %s\n' "$output"
}

install_prepare_summary_env() {
	SUMMARY_GENERATED_AT=$(date '+%Y-%m-%d %H:%M:%S %z')
	SUMMARY_DOMAIN=${WEBDOMAIN:-example.invalid}
	SUMMARY_PUBLIC_IPV4=${PUBLIC_IPV4:-127.0.0.1}
	SUMMARY_PUBLIC_IPV6=${PUBLIC_IPV6:-$SUMMARY_PUBLIC_IPV4}
	SUMMARY_USER_SSH=${USER_SSH:-unspecified}
	SUMMARY_USER_WEB=${USER_WEB:-unspecified}
	SUMMARY_PORT_REMOTE_SSH=${PORT_REMOTE_SSH:-unspecified}
	SUMMARY_SSH_TARGET="${SUMMARY_USER_SSH}@${SUMMARY_PUBLIC_IPV4}:${SUMMARY_PORT_REMOTE_SSH}"
	SUMMARY_COMPOSE_DIR="$INSTALL_ROOT/compose.d"
	SUMMARY_COMPOSE_ENV="$SUMMARY_COMPOSE_DIR/.env"
	SUMMARY_UPDATE_BRANCH=$(config_get update.branch "$INSTALL_DEFAULT_BRANCH")
	SUMMARY_SSH_AUTH="password"
	if [[ -n "${SSH_PBK:-}" ]]; then
		SUMMARY_SSH_AUTH="public key"
	fi
	SUMMARY_PORT_LOCAL_TRAEFIK=${PORT_LOCAL_TRAEFIK:-4443}
	SUMMARY_PORT_LOCAL_VLESS_PANEL=${PORT_LOCAL_VLESS_PANEL:-unspecified}
	SUMMARY_PORT_LOCAL_VLESS_SUBSCRIBE=${PORT_LOCAL_VLESS_SUBSCRIBE:-unspecified}
	SUMMARY_PORT_LOCAL_XHTTP=${PORT_LOCAL_XHTTP:-unspecified}
	SUMMARY_PORT_LOCAL_VISION=${PORT_LOCAL_VISION:-unspecified}
	SUMMARY_PORT_LOCAL_DOZZLE=${PORT_LOCAL_DOZZLE:-unspecified}
	SUMMARY_PORT_LOCAL_CADDYWEB=${PORT_LOCAL_CADDYWEB:-unspecified}
	SUMMARY_PORT_LOCAL_CROWDSEC_API=${PORT_LOCAL_CROWDSEC_API:-unspecified}
	SUMMARY_URL_HOMEPAGE=$(install_summary_url "${URI_HOMEPAGE:-}")
	SUMMARY_URL_3X_UI=$(install_summary_url "${URI_PANEL_PATH:-}")
	SUMMARY_URL_ADGUARD=$(install_summary_url "${URI_ADGUARD_PANEL:-}")
	SUMMARY_URL_ADGUARD_DOH=$(install_summary_url "${URI_ADGUARD_DOH:-}")
	SUMMARY_URL_DOZZLE=$(install_summary_url "${URI_DOZZLE:-}")
	SUMMARY_URL_TRAEFIK=$(install_summary_url "${URI_TRAEFIK_DASHBOARD:-}" "dashboard/#/")
	export SUMMARY_GENERATED_AT SUMMARY_DOMAIN SUMMARY_PUBLIC_IPV4 SUMMARY_PUBLIC_IPV6
	export SUMMARY_USER_SSH SUMMARY_USER_WEB SUMMARY_PORT_REMOTE_SSH SUMMARY_SSH_TARGET SUMMARY_SSH_AUTH
	export SUMMARY_COMPOSE_DIR SUMMARY_COMPOSE_ENV SUMMARY_UPDATE_BRANCH
	export SUMMARY_PORT_LOCAL_TRAEFIK SUMMARY_PORT_LOCAL_VLESS_PANEL SUMMARY_PORT_LOCAL_VLESS_SUBSCRIBE
	export SUMMARY_PORT_LOCAL_XHTTP SUMMARY_PORT_LOCAL_VISION SUMMARY_PORT_LOCAL_DOZZLE SUMMARY_PORT_LOCAL_CADDYWEB
	export SUMMARY_PORT_LOCAL_CROWDSEC_API
	export SUMMARY_URL_HOMEPAGE SUMMARY_URL_3X_UI SUMMARY_URL_ADGUARD SUMMARY_URL_ADGUARD_DOH
	export SUMMARY_URL_DOZZLE SUMMARY_URL_TRAEFIK
}

install_summary_url() {
	local path=${1:-} suffix=${2:-}
	path=${path#/}
	suffix=${suffix#/}
	if [[ -n "$path" && -n "$suffix" ]]; then
		printf 'https://%s/%s/%s\n' "${SUMMARY_DOMAIN:-example.invalid}" "$path" "$suffix"
	elif [[ -n "$suffix" ]]; then
		printf 'https://%s/%s\n' "${SUMMARY_DOMAIN:-example.invalid}" "$suffix"
	elif [[ -n "$path" ]]; then
		printf 'https://%s/%s\n' "${SUMMARY_DOMAIN:-example.invalid}" "$path"
	else
		printf 'https://%s/\n' "${SUMMARY_DOMAIN:-example.invalid}"
	fi
}

install_version_file() {
	printf '%s/VERSION\n' "$SCRIPT_DIR"
}

install_changelog_file() {
	printf '%s/CHANGELOG.md\n' "$SCRIPT_DIR"
}

install_read_version_file() {
	local file=$1 version
	[[ -f "$file" ]] || die "version file not found: $file"
	version=$(sed -n '1{s/[[:space:]]//g;p;q;}' "$file")
	install_validate_semver "$version"
	printf '%s\n' "$version"
}

install_validate_semver() {
	local version=$1
	[[ "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || die "invalid installer version: $version"
}

install_compare_semver() {
	local left=$1 right=$2
	install_validate_semver "$left"
	install_validate_semver "$right"
	local IFS=. left_major left_minor left_patch right_major right_minor right_patch
	read -r left_major left_minor left_patch <<<"$left"
	read -r right_major right_minor right_patch <<<"$right"
	if ((left_major > right_major)); then
		printf '1\n'
	elif ((left_major < right_major)); then
		printf -- '-1\n'
	elif ((left_minor > right_minor)); then
		printf '1\n'
	elif ((left_minor < right_minor)); then
		printf -- '-1\n'
	elif ((left_patch > right_patch)); then
		printf '1\n'
	elif ((left_patch < right_patch)); then
		printf -- '-1\n'
	else
		printf '0\n'
	fi
}

install_self_update_fetch_tree() {
	local branch=$1 tmp=$2
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd self-update.fetch git clone --depth 1 --branch "$branch" "$INSTALL_REPO_URL" "$tmp"
		mkdir -p "$tmp/script"
		printf '%s\n' "${INSTALL_MOCK_REMOTE_VERSION:-$(install_read_version_file "$(install_version_file)")}" >"$tmp/script/VERSION"
		if [[ -n "${INSTALL_MOCK_REMOTE_CHANGELOG:-}" ]]; then
			printf '%s\n' "$INSTALL_MOCK_REMOTE_CHANGELOG" >"$tmp/script/CHANGELOG.md"
		else
			cp "$(install_changelog_file)" "$tmp/script/CHANGELOG.md" 2>/dev/null || :
		fi
		return 0
	fi
	run_cmd self-update.fetch git clone --depth 1 --branch "$branch" "$INSTALL_REPO_URL" "$tmp"
}

install_print_changelog_range() {
	local changelog=$1 local_version=$2 remote_version=$3
	[[ -f "$changelog" ]] || return 0
	awk -v local="$local_version" -v remote="$remote_version" '
		function cmp(a, b, aa, bb, i) {
			split(a, aa, ".")
			split(b, bb, ".")
			for (i = 1; i <= 3; i++) {
				aa[i] += 0
				bb[i] += 0
				if (aa[i] > bb[i]) return 1
				if (aa[i] < bb[i]) return -1
			}
			return 0
		}
		/^##[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+/ {
			version=$2
			printing=(cmp(version, local) > 0 && cmp(version, remote) <= 0)
		}
		printing {print}
	' "$changelog"
}

install_self_update_prepare() {
	local branch=$1 result_file=$2 tmp local_version remote_version compare
	tmp=$(mktemp -d)
	install_self_update_fetch_tree "$branch" "$tmp"
	local_version=$(install_read_version_file "$(install_version_file)")
	remote_version=$(install_read_version_file "$tmp/script/VERSION")
	compare=$(install_compare_semver "$remote_version" "$local_version")
	{
		printf 'tmp=%s\n' "$tmp"
		printf 'local_version=%s\n' "$local_version"
		printf 'remote_version=%s\n' "$remote_version"
		printf 'update_available=%s\n' "$([[ "$compare" == "1" ]] && printf 1 || printf 0)"
	} >"$result_file"
}

install_self_update_load_result() {
	local result_file=$1 line key value
	while IFS= read -r line || [[ -n "$line" ]]; do
		key=${line%%=*}
		value=${line#*=}
		case "$key" in
		tmp) SELF_UPDATE_TMP=$value ;;
		local_version) SELF_UPDATE_LOCAL_VERSION=$value ;;
		remote_version) SELF_UPDATE_REMOTE_VERSION=$value ;;
		update_available) SELF_UPDATE_AVAILABLE=$value ;;
		esac
	done <"$result_file"
	export SELF_UPDATE_TMP SELF_UPDATE_LOCAL_VERSION SELF_UPDATE_REMOTE_VERSION SELF_UPDATE_AVAILABLE
}

install_self_update_print_check() {
	local tmp=$1 local_version=$2 remote_version=$3 available=$4
	if [[ "$available" == "1" ]]; then
		printf 'self-update: update available: %s -> %s\n' "$local_version" "$remote_version"
		install_print_changelog_range "$tmp/script/CHANGELOG.md" "$local_version" "$remote_version"
	else
		printf 'self-update: up to date (%s)\n' "$local_version"
	fi
}

install_self_update_command() {
	local branch check=0 yes=0 force=0 arg
	branch=$(config_get update.branch "$INSTALL_DEFAULT_BRANCH")
	while (($# > 0)); do
		arg=$1
		shift
		case "$arg" in
		--branch)
			(($# > 0)) || die "--branch requires a value"
			branch=$1
			shift
			;;
		--check) check=1 ;;
		--yes) yes=1 ;;
		--force) force=1 ;;
		*) die "unknown self-update option: $arg" ;;
		esac
	done
	config_set update.branch "$branch"
	local result_file tmp local_version remote_version available
	result_file=$(mktemp)
	install_self_update_prepare "$branch" "$result_file"
	install_self_update_load_result "$result_file"
	rm -f "$result_file"
	tmp=$SELF_UPDATE_TMP
	local_version=$SELF_UPDATE_LOCAL_VERSION
	remote_version=$SELF_UPDATE_REMOTE_VERSION
	available=$SELF_UPDATE_AVAILABLE
	if ((check)); then
		run_cmd self-update.check printf 'checked branch %s\n' "$branch"
		install_self_update_print_check "$tmp" "$local_version" "$remote_version" "$available"
		rm -rf "$tmp"
		return 0
	fi
	if [[ "$available" != "1" && "$force" != "1" ]]; then
		printf 'self-update: up to date (%s)\n' "$local_version"
		rm -rf "$tmp"
		return 0
	fi
	if ((yes == 0)) && [[ "$INSTALL_NONINTERACTIVE" == "1" ]]; then
		rm -rf "$tmp"
		die "self-update apply requires --yes in non-interactive mode"
	fi
	local diff_rc
	set +e
	run_cmd self-update.diff diff -ruN "$SCRIPT_DIR" "$tmp/script"
	diff_rc=$?
	set -e
	if ((diff_rc > 1)); then
		rm -rf "$tmp"
		die "self-update diff failed"
	fi
	run_cmd self-update.apply rsync -a --delete --exclude install-state "$tmp/script/" "$SCRIPT_DIR/"
	rm -rf "$tmp"
	printf 'self-update: applied %s (%s -> %s)\n' "$branch" "$local_version" "$remote_version"
}
