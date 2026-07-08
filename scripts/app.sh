#!/usr/bin/env bash
# Build and launch the JoeScreen macOS app, joined to the local dev SFU.
#
# Regenerates the Xcode project from project.yml (the .xcodeproj is gitignored), builds the
# JoeScreen-macOS scheme, and opens the .app with --join-url pointing at the dev server. Pass a room
# name as $1 (default "demo"); each launch gets a fresh random identity so two runs don't collide.
set -euo pipefail

cd "$(dirname "$0")/../apps/joescreen"

ROOM="${1:-demo}"
JOIN_URL="${JOIN_URL:-ws://localhost:7880}"

echo "▶ regenerating Xcode project"
xcodegen generate --spec Apps/project.yml >/dev/null

echo "▶ building JoeScreen-macOS (this can take a minute on a cold build)"
xcodebuild -project Apps/JoeScreen.xcodeproj -scheme JoeScreen-macOS -derivedDataPath build build \
	-quiet

APP="build/Build/Products/Debug/JoeScreen.app"
if [ ! -d "$APP" ]; then
	echo "✗ build succeeded but $APP is missing" >&2
	exit 1
fi

echo "▶ launching JoeScreen → room=$ROOM url=$JOIN_URL"
open -n "$APP" --args --join-url "$JOIN_URL" --room "$ROOM" --identity "$(uuidgen)"
echo "✓ JoeScreen launched. Re-run 'bun run app' to open another instance (they'll share the room)."
