#!/usr/bin/env bash
# Shared helpers for the TestFlight ship scripts (build-ipa.sh, testflight.sh,
# testflight-submit.sh). Adapted from the golf-app monorepo's mobile-testflight
# pattern — same robust env-reading + logged-run conventions, but this project
# is native Swift built by xcodebuild (no Expo/EAS), so the mechanics differ.
#
# Source it:  . "$(dirname "$0")/ship-lib.sh"
# Then call:  load_ship_env ; require_tools ; run_logged <log> <cmd…>

# ── env reading ──────────────────────────────────────────────────────────────
# Read one KEY=value out of an env file WITHOUT `set -a` sourcing (which trips on
# comments / quoting). Strips surrounding single or double quotes. (golf-app pattern.)
read_env() {
	local file="$1" key="$2" line val
	[ -f "$file" ] || return 0
	line="$(grep -E "^${key}=" "$file" | head -1 || true)"
	val="${line#*=}"
	val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
	printf '%s' "$val"
}

# Load ASC + Apple-team credentials from .env.testflight (repo root) into the env,
# unless already set in the shell (shell wins, so CI can inject secrets directly).
# Required keys (see .env.testflight.example):
#   APPLE_TEAM_ID          10-char team id (e.g. ABCDE12345)
#   ASC_API_KEY_ID         App Store Connect API key id
#   ASC_API_ISSUER_ID      ASC API issuer id (UUID)
#   ASC_API_KEY_PATH       path to the .p8 private key (absolute or repo-relative)
load_ship_env() {
	local root="$1" envf="$1/.env.testflight" k
	for k in APPLE_TEAM_ID ASC_API_KEY_ID ASC_API_ISSUER_ID ASC_API_KEY_PATH; do
		if [ -z "${!k:-}" ]; then
			local v; v="$(read_env "$envf" "$k")"
			[ -n "$v" ] && export "$k=$v"
		fi
	done
	# Resolve a repo-relative key path to absolute.
	if [ -n "${ASC_API_KEY_PATH:-}" ] && [ "${ASC_API_KEY_PATH#/}" = "$ASC_API_KEY_PATH" ]; then
		export ASC_API_KEY_PATH="$root/$ASC_API_KEY_PATH"
	fi
}

# Fail early with a clear message if a required credential is missing.
require_ship_env() {
	local missing=0 k
	for k in APPLE_TEAM_ID ASC_API_KEY_ID ASC_API_ISSUER_ID ASC_API_KEY_PATH; do
		if [ -z "${!k:-}" ]; then echo "✖ $k is not set (put it in .env.testflight — see .env.testflight.example)" >&2; missing=1; fi
	done
	if [ -n "${ASC_API_KEY_PATH:-}" ] && [ ! -f "$ASC_API_KEY_PATH" ]; then
		echo "✖ ASC_API_KEY_PATH points at a missing file: $ASC_API_KEY_PATH" >&2; missing=1
	fi
	[ "$missing" = 0 ] || exit 1
}

require_tools() {
	local t missing=0
	for t in "$@"; do
		command -v "$t" >/dev/null 2>&1 || { echo "✖ required tool not found: $t" >&2; missing=1; }
	done
	[ "$missing" = 0 ] || exit 1
}

# ── logged run ───────────────────────────────────────────────────────────────
# Run a command attached to the TTY (so xcodebuild/altool progress renders) while
# capturing all output to a log for failure diagnosis. Falls back to a plain pipe
# in CI / headless. (golf-app run_logged pattern.)
run_logged() {
	local log="$1"; shift
	if [ -t 1 ] && command -v script >/dev/null 2>&1; then
		if [ "$(uname)" = "Darwin" ]; then
			script -q "$log" "$@"
		else
			local cmd; printf -v cmd '%q ' "$@"
			script -qec "$cmd" "$log"
		fi
	else
		"$@" 2>&1 | tee "$log"
		return "${PIPESTATUS[0]}"
	fi
}

# ── build-number bump ────────────────────────────────────────────────────────
# Bump CURRENT_PROJECT_VERSION (the build number) for BOTH targets in project.yml,
# so each upload is a fresh, monotonically-increasing build (TestFlight rejects a
# reused build number). Marketing version (MARKETING_VERSION) is left to humans.
bump_build_number() {
	local project_yml="$1"
	[ -f "$project_yml" ] || { echo "✖ project.yml not found at $project_yml" >&2; return 1; }
	local cur next
	cur="$(grep -E 'CURRENT_PROJECT_VERSION:' "$project_yml" | head -1 | sed -E 's/.*CURRENT_PROJECT_VERSION:[[:space:]]*"?([0-9]+)"?.*/\1/')"
	[ -n "$cur" ] || { echo "✖ could not read CURRENT_PROJECT_VERSION from $project_yml" >&2; return 1; }
	next=$((cur + 1))
	# Update every occurrence (both targets + any CFBundleVersion mirror).
	/usr/bin/sed -i '' -E "s/(CURRENT_PROJECT_VERSION:[[:space:]]*\")[0-9]+(\")/\1${next}\2/g; s/(CFBundleVersion:[[:space:]]*\")[0-9]+(\")/\1${next}\2/g" "$project_yml"
	echo "$next"
}
