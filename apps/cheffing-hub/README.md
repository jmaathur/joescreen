# cheffing-hub

The `cheffing.dev` root — a hub landing page listing the cheffing dev tools. Each tool lives on its
own subdomain (e.g. `joescreen.cheffing.dev`). Cloudflare Worker (Hono), no bindings.

## Add a tool
Edit `TOOLS` in `src/page.ts` (name, blurb, subdomain href, badge). Set `live: true` when it ships.

## Local dev
```sh
cd apps/cheffing-hub && bun run dev   # http://localhost:3020
```

## Deploy
- **Automatic:** merges to `main` touching `apps/cheffing-hub/**` deploy production via
  `.github/workflows/cloudflare-deploy-prod.yml`.
- **Manual:** `cd apps/cheffing-hub && bun run deploy`.

Serves `cheffing.dev` + `www.cheffing.dev` (custom-domain routes in `wrangler.jsonc`). Requires the
cheffing.dev zone on your Cloudflare account — see `docs/CLOUDFLARE_SETUP.md`.
