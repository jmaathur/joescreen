#!/usr/bin/env bash
# Build, sign (Developer ID), notarize, staple, and package the macOS app into a .dmg for direct
# distribution — the path JoeScreen's non-sandboxed macOS app was DESIGNED for (D6). Unlike TestFlight
# (which requires the App Sandbox and thus can't take this app), this keeps ALL features incl. input
# injection. Testers download the .dmg, drag to Applications, and open.
#
#   bun run dist:mac
#
# Requires: a "Developer ID Application" cert in the keychain (create once — see docs) and the ASC
# API key in .env.testflight (notarytool authenticates with the same .p8).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/ship-lib.sh"
require_tools xcodebuild xcodegen xcrun hdiutil
load_ship_env "$ROOT"
require_ship_env

APP_DIR="$ROOT/apps/joescreen"
PROJECT="$APP_DIR/Apps/JoeScreen.xcodeproj"
BUILD_DIR="$APP_DIR/build"
DIST_DIR="$BUILD_DIR/dist-mac"
LOG_DIR="$BUILD_DIR/logs"
mkdir -p "$DIST_DIR" "$LOG_DIR"

# Find the Developer ID Application identity.
DEVID="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" | sed -E 's/.*"(Developer ID Application[^"]*)".*/\1/' || true)"
if [ -z "$DEVID" ]; then
	echo "✖ No 'Developer ID Application' certificate in your keychain." >&2
	echo "  Create one (once): Xcode → Settings → Accounts → your team → Manage Certificates → + →" >&2
	echo "  'Developer ID Application'. Then re-run. (Or via the developer portal → Certificates.)" >&2
	exit 1
fi
echo "✓ signing identity: $DEVID"

# Use the minimal App-Store entitlements (NOT the -team file): the SharePlay group-session entitlement
# requires a provisioning profile, which Developer-ID distribution doesn't use (and it's unapproved
# anyway). Input injection needs NO entitlement — it's gated by kTCCServicePostEvent TCC at runtime,
# not by an entitlement — so dropping SharePlay costs nothing for the core feature. Non-sandboxed is
# the point of Developer-ID over App Store (D6).
export SHIP_IOS_ENTITLEMENTS="iOS/Resources/JoeScreen-iOS-minimal.entitlements"
export SHIP_IOS_EXT_ENTITLEMENTS="BroadcastExtension/BroadcastExtension-minimal.entitlements"
export SHIP_MAC_ENTITLEMENTS="macOS/Resources/JoeScreen-macOS-appstore.entitlements"

echo "── regenerating Xcode project (TEAM_ID=$APPLE_TEAM_ID)"
( cd "$APP_DIR" && TEAM_ID="$APPLE_TEAM_ID" xcodegen generate --spec Apps/project.yml >/dev/null )

ARCHIVE="$BUILD_DIR/JoeScreen-macOS-devid.xcarchive"
echo "── archiving (Release, Developer ID, hardened runtime)"
run_logged "$LOG_DIR/archive-devid.log" \
	xcodebuild -project "$PROJECT" -scheme JoeScreen-macOS -configuration Release \
		-destination "generic/platform=macOS" -archivePath "$ARCHIVE" \
		DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
		CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$DEVID" \
		CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
		ENABLE_HARDENED_RUNTIME=YES \
		archive

# Export a Developer-ID-signed .app.
EXPORT_DIR="$BUILD_DIR/export-devid"
rm -rf "$EXPORT_DIR"
cat > "$BUILD_DIR/ExportOptions-devid.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$APPLE_TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
EOF
echo "── exporting Developer-ID .app"
run_logged "$LOG_DIR/export-devid.log" \
	xcodebuild -exportArchive -archivePath "$ARCHIVE" \
		-exportOptionsPlist "$BUILD_DIR/ExportOptions-devid.plist" -exportPath "$EXPORT_DIR" \
		-allowProvisioningUpdates \
		-authenticationKeyID "$ASC_API_KEY_ID" \
		-authenticationKeyIssuerID "$ASC_API_ISSUER_ID" \
		-authenticationKeyPath "$ASC_API_KEY_PATH"

APP="$EXPORT_DIR/JoeScreen.app"
[ -d "$APP" ] || { echo "✖ export produced no JoeScreen.app" >&2; exit 1; }

# Package into a .dmg BEFORE notarizing (notarize the dmg so the ticket staples to the container).
DMG="$DIST_DIR/JoeScreen.dmg"
rm -f "$DMG"
echo "── building .dmg"
STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "JoeScreen" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
echo "✓ dmg: $DMG"

echo "── notarizing (submit + wait; auth via ASC API key)"
run_logged "$LOG_DIR/notarize.log" \
	xcrun notarytool submit "$DMG" \
		--key "$ASC_API_KEY_PATH" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID" \
		--wait

echo "── stapling the notarization ticket to the dmg"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG" && echo "✓ stapled + validated"

cat <<EOF

════════════════════════════════════════════════════════════════
 Notarized macOS build ready:

     $DMG

 Distribute this .dmg directly (email / download link / your site).
 Testers: open the dmg, drag JoeScreen to Applications, launch it.
 Gatekeeper accepts it (Developer-ID signed + notarized + stapled).
════════════════════════════════════════════════════════════════
EOF
