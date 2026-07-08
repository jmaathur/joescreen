#!/usr/bin/env bash
# One command to take JoeScreen from "creds in .env.testflight" to "uploaded to TestFlight".
# Automates everything Apple exposes an API for; prints the one manual gate (SharePlay approval).
#
#   bun run ship:setup             # provision (portal + ASC records) then build + upload iOS
#   bun run ship:setup --dry-run   # show what provisioning WOULD do, no writes, no build
#   bun run ship:setup mac         # target macOS instead of iOS for the build+upload
#
# Steps:
#   1. Preflight credentials (.env.testflight) and required tools.
#   2. Provision via ASC API: bundle IDs, App Group, APP_GROUPS capability, app records (idempotent).
#   3. Build + upload the TestFlight build (delegates to scripts/testflight.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/ship-lib.sh"

DRY=""
PLATFORM="ios"
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY="--dry-run" ;;
		ios|mac) PLATFORM="$arg" ;;
		*) echo "usage: bun run ship:setup [ios|mac] [--dry-run]" >&2; exit 1 ;;
	esac
done

echo "════════════════════════════════════════════════════════════════"
echo " JoeScreen → TestFlight setup${DRY:+  (DRY RUN)}"
echo "════════════════════════════════════════════════════════════════"

# 1. Preflight.
echo ""
echo "── Step 1/3: preflight credentials + tools"
require_tools bun xcodebuild xcodegen xcrun
load_ship_env "$ROOT"
require_ship_env
log_ok() { echo "   ✓ $1"; }
log_ok "APPLE_TEAM_ID = $APPLE_TEAM_ID"
log_ok "ASC API key   = $ASC_API_KEY_ID (issuer ${ASC_API_ISSUER_ID:0:8}…)"
log_ok ".p8 key       = $ASC_API_KEY_PATH"

# 2. Provision bundle IDs (idempotent; ASC API key).
echo ""
echo "── Step 2/4: provision bundle IDs"
bun "$ROOT/scripts/asc-provision.mjs" $DRY

# 3. Ensure the App Store Connect app record exists. This is the ONE step the ASC API key can't do
#    (Apple blocks POST /v1/apps); fastlane produce needs your Apple ID + 2FA. Skippable if you've
#    already created it (set SKIP_APP_RECORD=1), or on dry-run.
if [ -z "$DRY" ] && [ -z "${SKIP_APP_RECORD:-}" ]; then
	echo ""
	echo "── Step 3/4: ensure App Store Connect app record"
	# Check via the API whether the record already exists; only invoke fastlane (which needs your
	# Apple ID login) if it's missing — so re-runs don't prompt once the record is there.
	APP_BUNDLE=$([ "$PLATFORM" = "mac" ] && echo "com.joescreen.app" || echo "com.joescreen.app.ios")
	if bun "$ROOT/scripts/asc-app-exists.mjs" "$APP_BUNDLE" >/dev/null 2>&1; then
		echo "   ✓ app record already exists for $APP_BUNDLE"
	else
		echo "   app record missing → creating via fastlane produce (needs your Apple ID + 2FA once)"
		bash "$ROOT/scripts/asc-create-app.sh" "$PLATFORM"
	fi
fi

# 4. Build + upload (skipped on dry-run).
if [ -n "$DRY" ]; then
	echo ""
	echo "── Step 4/4: build + upload  [SKIPPED on --dry-run]"
	echo ""
	echo "Dry run complete. Re-run without --dry-run to provision for real and ship:"
	echo "   bun run ship:setup $PLATFORM"
	exit 0
fi

echo ""
echo "── Step 4/4: build + upload ($PLATFORM) to TestFlight"
bash "$ROOT/scripts/testflight.sh" "$PLATFORM"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo " Done. Next:"
echo "  • App Store Connect → your app → TestFlight: the build appears after processing (~5-15 min)."
echo "  • Add internal testers (instant) or submit external testers for Beta App Review (~1 day)."
echo "  • Deploy the LiveKit SFU (apps/livekit) with a public URL — localhost won't reach testers."
echo "  • Commit the bumped build number in apps/joescreen/Apps/project.yml."
echo "════════════════════════════════════════════════════════════════"
