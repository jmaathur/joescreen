#!/usr/bin/env bash
# Expose a LOCAL dev stack (SFU + token server) to a Release/TestFlight build over ONE ngrok tunnel,
# so the app — which fetches a token over HTTP then WebSockets to the SFU — can actually connect.
#
#   bun run tunnel:testflight
#
# It starts, in order: livekit-server --dev (SFU) → ngrok (to get the public URL) → the Go token
# server (told to hand that ngrok URL back as the SFU url) → the tunnel-proxy (routes /token to the
# token server, everything else to the SFU). Then it prints the URL to paste into the app.
#
# Ephemeral + local-machine-bound: the ngrok URL rotates on restart, and media rides ICE-TCP off this
# Mac's routable IPs. Good for a quick TestFlight smoke test — NOT a real deployment (for that, deploy
# apps/livekit's docker-compose stack with a domain + TLS).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SFU_PORT=7880
TOKEN_PORT=8080
PROXY_PORT=9090

command -v livekit-server >/dev/null || { echo "✖ livekit-server not found (brew install livekit)"; exit 127; }
command -v ngrok >/dev/null || { echo "✖ ngrok not found (brew install ngrok)"; exit 127; }
command -v go >/dev/null || { echo "✖ go not found"; exit 127; }

pids=()
cleanup() { echo ""; echo "▶ stopping tunnel stack"; for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT INT TERM

# 1. SFU (dev mode).
if lsof -iTCP:$SFU_PORT -sTCP:LISTEN >/dev/null 2>&1; then
	echo "✓ SFU already on :$SFU_PORT"
else
	echo "▶ starting livekit-server --dev"
	livekit-server --dev >/tmp/joescreen-sfu.log 2>&1 & pids+=($!)
	for _ in $(seq 1 20); do lsof -iTCP:$SFU_PORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.5; done
fi

# 2. ngrok → the PROXY port (started below). Start ngrok first to learn the URL.
echo "▶ starting ngrok → :$PROXY_PORT"
pkill -f "ngrok http" 2>/dev/null || true; sleep 1
ngrok http $PROXY_PORT --log=stdout >/tmp/joescreen-ngrok.log 2>&1 & pids+=($!)
# Poll ngrok's local API for the public URL.
NGROK_URL=""
for _ in $(seq 1 30); do
	NGROK_URL="$(curl -s http://127.0.0.1:4040/api/tunnels 2>/dev/null \
		| /usr/bin/python3 -c "import json,sys;d=json.load(sys.stdin);t=d.get('tunnels',[]);print(t[0]['public_url'] if t else '')" 2>/dev/null || true)"
	[ -n "$NGROK_URL" ] && break
	sleep 0.5
done
[ -n "$NGROK_URL" ] || { echo "✖ ngrok didn't come up"; exit 1; }
NGROK_HOST="${NGROK_URL#https://}"
WSS_URL="wss://$NGROK_HOST"
echo "✓ ngrok: $NGROK_URL"

# 3. Token server — return the ngrok wss URL as the SFU url (so signaling comes back through the proxy).
echo "▶ starting token server (:$TOKEN_PORT), returning SFU url $WSS_URL"
( cd "$ROOT/apps/livekit/token-server" && go build -o /tmp/joescreen-token . )
LIVEKIT_API_KEY=devkey LIVEKIT_API_SECRET=secret LIVEKIT_URL="$WSS_URL" \
	/tmp/joescreen-token >/tmp/joescreen-token.log 2>&1 & pids+=($!)
sleep 1

# 4. Proxy: /token → token server, everything else (incl. /rtc ws) → SFU.
echo "▶ starting tunnel-proxy (:$PROXY_PORT)"
PROXY_PORT=$PROXY_PORT TOKEN_PORT=$TOKEN_PORT SFU_PORT=$SFU_PORT \
	bun "$ROOT/scripts/tunnel-proxy.mjs" >/tmp/joescreen-proxy.log 2>&1 & pids+=($!)
sleep 2

# Smoke-test the whole chain through the public URL.
echo "▶ smoke-testing $NGROK_URL/token"
if curl -s --max-time 8 "$NGROK_URL/token?room=demo&identity=$(uuidgen)" | grep -q '"token"'; then
	echo "✓ /token works through the tunnel"
else
	echo "⚠ /token smoke test didn't return a token — check /tmp/joescreen-*.log"
fi

cat <<EOF

════════════════════════════════════════════════════════════════
 TestFlight tunnel is UP. In the JoeScreen app, use this server URL:

     $NGROK_URL

 (room "demo", any identity). The app fetches a token from it, then
 connects to the SFU through the same host.

 • This URL is EPHEMERAL — it changes every time you re-run this.
 • Media rides ICE-TCP off this Mac; keep this Mac + terminal running.
 • Ctrl-C stops the whole stack.
════════════════════════════════════════════════════════════════
EOF

# Hold until interrupted.
wait
