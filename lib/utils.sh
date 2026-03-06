#!/usr/bin/env bash
#
# sing-box deployment project - utility functions
#

# ============================================================================
# Terminal color codes
# ============================================================================
# Emit ANSI colors only when stdout is a TTY
if [[ -t 1 ]]; then
	RED=$'\033[0;31m'
	GREEN=$'\033[0;32m'
	YELLOW=$'\033[1;33m'
	BLUE=$'\033[0;34m'
	NC=$'\033[0m'
else
	RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

# ============================================================================
# Standard exit codes
# ============================================================================
export E_GENERAL=1
export E_NETWORK=10
export E_CONFIG=11
export E_LOCK=12
export E_PERMISSION=13
export E_DEPENDENCY=14

_redact() {
	# Redact URLs, IPs, tokens, and secrets from output
	sed -E \
		-e 's#https?://[^[:space:]]+#<REDACTED_URL>#g' \
		-e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<REDACTED_IP>/g' \
		-e 's/(token|key|secret|password|uuid|private_key|pre_shared_key|auth_str|username|peer)=[^&[:space:]]+/\1=<REDACTED>/gi' \
		-e 's/"(token|key|secret|password|uuid|private_key|pre_shared_key|auth_str|username|peer)"[[:space:]]*:[[:space:]]*"[^"]*"/"\1":""/gi'
}

_on_err() {
	local rc="$1" line="$2" cmd="$3" file="${4:-$0}"
	local cmd_safe
	cmd_safe="$(printf '%s' "$cmd" | _redact)"

	echo -e "${RED}[ERROR]${NC} File: ${file}"
	echo -e "${RED}[ERROR]${NC} Step: ${CURRENT_STEP:-init}"
	echo -e "${RED}[ERROR]${NC} Line: ${line}, exit code: ${rc}"
	echo -e "${RED}[ERROR]${NC} Command: ${cmd_safe}"

	# Trouble-shooting advice based on standardized exit codes
	case "$rc" in
		"$E_NETWORK")    echo -e "${YELLOW}[HINT] Network connection failed. Check DNS or whether the domain is blocked in your region.${NC}" ;;
		"$E_CONFIG")     echo -e "${YELLOW}[HINT] Config file format, parameters, or dependency missing. Verify jq output and input payload.${NC}" ;;
		"$E_LOCK")       echo -e "${YELLOW}[HINT] Failed to acquire file lock. If a stale process exists, try cleaning the lock file manually.${NC}" ;;
		"$E_PERMISSION") echo -e "${YELLOW}[HINT] Insufficient permissions. Run with sudo and check file access rights.${NC}" ;;
		"$E_DEPENDENCY") echo -e "${YELLOW}[HINT] Missing system dependency (curl, jq, iptables, etc). Verify prerequisite setup.${NC}" ;;
		*)               echo -e "${YELLOW}[HINT] Unknown error. Review the command above and system logs below.${NC}" ;;
	esac

	# Dump recent sing-box journal logs if the unit exists
	if command -v systemctl >/dev/null 2>&1; then
		if systemctl status sing-box --no-pager -n 30 >/dev/null 2>&1; then
			journalctl -u sing-box -n 120 --no-pager 2>/dev/null || true
		fi
	fi

	exit "$rc"
}

# ============================================================================
# Trap stack management
# ============================================================================
declare -a TRAP_STACK=()

push_trap() {
	local name="$1"
	local cmd="$2"
	# Extract current ERR trap command using awk (handles single quotes in content better than sed)
	local current_trap
	current_trap=$(trap -p ERR 2>/dev/null | awk -F"'" 'NF>=2{print $2}' || true)

	if [ -z "$current_trap" ]; then
		current_trap="__EMPTY__"
	fi

	# Push named entry onto stack for pop-time validation
	TRAP_STACK+=("${name}::${current_trap}")

	# Chain new trap handler with the existing one
	if [ "$current_trap" != "__EMPTY__" ]; then
		# shellcheck disable=SC2064
		trap "$cmd; $current_trap" ERR
	else
		# shellcheck disable=SC2064
		trap "$cmd" ERR
	fi
}

