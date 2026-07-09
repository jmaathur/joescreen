#!/usr/bin/env bash
# One command to ship BOTH JoeScreen apps to their (different) distribution channels:
#   • iOS   → TestFlight (App Store Connect)
#   • macOS → notarized Developer-ID .dmg for direct download
#
# Why not both to TestFlight: the macOS app is non-sandboxed (input injection needs
# kTCCServicePostEvent, D6) and Apple's App Store pipeline REQUIRES the sandbox — so macOS can't use
# TestFlight. Developer-ID notarization is the correct channel for it (keeps all features).
#
#   bun run release              # ship both (iOS TestFlight + macOS dmg)
#   bun run release ios          # iOS only
#   bun run release mac          # macOS only
#   bun run release --no-review  # ship iOS build but don't submit for external Beta App Review
#
# macOS runs FIRST because it needs your login-keychain password (an interactive codesign dialog —
# click "Always Allow" once). iOS is headless (ASC API key).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/ship-lib.sh"

WHICH="both"
DO_REVIEW=1
for a in "$@"; do
	case "$a" in
		ios|mac|both) WHICH="$a" ;;
		--no-review) DO_REVIEW=0 ;;
		*) echo "usage: bun run release [ios|mac|both] [--no-review]" >&2; exit 1 ;;
	esac
done

require_tools bun xcodebuild xcodegen xcrun
load_ship_env "$ROOT"
require_ship_env

mac_ok="skipped"
ios_ok="skipped"
DMG=""

echo "════════════════════════════════════════════════════════════════"
echo " JoeScreen release — ${WHICH}"
echo "════════════════════════════════════════════════════════════════"

# ── macOS first (interactive keychain password) ──────────────────────────────
if [ "$WHICH" = "both" ] || [ "$WHICH" = "mac" ]; then
	echo ""
	echo "▶▶ macOS: notarized Developer-ID .dmg"
	echo "   (codesign will ask for your login-keychain password — click Always Allow)"
	if bash "$ROOT/scripts/notarize-mac.sh"; then
		DMG="$ROOT/apps/joescreen/build/dist-mac/JoeScreen.dmg"
		mac_ok="✓ $DMG"
	else
		mac_ok="✖ FAILED (see log above)"
	fi
fi

# ── iOS (headless via ASC API key) ───────────────────────────────────────────
if [ "$WHICH" = "both" ] || [ "$WHICH" = "ios" ]; then
	echo ""
	echo "▶▶ iOS: TestFlight"
	if SKIP_APP_RECORD=1 bash "$ROOT/scripts/testflight.sh" ios; then
		if [ "$DO_REVIEW" = "1" ]; then
			echo "── submitting iOS build for tester groups + external review"
			# review script reads creds from env; load them for the sub-shell.
			( set -a; . "$ROOT/.env.testflight"; set +a; bun "$ROOT/scripts/asc-testflight-review.mjs" ios ) || true
		fi
		ios_ok="✓ uploaded to TestFlight"
	else
		ios_ok="✖ FAILED (see log above)"
	fi
fi

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo " Release summary"
echo "   iOS   (TestFlight): $ios_ok"
echo "   macOS (.dmg)      : $mac_ok"
if [ -n "$DMG" ] && [ -f "$DMG" ]; then
	echo ""
	echo " Distribute the macOS app: $DMG"
	echo " iOS: App Store Connect → TestFlight (build appears after ~5-15 min processing)."
fi
echo ""
echo " Remember to commit the bumped build number in apps/joescreen/Apps/project.yml."
echo "════════════════════════════════════════════════════════════════"

# Non-zero exit if a requested target failed, so CI/callers notice.
case "$ios_ok$mac_ok" in *"✖"*) exit 1 ;; esac
