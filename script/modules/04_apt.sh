#!/usr/bin/env bash
# APT mirror selection and OS update command domain.

apt_os_codename() {
	local os_file=${INSTALL_TEST_OS_RELEASE:-/etc/os-release} codename=""
	while IFS='=' read -r key value; do
		value=${value%\"}
		value=${value#\"}
		[[ "$key" == "VERSION_CODENAME" ]] && codename=$value
		[[ "$key" == "UBUNTU_CODENAME" && -z "$codename" ]] && codename=$value
	done <"$os_file"
	printf '%s\n' "$codename"
}

apt_os_id() {
	local os_file=${INSTALL_TEST_OS_RELEASE:-/etc/os-release} id=""
	while IFS='=' read -r key value; do
		value=${value%\"}
		value=${value#\"}
		[[ "$key" == "ID" ]] && id=$value
	done <"$os_file"
	printf '%s\n' "$id"
}

install_apt_required_packages() {
	printf '%s\n' \
		ca-certificates \
		curl \
		gnupg \
		lsb-release \
		apache2-utils \
		gettext-base \
		mc \
		perl \
		openssl \
		lsof \
		ufw \
		jq \
		gzip \
		cron \
		sqlite3 \
		git \
		tcpdump \
		net-tools \
		traceroute \
		whois \
		idn \
		iproute2 \
		rsync \
		sudo \
		openssh-client \
		psmisc \
		unattended-upgrades
}

install_apt_command() {
	require_opt_in --apply "$@"
	require_apply_confirmation "$@"
	install_apt_wait_for_locks
	local -a required_packages=()
	mapfile -t required_packages < <(install_apt_required_packages)
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		local country="${APT_COUNTRY:-}"
		if [[ -z "$country" ]]; then
			country=ZZ
			run_cmd apt.country.detect curl -fsSL https://ipapi.co/country/
		fi
		run_cmd apt.mirror.check curl -fsSL "http://mirrors.ubuntu.com/$country.txt"
		run_cmd apt.sources.backup cp /etc/apt/sources.list "$INSTALL_STATE_DIR/backups/sources.list"
		install_apt_update_with_fallback ubuntu noble
		run_cmd apt.install.deps apt-get install -y "${required_packages[@]}"
		run_cmd apt.list.upgradable apt list --upgradable
		run_cmd apt.upgrade apt-get upgrade -y -V
		run_cmd apt.autoremove apt-get autoremove -y
		install_apt_enable_auto_updates
		printf 'APT mirror check completed\nAPT package list updated\nAPT upgrade completed\n'
		return 0
	fi
	local os_id codename
	os_id=$(apt_os_id)
	codename=$(apt_os_codename)
	[[ -n "$codename" ]] || die "could not detect OS codename"
	if [[ "$os_id" == "ubuntu" ]]; then
		install_apt_pick_ubuntu_mirror "$codename"
	else
		printf 'APT mirror selection skipped for OS: %s\n' "$os_id"
	fi
	install_apt_update_with_fallback "$os_id" "$codename"
	run_cmd apt.install.deps env DEBIAN_FRONTEND=noninteractive apt-get install -y "${required_packages[@]}" || die "failed to install required APT packages"
	local updates
	updates=$(apt list --upgradable 2>/dev/null | grep -c "upgradable" || true)
	printf 'Upgradable packages: %s\n' "$updates"
	if ((updates > 0)); then
		run_cmd apt.upgrade env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -V || die "APT upgrade failed"
		run_cmd apt.autoremove apt-get autoremove -y || die "APT autoremove failed"
	else
		printf 'No upgrades available; system is up to date\n'
	fi
	install_apt_enable_auto_updates
	printf 'APT package list updated\nAPT upgrade completed\n'
}

install_apt_update_with_fallback() {
	local os_id=$1 codename=$2 fallback_mirror="${APT_FALLBACK_MIRROR:-http://archive.ubuntu.com/ubuntu/}"
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		if [[ "${INSTALL_MOCK_APT_UPDATE_FAIL_ONCE:-0}" == "1" && -z "${INSTALL_MOCK_APT_UPDATE_FAILED_ONCE:-}" ]]; then
			INSTALL_MOCK_APT_UPDATE_FAILED_ONCE=1
			export INSTALL_MOCK_APT_UPDATE_FAILED_ONCE
			run_cmd apt.update.fail apt-get update -y
			if [[ "$os_id" == "ubuntu" ]]; then
				run_cmd apt.sources.fallback printf 'fallback mirror %s\n' "$fallback_mirror"
				run_cmd apt.lists.clean rm -rf /var/lib/apt/lists
			fi
		fi
		run_cmd apt.update apt-get update -y
		return 0
	fi
	if run_cmd apt.update apt-get update -y; then
		return 0
	fi
	if [[ "$os_id" != "ubuntu" ]]; then
		die "APT update failed"
	fi
	log WARN "APT update failed; selected mirror may be syncing. Falling back to $fallback_mirror"
	install_apt_apply_ubuntu_mirror "$codename" "$fallback_mirror"
	run_cmd apt.lists.clean bash -c 'rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/partial/*'
	run_cmd apt.update.fallback apt-get update -y || die "APT update failed after fallback mirror"
}

install_apt_wait_for_locks() {
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd apt.locks.wait test apt-locks-free
		return 0
	fi
	local attempts="${APT_LOCK_ATTEMPTS:-24}" sleep_secs="${APT_LOCK_SLEEP:-5}" i lock
	local locks=(
		/var/lib/dpkg/lock-frontend
		/var/lib/dpkg/lock
		/var/cache/apt/archives/lock
		/var/lib/apt/lists/lock
	)
	for ((i = 1; i <= attempts; i++)); do
		local busy=0
		for lock in "${locks[@]}"; do
			if fuser "$lock" >/dev/null 2>&1; then
				busy=1
				break
			fi
		done
		((busy == 0)) && return 0
		printf 'APT/dpkg lock is busy; waiting (%s/%s)\n' "$i" "$attempts"
		sleep "$sleep_secs"
	done
	die "APT/dpkg lock is still busy"
}

install_apt_pick_ubuntu_mirror() {
	local codename=$1 limit="${APT_MIRROR_LIMIT:-8}" list_url="${APT_MIRROR_LIST_URL:-}"
	local sources="/etc/apt/sources.list" deb822="/etc/apt/sources.list.d/ubuntu.sources"
	local best="" mirror release_url country
	country="${APT_COUNTRY:-$(install_apt_detect_country || true)}"
	if [[ -z "$list_url" ]]; then
		list_url=$(install_apt_country_mirror_list_url "$country")
	fi
	printf 'Testing Ubuntu mirrors from %s\n' "$list_url"
	while IFS= read -r mirror; do
		[[ "$mirror" =~ ^https?:// ]] || continue
		release_url="${mirror%/}/dists/$codename/Release"
		if curl -ILfs --max-time 4 "$release_url" >/dev/null 2>&1; then
			best="${mirror%/}/"
			break
		fi
		((--limit <= 0)) && break
	done < <(curl -fsSL "$list_url")
	[[ -n "$best" ]] || {
		printf 'No faster Ubuntu mirror selected; keeping current APT sources\n'
		return 0
	}
	printf 'Selected Ubuntu mirror: %s\n' "$best"
	install_apt_apply_ubuntu_mirror "$codename" "$best"
}

install_apt_apply_ubuntu_mirror() {
	local codename=$1 mirror=$2
	local sources="/etc/apt/sources.list" deb822="/etc/apt/sources.list.d/ubuntu.sources"
	if [[ -f "$deb822" ]]; then
		backup_file "$deb822"
		local tmp
		tmp=$(mktemp)
		awk -v mirror="$mirror" '
			/^URIs:/ {$0="URIs: " mirror}
			{print}
		' "$deb822" >"$tmp"
		run_cmd apt.sources.apply install -m 0644 "$tmp" "$deb822"
		rm -f "$tmp"
	elif [[ -f "$sources" ]]; then
		backup_file "$sources"
		run_cmd apt.sources.apply sed -i -E "s|https?://[^ ]*/ubuntu/?|$mirror|g" "$sources"
	else
		local tmp
		tmp=$(mktemp)
		cat >"$tmp" <<EOF
deb ${mirror} ${codename} main restricted universe multiverse
deb ${mirror} ${codename}-updates main restricted universe multiverse
deb ${mirror} ${codename}-backports main restricted universe multiverse
deb ${mirror} ${codename}-security main restricted universe multiverse
EOF
		run_cmd apt.sources.apply install -m 0644 "$tmp" "$sources"
		rm -f "$tmp"
	fi
}

install_apt_detect_country() {
	local country
	country=$(curl -fsSL --max-time 3 https://ipapi.co/country/ 2>/dev/null || true)
	[[ "$country" =~ ^[A-Za-z]{2}$ ]] || country=$(curl -fsSL --max-time 3 https://ifconfig.co/country-iso 2>/dev/null || true)
	[[ "$country" =~ ^[A-Za-z]{2}$ ]] || return 1
	printf '%s\n' "$(tr '[:lower:]' '[:upper:]' <<<"$country")"
}

install_apt_country_mirror_list_url() {
	local country=$1 base="http://mirrors.ubuntu.com" lc
	if [[ "$country" =~ ^[A-Za-z]{2}$ ]]; then
		lc=$(tr '[:upper:]' '[:lower:]' <<<"$country")
		local candidate
		for candidate in "$base/mirrors.$lc.txt" "$base/$country.txt" "$base/$lc.txt"; do
			if curl -fsI --max-time 3 "$candidate" >/dev/null 2>&1; then
				printf '%s\n' "$candidate"
				return 0
			fi
		done
	fi
	printf '%s\n' "$base/mirrors.txt"
}

install_apt_enable_auto_updates() {
	local mode="${AUTO_UPDATES_MODE:-all}"
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd apt.auto.install apt-get install -y unattended-upgrades
		run_cmd apt.auto.write install -m 0644 20auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades
		run_cmd apt.unattended.write install -m 0644 50unattended-upgrades /etc/apt/apt.conf.d/50unattended-upgrades
		run_cmd apt.timer.enable systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
		install_apt_unattended_dry_run
		return 0
	fi
	run_cmd apt.auto.install env DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades
	install_apt_write_auto_upgrades "$mode"
	run_cmd apt.timer.enable systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
	if install_apt_wait_for_locks; then
		install_apt_unattended_dry_run
	fi
}

install_apt_unattended_dry_run() {
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd apt.unattended.dry-run unattended-upgrade --dry-run --debug
		return 0
	fi
	runner_log apt.unattended.dry-run unattended-upgrade --dry-run --debug ">>$INSTALL_LOG_FILE"
	if unattended-upgrade --dry-run --debug >>"$INSTALL_LOG_FILE" 2>&1; then
		printf 'unattended-upgrade dry-run completed; details: %s\n' "$INSTALL_LOG_FILE"
	else
		log WARN "unattended-upgrade dry-run reported issues; details: $INSTALL_LOG_FILE"
	fi
}

install_apt_write_auto_upgrades() {
	local mode=$1 auto_file=/etc/apt/apt.conf.d/20auto-upgrades unattended_file=/etc/apt/apt.conf.d/50unattended-upgrades tmp
	backup_file "$auto_file"
	tmp=$(mktemp)
	cat >"$tmp" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
	run_cmd apt.auto.write install -m 0644 "$tmp" "$auto_file"
	rm -f "$tmp"

	backup_file "$unattended_file"
	tmp=$(mktemp)
	cat >"$tmp" <<EOF
// Managed by install.sh
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
$([[ "$mode" == "all" ]] && printf '    "${distro_id}:${distro_codename}-updates";\n')
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
	run_cmd apt.unattended.write install -m 0644 "$tmp" "$unattended_file"
	rm -f "$tmp"
	printf 'Automatic APT updates enabled: %s\n' "$mode"
}
