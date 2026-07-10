# Cloudflare setup — cheffing.dev

The web layer lives in two Cloudflare Worker apps under `apps/`:

| App | Domain | What |
|---|---|---|
| `cheffing-hub` | `cheffing.dev`, `www.cheffing.dev` | Hub landing page listing the dev tools |
| `joescreen-download` | `joescreen.cheffing.dev` | JoeScreen macOS download site (streams the `.dmg` from R2) |

Future tools each get their own subdomain (`<tool>.cheffing.dev`) + their own worker app.

## One-time account setup

1. **Add the `cheffing.dev` zone to your Cloudflare account** (Dashboard → Add a site → cheffing.dev),
   and point the domain's nameservers at Cloudflare (at your registrar). Custom-domain worker routes
   only work once the zone is active on the account.

2. **Credentials.** Copy the templates and fill in real values (both files are gitignored):
   ```sh
   cp .env.example .env.local
   cp .env.production.example .env.production
   # edit both: CLOUDFLARE_ACCOUNT_ID + CLOUDFLARE_API_TOKEN
   ```
   API token scopes: **Workers Scripts:Edit**, **Account Settings:Read**, **Workers R2 Storage:Edit**
   (create at https://dash.cloudflare.com/profile/api-tokens). `wrangler` reads these from the env.

3. **R2 bucket** for the macOS `.dmg`. R2 is not yet enabled on the account — until it is, the
   production worker deploys **without** the DMG binding and `/download` returns 404.
   ```sh
   # 1. Dashboard → R2 → purchase the free plan (one-time enable; needs a billing profile).
   # 2. Then:
   bunx wrangler r2 bucket create joescreen-downloads
   # 3. Restore the commented-out "r2_buckets" block under env.production in
   #    apps/joescreen-download/wrangler.jsonc, redeploy, then `bun run publish:dmg`.
   ```

4. **GitHub Actions secrets** (for auto-deploy on merge to main):
   Repo → Settings → Secrets and variables → Actions → add `CLOUDFLARE_API_TOKEN` and
   `CLOUDFLARE_ACCOUNT_ID`, and create a `production` environment.

## Deploying

- **Automatic:** merge to `main`. `.github/workflows/cloudflare-deploy-prod.yml` deploys whichever
  worker app(s) changed. The custom-domain routes in each `wrangler.jsonc` create the DNS records.
- **Manual:**
  ```sh
  cd apps/cheffing-hub        && bun run deploy    # cheffing.dev
  cd apps/joescreen-download  && bun run deploy    # joescreen.cheffing.dev
  ```

## Publishing a new macOS build

```sh
bun run dist:mac       # build + notarize + staple the .dmg
bun run publish:dmg    # upload it to r2://joescreen-downloads/JoeScreen.dmg
```
Bump `APP_VERSION` in `apps/joescreen-download/wrangler.jsonc` so the page shows the new version.
