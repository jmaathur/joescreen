# joescreen-download

Public download site for the JoeScreen **macOS** app — a Cloudflare Worker (Hono) that serves a
landing page and streams the notarized `.dmg` from R2. (The macOS app can't use TestFlight — it's
non-sandboxed for input injection — so it's distributed as a notarized Developer-ID `.dmg`.)

## Routes
- `GET /` — landing page with a **Download for macOS** button
- `GET /download` — streams the current `.dmg` from R2 (`attachment`; 404 until one is published)
- `GET /version` — `{ version, env }`

## One-time setup (you, in Cloudflare)
```sh
bunx wrangler login                                   # authenticate
bunx wrangler r2 bucket create joescreen-downloads    # create the bucket the worker reads
```
For CI deploys, add repo **secrets** `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID`
(Settings → Secrets → Actions), and a `production` environment.

## Publish a build
From the repo root:
```sh
bun run dist:mac        # build + notarize + staple → apps/joescreen/build/dist-mac/JoeScreen.dmg
bun run publish:dmg     # upload that .dmg to r2://joescreen-downloads/JoeScreen.dmg
```
When you ship a new version, prepend a release to **`src/changelog.ts`** (the single source of truth
for the version badge + the page's "What's new" section) and add the matching entry to the repo's
`/CHANGELOG.md`. `APP_VERSION` in `wrangler.jsonc` is only a fallback if the release list is empty.

## Deploy the worker
- **Automatic:** merges to `main` that touch `apps/joescreen-download/**` deploy production via
  `.github/workflows/cloudflare-deploy-prod.yml`.
- **Manual:**
  ```sh
  cd apps/joescreen-download && bun run deploy
  ```
It lands on `joescreen-download.<you>.workers.dev`; add a Custom Domain (e.g. `get.joescreen.com`)
in the Cloudflare dashboard when ready.

## Local dev
```sh
cd apps/joescreen-download && bun run dev     # http://localhost:3010
```
`/download` 404s locally unless you put an object in the local R2 sim (or use `--remote`).
