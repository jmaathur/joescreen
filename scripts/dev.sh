#!/usr/bin/env bash
# `bun run dev` — the single command: start the LiveKit dev SFU, then build and launch the JoeScreen
# macOS app joined to it. Keeps the SFU running in the foreground (so its logs stream and Ctrl-C
# stops everything); the app is launched detached (it's a GUI app with its own lifecycle).
#
# Usage:
#   bun run dev              # room "demo"
#   bun run dev my-room      # custom room name
set -euo pipefail

cd "$(dirname "$0")/.."

ROOM="${1:-demo}"
PORT=7880
LK_PID=""

# On exit, stop the SFU if WE started it (don't kill a pre-existing one the user is running).
cleanup() {
	if [ -n "$LK_PID" ] && kill -0 "$LK_PID" 2>/dev/null; then
		echo ""
		echo "▶ stopping LiveKit dev server (pid $LK_PID)"
		kill "$LK_PID" 2>/dev/null || true
	fi
}
trap cleanup EXIT INT TERM

# 1) Start the SFU (reuse an already-running one).
if lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
	echo "✓ LiveKit already listening on :$PORT — reusing it."
else
	if ! command -v livekit-server >/dev/null 2>&1; then
		echo "✗ livekit-server not found. Install it:  brew install livekit" >&2
		exit 127
	fi
	echo "▶ starting livekit-server --dev on ws://localhost:$PORT"
	livekit-server --dev &
	LK_PID=$!
	# Wait (up to ~15s) for the signaling port to accept connections before building the app.
	for _ in $(seq 1 30); do
		lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && break
		sleep 0.5
	done
	if ! lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
		echo "✗ LiveKit did not come up on :$PORT within 15s" >&2
		exit 1
	fi
	echo "✓ LiveKit up on :$PORT"
fi

# 2) Build + launch the app (detached GUI process).
bash scripts/app.sh "$ROOM"

# 3) Hold the terminal so the SFU keeps running and its logs stream. Ctrl-C triggers cleanup.
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " JoeScreen is running against the local LiveKit dev server."
echo " • Open another window in the same room:  bun run app $ROOM"
echo " • Press Ctrl-C to stop the LiveKit server and end the session."
echo "──────────────────────────────────────────────────────────────"
if [ -n "$LK_PID" ]; then
	wait "$LK_PID"
else
	# We reused someone else's SFU; just idle until interrupted so the trap can clean up.
	tail -f /dev/null
fi
