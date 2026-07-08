#!/usr/bin/env bash
# Archive + export an App Store distribution build of JoeScreen (iOS .ipa or
# macOS .pkg), ready to upload to TestFlight. Native xcodebuild path — this
# project is Swift, not Expo/EAS, so this replaces golf-app's `eas build`.
#
#   bun run build:ipa <ios|mac>
#
# Reads signing config from .env.testflight (APPLE_TEAM_ID + ASC key) and uses
# the matching ExportOptions plist. Requires a real Team ID + App Store
# distribution signing assets registered with Apple (see docs/SHIPPING_TESTFLIGHT.md).
set -euo pipefail

PLATFORM="${1:-}"
if [ "$PLATFORM" != "ios" ] && [ "$PLATFORM" != "mac" ]; then
	echo "usage: bun run build:ipa <ios|mac>" >&2
	exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/ship-lib.sh"
require_tools xcodebuild xcodegen
load_ship_env "$ROOT"
require_ship_env

APP_DIR="$ROOT/apps/joescreen"
PROJECT="$APP_DIR/Apps/JoeScreen.xcodeproj"
BUILD_DIR="$APP_DIR/build"
LOG_DIR="$BUILD_DIR/logs"
mkdir -p "$LOG_DIR"

if [ "$PLATFORM" = "ios" ]; then
	SCHEME="JoeScreen-iOS"
	EXPORT_OPTS="$ROOT/ExportOptions-appstore-ios.plist"
	ARCHIVE="$BUILD_DIR/JoeScreen-iOS.xcarchive"
	EXPORT_PATH="$BUILD_DIR/export-ios"
	SDK_ARGS=(-destination "generic/platform=iOS")
else
	SCHEME="JoeScreen-macOS"
	EXPORT_OPTS="$ROOT/ExportOptions-appstore-macos.plist"
	ARCHIVE="$BUILD_DIR/JoeScreen-macOS.xcarchive"
	EXPORT_PATH="$BUILD_DIR/export-mac"
	SDK_ARGS=(-destination "generic/platform=macOS")
fi

[ -f "$EXPORT_OPTS" ] || { echo "✖ missing $EXPORT_OPTS" >&2; exit 1; }

# Render the ExportOptions with the real Team ID (the committed plist has a __TEAM_ID__
# placeholder so no team id is ever committed).
RENDERED_OPTS="$BUILD_DIR/ExportOptions-$PLATFORM.plist"
/usr/bin/sed "s/__TEAM_ID__/$APPLE_TEAM_ID/g" "$EXPORT_OPTS" > "$RENDERED_OPTS"
EXPORT_OPTS="$RENDERED_OPTS"

# iOS entitlements selection. Default = minimal (no SharePlay / App Group), so automatic signing
# succeeds BEFORE the group-session managed capability is approved — the first viewer+voice build
# ships now. After SharePlay is approved for the App ID, pass SHIP_ENTITLEMENTS=full to re-enable it.
ENTITLEMENTS_OVERRIDE=()
if [ "$PLATFORM" = "ios" ]; then
	case "${SHIP_ENTITLEMENTS:-minimal}" in
		full)    IOS_ENT="iOS/Resources/JoeScreen-iOS.entitlements"; echo "── iOS entitlements: FULL (SharePlay + App Group — needs group-session approved)";;
		minimal) IOS_ENT="iOS/Resources/JoeScreen-iOS-minimal.entitlements"; echo "── iOS entitlements: MINIMAL (viewer+voice; no SharePlay yet)";;
		*) echo "✖ SHIP_ENTITLEMENTS must be 'minimal' or 'full'" >&2; exit 1;;
	esac
	ENTITLEMENTS_OVERRIDE=(CODE_SIGN_ENTITLEMENTS="$IOS_ENT")
fi

echo "── regenerating Xcode project (TEAM_ID=$APPLE_TEAM_ID)"
( cd "$APP_DIR" && TEAM_ID="$APPLE_TEAM_ID" xcodegen generate --spec Apps/project.yml >/dev/null )

echo "── archiving $SCHEME (Release, App Store distribution signing)"
run_logged "$LOG_DIR/archive-$PLATFORM.log" \
	xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
		"${SDK_ARGS[@]}" -archivePath "$ARCHIVE" \
		-allowProvisioningUpdates \
		-authenticationKeyID "$ASC_API_KEY_ID" \
		-authenticationKeyIssuerID "$ASC_API_ISSUER_ID" \
		-authenticationKeyPath "$ASC_API_KEY_PATH" \
		DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
		CODE_SIGN_STYLE=Automatic CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
		"CODE_SIGN_IDENTITY=Apple Distribution" \
		"${ENTITLEMENTS_OVERRIDE[@]}" \
		archive

echo "── exporting App Store package"
run_logged "$LOG_DIR/export-$PLATFORM.log" \
	xcodebuild -exportArchive -archivePath "$ARCHIVE" \
		-exportOptionsPlist "$EXPORT_OPTS" -exportPath "$EXPORT_PATH" \
		-allowProvisioningUpdates \
		-authenticationKeyID "$ASC_API_KEY_ID" \
		-authenticationKeyIssuerID "$ASC_API_ISSUER_ID" \
		-authenticationKeyPath "$ASC_API_KEY_PATH"

ARTIFACT="$(find "$EXPORT_PATH" -maxdepth 1 \( -name '*.ipa' -o -name '*.pkg' \) | head -1)"
if [ -z "$ARTIFACT" ]; then
	echo "✖ export produced no .ipa/.pkg in $EXPORT_PATH" >&2
	exit 1
fi
echo "✓ built: $ARTIFACT"
printf '%s\n' "$ARTIFACT" > "$BUILD_DIR/last-artifact-$PLATFORM.txt"
