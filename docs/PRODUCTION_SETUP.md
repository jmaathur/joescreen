# Production Setup — what it takes to make this session's changes fully live

**Audience:** you (the operator). **Scope:** everything the M9–M11 + backlog work needs to actually
run for real users, not just build green. Written 2026-07-10.

TL;DR of the dependency chain: **almost everything real-time depends on ONE thing that doesn't exist
yet — a hosted LiveKit SFU.** Get that up (Option A/B below) and ~80% of the setup falls into place;
the rest is grants, secrets, and a deploy.

---

## The big picture: three planes, three homes

JoeScreen is built as three planes. Each has a different home and a different setup story.

| Plane | What runs it | Status | Gets you |
|---|---|---|---|
| **Media** (audio/video/data) | A LiveKit **SFU** + the Go **token server** | ❌ not hosted | The actual calls. Everything else is moot without this. |
| **App** (macOS/iOS binaries) | Direct-download `.dmg` + TestFlight | ⚠️ old build shipped | What users install. |
| **Web** (download page, rooms, invites) | Cloudflare **Workers** | ⚠️ partial | The download site + shareable room links. |

The single hard blocker is the **SFU**. The Swift app is finished and tested; it just needs a server
to connect to.

---

## 1. The media plane — the one true blocker

Every real-time feature this session added (webcam tiles, screen share, draw, clipboard, remote
control, rooms, browser-watch) rides the LiveKit media plane. There is **no hosted SFU** today:

- `apps/livekit/` has a ready `docker-compose` (LiveKit `v1.13.3` + the Go token server) but it is
  **shipped dark** — no host, no domain, no TLS, no real API key.
- Local dev uses `ws://localhost:7880` (`bun run livekit`).
- TestFlight testers currently reach an SFU via an **ephemeral ngrok tunnel** (`bun run
  tunnel:testflight`) — rotates every restart, "NOT a real deployment."
- `sfu.cheffing.dev` was a placeholder I wrote into the rooms worker; **it never existed** (now
  cleared).

### Pick ONE way to get an SFU (both keep the existing LiveKit SDK — no app rewrite)

**Option A — LiveKit Cloud (recommended for beta).** Managed, zero ops, and it *is* LiveKit, so
`JoeScreenLiveKit` works unchanged.
1. Create a project at cloud.livekit.io → you get a `wss://<project>.livekit.cloud` URL + an API
   key/secret.
2. Point the app's token server (or the app's `serverURL`) at it; put the key/secret only on the
   token server, never in the app.
3. Cost: generous free tier, then usage-based. No server to babysit.

