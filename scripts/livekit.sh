#!/usr/bin/env bash
# Start the LiveKit dev SFU (loopback/LAN, fixed devkey/secret, no TLS) on ws://localhost:7880.
#
# Idempotent: if something is already listening on 7880 we assume a dev SFU is up and exit 0, so
# `bun run dev` can be re-run without spawning duplicates. Runs in the FOREGROUND (so a parent that
# backgrounds it owns its lifecycle); Ctrl-C stops it.
set -euo pipefail

PORT=7880

if lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
	echo "✓ LiveKit already listening on :$PORT — reusing it."
	# Keep the process alive so a supervisor waiting on us doesn't think we exited/failed.
	exec tail -f /dev/null
fi

if ! command -v livekit-server >/dev/null 2>&1; then
	echo "✗ livekit-server not found. Install it:  brew install livekit" >&2
	exit 127
fi

echo "▶ starting livekit-server --dev on ws://localhost:$PORT (devkey/secret, no TLS)"
exec livekit-server --dev
