#!/usr/bin/env bash
# Upload an already-built App Store package (.ipa / .pkg) to TestFlight. Standalone
# submit step — use it to retry an upload when the build already succeeded. Mirrors
# golf-app's mobile-testflight-submit.sh, but uploads via `xcrun altool` with an ASC
# API key (this project has no EAS).
#
#   bun run testflight:submit <ios|mac> [artifact-path]
#
# If no artifact path is given, uses build/last-artifact-<platform>.txt written by
# build-ipa.sh.
set -euo pipefail

PLATFORM="${1:-}"
if [ "$PLATFORM" != "ios" ] && [ "$PLATFORM" != "mac" ]; then
	echo "usage: bun run testflight:submit <ios|mac> [artifact]" >&2
	exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/ship-lib.sh"
require_tools xcrun
load_ship_env "$ROOT"
require_ship_env

BUILD_DIR="$ROOT/apps/joescreen/build"
ARTIFACT="${2:-}"
if [ -z "$ARTIFACT" ] && [ -f "$BUILD_DIR/last-artifact-$PLATFORM.txt" ]; then
	ARTIFACT="$(cat "$BUILD_DIR/last-artifact-$PLATFORM.txt")"
fi
if [ -z "$ARTIFACT" ] || [ ! -f "$ARTIFACT" ]; then
	echo "✖ artifact not found${ARTIFACT:+ at $ARTIFACT}." >&2
	echo "  Build it first:  bun run build:ipa $PLATFORM" >&2
	exit 1
fi

[ "$PLATFORM" = "ios" ] && TYPE="ios" || TYPE="macos"

# altool --apiKey does NOT accept an explicit key path — it only searches a few fixed dirs
# (~/.appstoreconnect/private_keys, ~/private_keys, …) for AuthKey_<KEYID>.p8. Stage our key there
# (named exactly AuthKey_<KEYID>.p8) so altool finds it, regardless of where ASC_API_KEY_PATH points.
STAGE_DIR="$HOME/.appstoreconnect/private_keys"
STAGED_KEY="$STAGE_DIR/AuthKey_${ASC_API_KEY_ID}.p8"
if [ ! -f "$STAGED_KEY" ]; then
	mkdir -p "$STAGE_DIR"
	cp "$ASC_API_KEY_PATH" "$STAGED_KEY"
	chmod 600 "$STAGED_KEY"
	echo "── staged ASC key → $STAGED_KEY (altool looks here)"
fi

echo "── uploading $ARTIFACT to TestFlight ($TYPE)…"
UPLOAD_LOG="$BUILD_DIR/logs/upload-$PLATFORM.log"
mkdir -p "$BUILD_DIR/logs"
# Run altool directly (not via run_logged) so we get its real exit code, and tee to a log.
set +e
xcrun altool --upload-app -f "$ARTIFACT" -t "$TYPE" \
	--apiKey "$ASC_API_KEY_ID" --apiIssuer "$ASC_API_ISSUER_ID" 2>&1 | tee "$UPLOAD_LOG"
RC="${PIPESTATUS[0]}"
set -e

if [ "$RC" -ne 0 ]; then
	echo "" >&2
	echo "✖ upload FAILED (altool exit $RC)." >&2
	if grep -q "Cannot determine the Apple ID from Bundle ID" "$UPLOAD_LOG" 2>/dev/null; then
		echo "  → No App Store Connect app record exists for this bundle id yet." >&2
		echo "    Create it: App Store Connect → Apps → +  → New App" >&2
		echo "      Platform: iOS   Bundle ID: com.joescreen.app.ios   (Name must be globally unique)" >&2
		echo "    Then wait ~1-2 min for it to propagate and re-run: bun run testflight:submit ios" >&2
	fi
	exit "$RC"
fi

echo ""
echo "✓ uploaded. It appears in App Store Connect → TestFlight after processing (a few minutes)."
echo "  First external-tester distribution needs a one-time Beta App Review (~1 day)."
