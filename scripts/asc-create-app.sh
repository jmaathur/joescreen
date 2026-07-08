#!/usr/bin/env bash
# Create the App Store Connect app record programmatically via `fastlane produce`.
#
# WHY fastlane and not our ASC JWT API: Apple blocks raw `POST /v1/apps` (403 "apps does not allow
# CREATE") — confirmed in golf-app's own notes too. The record is created through the legacy portal
# path that fastlane/eas/@expo/apple-utils use. fastlane can authenticate with the App Store Connect
# API KEY (no interactive Apple ID / 2FA) for this.
#
#   bun run asc:create-app ios     # creates the record for com.joescreen.app.ios
#   bun run asc:create-app mac      # com.joescreen.app
set -euo pipefail

PLATFORM="${1:-ios}"
case "$PLATFORM" in
	ios) BUNDLE="com.joescreen.app.ios"; PLATFORMS="ios" ;;
	mac) BUNDLE="com.joescreen.app";     PLATFORMS="osx" ;;
	*) echo "usage: bun run asc:create-app <ios|mac>" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/ship-lib.sh"
require_tools fastlane
load_ship_env "$ROOT"
require_ship_env

APP_NAME="${JOESCREEN_APP_NAME:-JoeScreen}"

# App-record creation is the ONE step the ASC API key can't do (Apple blocks POST /v1/apps; fastlane
# produce needs Apple-ID cookie auth). So we need your Apple ID. Read it from APPLE_ID / FASTLANE_USER
# (env or .env.testflight), else prompt. fastlane handles the password (Keychain) + 2FA interactively.
APPLE_ID="${APPLE_ID:-${FASTLANE_USER:-$(read_env "$ROOT/.env.testflight" APPLE_ID)}}"
if [ -z "$APPLE_ID" ]; then
	printf "Apple ID email (for App Store Connect login): "
	read -r APPLE_ID
fi
if [ -z "$APPLE_ID" ]; then
	echo "✖ an Apple ID is required to create the app record (fastlane produce needs it)." >&2
	exit 1
fi
export FASTLANE_USER="$APPLE_ID"
export FASTLANE_HIDE_CHANGELOG=1 FASTLANE_SKIP_UPDATE_CHECK=1

echo "── creating App Store Connect app record via fastlane produce"
echo "   bundle: $BUNDLE   name: \"$APP_NAME\"   apple id: $APPLE_ID"
echo "   (fastlane will ask for your Apple ID password + 2FA the first time; it's cached after.)"

# --skip_devcenter: the App ID (bundle id) already exists (registered via the ASC API), so only create
# the App Store Connect side. produce is idempotent — no-ops if the record already exists.
fastlane produce create \
	--username "$APPLE_ID" \
	--app_identifier "$BUNDLE" \
	--app_name "$APP_NAME" \
	--platforms "$PLATFORMS" \
	--team_id "$APPLE_TEAM_ID" \
	--skip_devcenter \
	|| {
		echo "" >&2
		echo "✖ fastlane produce failed." >&2
		echo "  • If the app NAME is taken, set a unique one: JOESCREEN_APP_NAME=\"JoeScreen Beta\" bun run asc:create-app $PLATFORM" >&2
		echo "  • If 2FA looped, run 'fastlane spaceauth -u $APPLE_ID' once to cache a session, then retry." >&2
		exit 1
	}

echo "✓ app record ensured for $BUNDLE."