pop_trap() {
	local expected_name="${1:-}"
	if [ ${#TRAP_STACK[@]} -eq 0 ]; then
		return 0
	fi

	local last_entry="${TRAP_STACK[-1]}"
	unset 'TRAP_STACK[-1]'

	# Validate tag name matches expected
	local tag="${last_entry%%::*}"
	local last_trap="${last_entry#*::}"
	if [ -n "$expected_name" ] && [ "$tag" != "$expected_name" ]; then
		log_warn "Trap stack mismatch: expected '$expected_name', got '$tag'"
	fi

	if [ "$last_trap" == "__EMPTY__" ]; then
		trap - ERR
	else
		# shellcheck disable=SC2064
		trap "$last_trap" ERR
	fi
}

_on_err_trap() {
	local rc="$1" line="$2" cmd="$3" file="$4"
	_on_err "$rc" "$line" "$cmd" "$file"
}

cleanup() {
	# Unset known sensitive variables to avoid leaking secrets
	unset AIRPORT_URLS AIRPORT_URLS_STR AIRPORT_TAGS NEXTDNS_ID REMOTE_MAIN_TAG 2>/dev/null || true
	unset SUBSCRIBE_COMMIT AIRPORT_URLS_STR 2>/dev/null || true

	# Clean up temp files
	rm -f /usr/local/etc/sing-box/*.tmp 2>/dev/null || true
	rm -f /var/lib/sing-box/ruleset/*.tmp 2>/dev/null || true
	rm -f /tmp/singbox-* 2>/dev/null || true
}

_array_contains() {
	local needle="$1"
	shift
	local x
	for x in "$@"; do
		[[ "$x" == "$needle" ]] && return 0
	done
	return 1
}

log_info()  { printf "${GREEN}[INFO]${NC}  [%(%H:%M:%S)T] %s\n"  -1 "$*"; }
log_warn()  { printf "${YELLOW}[WARN]${NC}  [%(%H:%M:%S)T] %s\n"  -1 "$*"; }
log_error() { printf "${RED}[ERROR]${NC} [%(%H:%M:%S)T] %s\n" -1 "$*"; }
log_step()  {
	CURRENT_STEP="$*"
	printf "${BLUE}[STEP]${NC}  [%(%H:%M:%S)T] %s\n" -1 "$*"
}

_run() {
	# Always execute mkdir even in dry-run (later steps depend on it)
	if [[ "$1" == "mkdir" ]]; then
		if [ "${DRY_RUN:-0}" -eq 1 ]; then
			echo -e "${YELLOW}[DRY-RUN]${NC} $* (created anyway to prevent downstream errors)"
		fi
		"$@"
		return $?
	fi

	if [ "${DRY_RUN:-0}" -eq 1 ]; then
		echo -e "${YELLOW}[DRY-RUN]${NC} $*"
		return 0
	fi

	# Retry apt-get when dpkg lock is held by unattended-upgrades
	if [[ "$1" == "apt-get" ]]; then
		local wait_s="${APT_LOCK_WAIT_S:-300}"
		local interval_s="${APT_LOCK_POLL_S:-3}"
		local start_ts
		start_ts=$(date +%s)
		# Declare locals outside loop for Bash 4.3 compatibility
		local tmp rc elapsed

		while true; do
			tmp=$(mktemp /tmp/apt-get.stderr.XXXXXX)

			"$@" 2>"$tmp"
			rc=$?
			if [ $rc -eq 0 ]; then
				rm -f "$tmp"
				return 0
			fi

			# Preserve original apt-get stderr
			cat "$tmp" >&2

			if [ $rc -eq 100 ] && grep -qE "Could not get lock (/var/lib/dpkg/lock-frontend|/var/lib/dpkg/lock)|dpkg frontend lock|Unable to acquire the dpkg frontend lock" "$tmp"; then
				rm -f "$tmp"
				elapsed=$(($(date +%s) - start_ts))

				if [ "$elapsed" -ge "$wait_s" ]; then
					log_error "apt-get blocked by dpkg lock for over ${wait_s}s, please retry later"
					return $rc
				fi

				log_warn "apt-get blocked by dpkg lock, waiting... (${elapsed}/${wait_s}s)"
				sleep "$interval_s"
				continue
			fi

			rm -f "$tmp"
			return $rc
		done
	fi

	"$@"
}

_sed_escape_replacement() {
	# Escape sed replacement meta-characters: & / \ |
	printf '%s' "$1" | sed -e 's/[&\/|]/\\&/g'
}

_safe_source_deployment_config() {
	local cfg="$1"
	[ -f "$cfg" ] || { log_error "Config file not found: $cfg"; return 1; }
	# Reject backticks, $(), ${} and other shell expansion patterns
	if grep -qvE '^[A-Za-z_][A-Za-z0-9_]*="[^`$]*"|^[A-Za-z_][A-Za-z0-9_]*=[0-9]+$|^[[:space:]]*$|^#' "$cfg"; then
		log_error "Config file contains forbidden shell metacharacters: $cfg"
		return 1
	fi
	# shellcheck source=/dev/null
	source "$cfg"
}

_atomic_write() {
	local target="$1"
	local content
	if [ $# -gt 1 ]; then
		content="$2"
	else
		content=$(cat)
	fi
	
	local target_dir
	target_dir="$(dirname "$target")"
	
	# Verify target filesystem has at least 1MB free space
	if ! df -P "$target_dir" >/dev/null 2>&1 || [ "$(df -P "$target_dir" | awk 'NR==2 {print $4}')" -lt 1024 ]; then
		log_error "Disk full or inaccessible at $target_dir, aborting atomic write"
		return 1
	fi

	local tmp
	tmp=$(mktemp "$target_dir/$(basename "$target").tmp.XXXXXX") || {
		log_error "Failed to create temp file in $target_dir (permission or config issue)"
		return 1
	}
	
	# Inherit permissions from existing target file
	if [ -f "$target" ]; then
		chmod --reference="$target" "$tmp" 2>/dev/null || true
	fi
	
	# Write content without trailing newline (preserves JSON formatting)
	if printf '%s' "$content" > "$tmp"; then
		# Flush data to disk before atomic rename
		sync "$tmp" 2>/dev/null || sync
		if ! mv "$tmp" "$target"; then
			rm -f "$tmp"
			log_error "Atomic rename failed: $target"
			return 1
		fi
		return 0
	else
		rm -f "$tmp"
		log_error "Failed to write temp file: $tmp"
		return 1
	fi
}

# ============================================================================
# Maintenance and recovery
# ============================================================================
validate_sing_box_config() {
	local config="$1"
	local sb_bin="${SING_BOX_BIN:-/usr/bin/sing-box}"
	log_info "Validating config: $config"

	if [ ! -f "$config" ]; then
		log_error "File not found: $config"
		return 1
	fi

	if ! jq empty "$config" >/dev/null 2>&1; then
		log_error "JSON syntax error"
		return 1
	fi

	local check_log
	check_log=$(mktemp /tmp/singbox_check.XXXXXX)
	# shellcheck disable=SC2024
	if ! sudo -u sing-box "$sb_bin" check -c "$config" >"$check_log" 2>&1; then
		log_error "sing-box semantic check failed:"
		cat "$check_log" >&2
		rm -f "$check_log"
		return 1
	fi
	rm -f "$check_log"

	return 0
}

create_rollback_point() {
	local config_dir="${1:-/usr/local/etc/sing-box}"
	local rollback_tar="$config_dir/rollback_point.tar.gz"
	
	log_info "Creating config rollback point..."
	# Collect existing config files
	local files_to_back=()
	for f in config.json providers.json config_template.json; do
		[ -f "$config_dir/$f" ] && files_to_back+=("$f")
	done

	if [ ${#files_to_back[@]} -gt 0 ]; then
		tar -czf "$rollback_tar" -C "$config_dir" "${files_to_back[@]}"
		sha256sum "$rollback_tar" > "${rollback_tar}.sha256"
		log_info "  OK rollback snapshot saved: $rollback_tar (${files_to_back[*]})"
	else
		log_warn "  No config files found, skipping rollback point"
	fi
}

# Set backward-compatible defaults for upgrade mode (intentionally global)
_ensure_compat_defaults() {
	ENABLE_DASHBOARD=${ENABLE_DASHBOARD:-1}
	DASHBOARD_PORT=${DASHBOARD_PORT:-9090}
	DASHBOARD_SECRET=${DASHBOARD_SECRET:-sing-box}
	IS_DESKTOP=${IS_DESKTOP:-0}
	HAS_IPV6=${HAS_IPV6:-0}
	DEFAULT_REGION=${DEFAULT_REGION:-auto}
	PHYSICAL_MTU=${PHYSICAL_MTU:-1500}
	RECOMMENDED_TUN_MTU=${RECOMMENDED_TUN_MTU:-1400}
	LAN_SUBNET=${LAN_SUBNET:-192.168.0.0/16}
}

# ============================================================================
# GitHub release asset download
# ============================================================================
# download_release_asset <asset_name> <dest_path>
download_release_asset() {
	local asset_name="$1"
	local dest="$2"
	local owner="${GITHUB_OWNER:-coloradomartnz}"
	local repo="${GITHUB_REPO:-Sing-box-Stealth-Deploy}"
	local tag

	# Detect current release tag from git (exact match only, then nearest tag)
	if [ -d "$PROJECT_DIR/.git" ]; then
		tag=$(git -C "$PROJECT_DIR" describe --tags --exact-match 2>/dev/null || \
		      git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null || true)
	fi

	# Skip non-release tags (e.g. commit hashes from --always)
	if [[ "$tag" =~ ^v[0-9] ]]; then
		local direct_url="https://github.com/${owner}/${repo}/releases/download/${tag}/${asset_name}"
		log_info "  GitHub tag ($tag) detected, attempting direct download..."
		if curl -fsSL --connect-timeout "${CONNECT_TIMEOUT:-5}" -m "${MAX_TIME:-60}" --retry 3 -o "$dest" "$direct_url"; then
			return 0
		fi
		log_warn "  Direct download failed, falling back to GitHub API..."
	fi

	# Fall back to GitHub API for latest release asset URL
	local api_url="https://api.github.com/repos/${owner}/${repo}/releases/latest"
	local download_url
	
	# Require jq for API response parsing
	if ! command -v jq &>/dev/null; then
		log_warn "  jq not found, cannot parse GitHub API response"
		return 1
	fi

	download_url=$(curl -sf \
		--connect-timeout "${CONNECT_TIMEOUT:-5}" \
		-m "${MAX_TIME:-15}" \
		"$api_url" | jq -r ".assets[] | select(.name == \"$asset_name\") | .browser_download_url" 2>/dev/null)

	if [ -n "$download_url" ] && [ "$download_url" != "null" ]; then
		if curl -fsSL --connect-timeout "${CONNECT_TIMEOUT:-5}" -m "${MAX_TIME:-60}" --retry 3 -o "$dest" "$download_url"; then
			return 0
		fi
	fi

	return 1
}
