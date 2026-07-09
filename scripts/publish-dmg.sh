#!/usr/bin/env bash
# Upload the notarized macOS .dmg to the R2 bucket the download worker serves from.
#
#   bun run publish:dmg            # uploads apps/joescreen/build/dist-mac/JoeScreen.dmg
#   bun run publish:dmg <path>     # upload a specific dmg
#
# Needs Cloudflare auth (wrangler login, or CLOUDFLARE_API_TOKEN/CLOUDFLARE_ACCOUNT_ID in env).
# The bucket + object key must match apps/joescreen-download/wrangler.jsonc (joescreen-downloads / JoeScreen.dmg).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUCKET="joescreen-downloads"
KEY="JoeScreen.dmg"

DMG="${1:-$ROOT/apps/joescreen/build/dist-mac/JoeScreen.dmg}"
if [ ! -f "$DMG" ]; then
	echo "✖ dmg not found at $DMG — build it first: bun run dist:mac" >&2
	exit 1
fi

command -v bunx >/dev/null || { echo "✖ bun/bunx required" >&2; exit 1; }

echo "── uploading $DMG → r2://$BUCKET/$KEY"
# --remote uploads to the real bucket (not the local Miniflare sim). Content type = Apple disk image.
bunx wrangler r2 object put "$BUCKET/$KEY" \
	--file "$DMG" \
	--content-type "application/x-apple-diskimage" \
	--remote

echo "✓ published. The download worker now serves this at /download."
echo "  Verify (after deploy): curl -I https://<your-worker-url>/download"
