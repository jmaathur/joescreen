# Deployed SFU — sfu.cheffing.dev

The production LiveKit SFU is **live** (deployed 2026-07-11).

## Host
- **DigitalOcean droplet** `joescreen-sfu` — `s-2vcpu-2gb`, region `nyc3`, Ubuntu 24.04.
- Public IP: **167.172.224.54** · SSH: `ssh root@167.172.224.54` (jeevans-macbook-pro key).
- DNS: `sfu.cheffing.dev` → 167.172.224.54 (Cloudflare A record, **DNS-only / not proxied** — the
  proxy would break WebRTC media + TLS).

## Stack (on the box at `/opt/joescreen-sfu/`)
- **livekit** — `livekit/livekit-server:v1.13.3`, `network_mode: host` (needs the raw UDP media
  range). Config `livekit.yaml`: port 7880, RTC UDP 50000–50100, ICE-TCP 7881, `use_external_ip`.
  API key/secret injected via `LIVEKIT_KEYS` env (NOT in the repo — see below).
- **caddy** — `caddy:2`, host networking, terminates TLS for `wss://sfu.cheffing.dev` and reverse-
  proxies to `127.0.0.1:7880`. Auto-provisions + renews a Let's Encrypt cert.
- Firewall (ufw): 22, 80, 443/tcp, 7880, 7881/tcp, 50000–50100/udp.

## URLs
- App dials: **`wss://sfu.cheffing.dev`**
- RoomService (presence, admin): **`https://sfu.cheffing.dev`**
- TURN-over-TLS on :443 is currently **disabled** (`turn.enabled: false`). Direct UDP + ICE-TCP
  fallback works for most networks; enable TURN later for strict corporate firewalls (needs a cert
  wired into livekit.yaml's `turn.cert_file`).

## The API key/secret (NOT committed — R3)
Generated on the box with `docker run --rm livekit/livekit-server:v1.13.3 generate-keys`.
- Key: `APIW2M8d5dhpHam` (the key id is fine to know; the SECRET lives only on the SFU + wherever
  tokens are minted).
- **Where the secret must go** (server-side only, never in the app binary):
  - The SFU box (already set, in the container env).
  - The rooms Cloudflare worker secrets (already set: `wrangler secret put LIVEKIT_API_KEY/SECRET
    --env production`) — for presence + browser view-only tokens.
  - **The app-token server** (`apps/livekit/token-server`) when you deploy it, so Release builds of
    the Mac/iOS app can fetch a join token. (Until then, DEBUG builds mint dev tokens locally.)

## Operating
```sh
ssh root@167.172.224.54
cd /opt/joescreen-sfu
docker compose ps                 # status
docker compose logs -f livekit    # media-plane logs
docker compose pull && docker compose up -d   # update (pin the version in docker-compose.yml)
```

## Verified at deploy
- Let's Encrypt cert obtained for `sfu.cheffing.dev`; HTTPS 200.
- A token signed with the generated key/secret validates against `https://sfu.cheffing.dev/rtc/validate`
  → HTTP 200 `success` (full media-plane auth path works end to end).
