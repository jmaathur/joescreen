# joescreen-rooms

Rooms + HTTPS invite links for JoeScreen (backlog #7 / F13-lite). A Cloudflare Worker (Hono),
following the `joescreen-download` / cheffing.dev pattern.

## What it does
- **Slug directory (KV):** `POST /rooms` allocates a short slug (random or a custom one) → a
  `{ room, sfu, title }` record in the `ROOMS` KV namespace. Collisions 409; invalid custom slugs 400.
- **Invite page:** `GET /r/<slug>` is a shareable landing page that OpenGraph-unfurls in Slack/iMessage,
  fires the `joescreen://join?server=…&room=…` deep link (identity omitted — fresh per joiner), and
  falls back to the download page for anyone without the app.
- **Presence-lite:** the page + `GET /api/rooms/<slug>` show a live participant count via the LiveKit
  RoomService `ListParticipants` (Twirp), authorized with a short-lived admin JWT minted Worker-side.
  Presence degrades to "unknown" (never 500s) when the RoomService isn't configured.

- **Browser view-only join (backlog #8):** `GET /watch/<slug>` mints a subscribe-only token
  Worker-side (`canSubscribe:true, canPublish:false, canPublishData:false`) and serves a static
  `livekit-client` page that renders the room's `window:`/`display:` share tracks. Element-size-driven
  adaptiveStream holds R24/R32. `GET /api/rooms/<slug>/token` returns the token as JSON for embedders.

**No APP-token minting** — that stays in the Go token server (`apps/livekit/token-server`,
DECISIONS §5.4). Only browser view-only tokens are minted Worker-side (WebCrypto HS256).

## Machine-verified (this repo)
- `bun run test` (vitest) — slug validation/generation/normalization, deep-link shape, HS256 signing,
  presence degradation + counting. 12 tests.
- `bun run check-types` (tsc) — clean.
- Local `wrangler dev --local` smoke: create custom/random slug, invite page renders with OG +
  deep link, `/api/rooms/<slug>` JSON, 404 unknown slug, 409 collision — all verified.

## Human TODO (deploy)
1. `wrangler kv namespace create ROOMS` → put the returned id into `wrangler.jsonc` (both the top-level
   and the `production` env), replacing `REPLACE_WITH_KV_ID`.
2. `wrangler secret put --env production LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` (for presence).
3. Set `production.vars.LIVEKIT_URL` / `LIVEKIT_API_URL` to the real SFU (wss/https).
4. `bun run deploy` — serves at `rooms.cheffing.dev` (custom-domain route; the cheffing.dev zone must
   be on the account, same as `joescreen-download`).
