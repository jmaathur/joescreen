#!/usr/bin/env bash
# Build AND ship a JoeScreen TestFlight build in one shot: bump the build number,
# archive + export an App Store package, then upload it. Mirrors golf-app's
# mobile-testflight.sh (build → submit), on the native xcodebuild + altool path.
#
#   bun run testflight <ios|mac>
#
# Prerequisites (see docs/SHIPPING_TESTFLIGHT.md): a real Apple Team ID, App Store
# distribution signing set up, and .env.testflight populated with the ASC API key.
set -euo pipefail

PLATFORM="${1:-}"
if [ "$PLATFORM" != "ios" ] && [ "$PLATFORM" != "mac" ]; then
	echo "usage: bun run testflight <ios|mac>" >&2
	exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/ship-lib.sh"

PROJECT_YML="$ROOT/apps/joescreen/Apps/project.yml"

echo "── bumping build number"
NEW_BUILD="$(bump_build_number "$PROJECT_YML")"
echo "   build number → $NEW_BUILD"

echo "── build + export"
bash "$ROOT/scripts/build-ipa.sh" "$PLATFORM"

echo "── upload"
bash "$ROOT/scripts/testflight-submit.sh" "$PLATFORM"

echo ""
echo "✓ TestFlight build $NEW_BUILD shipped for $PLATFORM."
echo "  Commit the bumped build number in $PROJECT_YML so it isn't reused."