**Option B — Self-host the compose stack on a small VPS (~$5–12/mo).** You own it end to end.
1. Provision a VPS (Hetzner CX22 / DigitalOcean / Fly.io, 2 vCPU / 4 GB is plenty for early beta).
2. Point a domain at it, e.g. `sfu.<yourdomain>` → the host's public IP (A record).
3. Get TLS certs (Let's Encrypt) → `apps/livekit/certs/fullchain.pem` + `privkey.pem` (the embedded
   TURN-over-TLS on :443 needs them; that's what traverses corporate firewalls).
4. Generate a real key/secret:
   `docker run --rm livekit/livekit-server:v1.13.3 generate-keys`
   → put in `apps/livekit/.env` (`LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` / `LIVEKIT_URL=wss://sfu.<yourdomain>`)
   and set `keys:` in `livekit.yaml` + `turn.domain`.
5. Open the firewall: **7880/tcp** (signaling), **7881/tcp** (ICE-TCP fallback), **50000–50100/udp**
   (RTP media), **443/tcp** (TURN/TLS).
6. `cd apps/livekit && docker compose up -d`.

### Why NOT Cloudflare Containers for the SFU (asked directly)
It won't work — capability mismatch, not cost:
- **No public inbound UDP.** WebRTC media needs the `50000–50100/udp` range reachable from peers;
  Containers are reached through the Workers/HTTP layer, so ICE can't deliver media.
- **No stable per-container public IP** to advertise in ICE candidates.
- **Scale-to-zero is exactly wrong for calls** — a container that sleeps when idle cold-starts *at
  the moment someone tries to join*, i.e. dead air on join; it can't already be "in the room."
- Containers are billed/positioned for request- or CPU-bound sidecars (headless browser, ffmpeg,
  sandboxes), not persistent low-latency media relays.

(Cloudflare *does* have a managed WebRTC SFU — **Cloudflare Realtime/Calls** — but it is NOT LiveKit;
adopting it means replacing the entire media plane + SDK, a large rewrite that breaks the R22
one-media-SDK design. Only consider it as a deliberate future migration, not a quick swap.)

### Also deploy the token server (both options)
The app fetches a short-lived, room-scoped JWT from the Go token server (`apps/livekit/token-server`)
so the LiveKit secret never ships in the binary. With Option B it's already in the compose stack
(expose `/token` behind HTTPS). With Option A you still run the token server (or LiveKit Cloud's
token endpoint) — the app's release path calls `TokenClient.fetch(server:room:identity:name:)`.

---

## 2. The app plane — ship the new build

The `.dmg` in R2 and the TestFlight build **both predate this session** — none of the M9–M11/backlog
work is in what users can install until you cut new builds.

### macOS (direct download → joescreen.cheffing.dev)
Needs: an Apple **Developer-ID Application** cert in your login keychain + notarization creds.
```sh
# 0. (optional) bump MARKETING_VERSION / build number in apps/joescreen/Apps/project.yml
bun run dist:mac      # build + notarize + staple → JoeScreen.dmg   (keychain password prompt)
bun run publish:dmg   # upload the .dmg to R2 (Cloudflare auth needed)  → /download serves it
# then bump src/changelog.ts + push → the page redeploys
```

### iOS (TestFlight)
Needs: the ASC pieces already present in `.env.testflight` (Team `6UU3BC5GB2`, ASC key, `.p8`).
```sh
bun run testflight ios          # bump build → archive → export → upload
# wait for Apple to mark it VALID (a few min), then:
bun run testflight:review ios   # attach to testers + submit Beta App Review (~1 day first time)
# commit the bumped build number in project.yml
```
Public join link (live once review passes): https://testflight.apple.com/join/C3AdpdZJ
Note: iOS is a **viewer + voice** client (no control/share — R6).

**Important:** the app must be pointed at the real SFU (§1). For a Release build that's the token
server URL it fetches from; for a quick TestFlight smoke test today it's the ngrok tunnel.

---

## 3. The web plane — Cloudflare Workers

Three worker apps; the download-site half is essentially ready, the rooms half waits on the SFU.

### joescreen-download → joescreen.cheffing.dev  ✅ ready
Serves the landing page (with the new "What's new" changelog + the "iOS beta on TestFlight" button)
and streams the `.dmg` from the `joescreen-downloads` R2 bucket. Deploys automatically via CI on push
to `main` (path `apps/joescreen-download/**`). **To make the newest version live:** run `dist:mac` +
`publish:dmg` (§2), prepend a release to `src/changelog.ts`, push.
- Requires: the `joescreen-downloads` R2 bucket to exist on the account (already referenced; verify
  it's created, or `wrangler r2 bucket create joescreen-downloads`).

### joescreen-rooms → rooms.cheffing.dev  ⏸ deferred until the SFU exists
Slug directory + invite pages + presence + browser view-only tokens. **Currently skipped by CI** (a
`.deploy-disabled` marker) because with no SFU it would hand out dead invite links.
- The ROOMS **KV namespace is already provisioned** (`d722a68c…` in `wrangler.jsonc`).
- To enable, once the SFU is up:
  1. Set `LIVEKIT_URL` (wss://…) + `LIVEKIT_API_URL` (https://…) in `wrangler.jsonc` (production env).
  2. `cd apps/joescreen-rooms && bunx wrangler secret put --env production LIVEKIT_API_KEY` (and
     `LIVEKIT_API_SECRET`) — powers presence + browser view-only tokens.
  3. Delete `apps/joescreen-rooms/.deploy-disabled` and push → CI deploys it.
  4. (Custom domain: `rooms.cheffing.dev` route needs the `cheffing.dev` zone on the account, same as
     the download site.)

### cheffing-hub  ✅ (pre-existing, unrelated to this session)

---

## 4. Client-side grants (per Mac, one-time) — for the person USING the app
These aren't "deploy" steps but the features don't work without them. macOS prompts on first use:
- **Screen Recording** — required to share any window/screen.
- **Camera + Microphone** — for webcam tiles + voice.
- **Accessibility / `kTCCServicePostEvent`** — only for remote *control* (typing/clicking into a
  shared window). Ships OFF by default; the owner grants when they enable control.
Password-manager/Keychain windows are never shareable regardless (built-in blocklist).

---

## Recommended order

1. **Stand up the SFU** — Option A (LiveKit Cloud, fastest) or B (VPS). This unblocks everything.
2. **Point the token server / app at it**; smoke-test a 2-Mac call locally.
3. **Cut new builds:** `dist:mac` + `publish:dmg` + changelog bump (macOS); `testflight ios` +
   `testflight:review ios` (iOS). Bump the version if you like (still 0.1.0, early beta).
4. **Enable rooms:** set the SFU vars + secrets, delete the marker, push → rooms.cheffing.dev live.
5. **Grant TCC** on each dev/test Mac and run the Tier-2 hardware checks in `TESTING.md`.

The full per-feature human-gated list (with time estimates) is the `## Human TODO` ledger at the
bottom of `docs/COSCREEN_PARITY_PLAN.md`.
