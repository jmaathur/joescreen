#!/usr/bin/env bash
# Push Cloudflare secrets from .env.production into GitHub Actions (production environment).
# Adapted from the golf-app monorepo's push-github-secrets.sh, simplified to production-only.
#
# The CI workflow (.github/workflows/cloudflare-deploy-prod.yml) references CLOUDFLARE_API_TOKEN and
# CLOUDFLARE_ACCOUNT_ID WITHOUT a prefix, scoped by the job's `environment: production`. So we push
# them verbatim (no prefix) into the repo's `production` environment.
#
# Usage:
#   scripts/push-github-secrets.sh [--repo OWNER/REPO] [--dry-run]
set -euo pipefail

REPO="jmaathur/joescreen"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--repo) REPO="$2"; shift 2 ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help) sed -n '2,14p' "$0"; exit 0 ;;
		*) echo "unknown arg: $1" >&2; exit 2 ;;
	esac
done

command -v gh >/dev/null || { echo "❌ gh CLI not installed. brew install gh" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "❌ gh not authenticated. Run: gh auth login" >&2; exit 1; }

cd "$(dirname "$0")/.."
FILE=".env.production"
[ -f "$FILE" ] || { echo "❌ $FILE not found (copy .env.production.example and fill it in)" >&2; exit 1; }

# Ensure the 'production' environment exists (gh secret set --env requires it).
if [ "$DRY_RUN" -eq 0 ]; then
	gh api -X PUT "repos/$REPO/environments/production" >/dev/null 2>&1 || true
fi

# Read a KEY=VALUE from the env file (strips quotes/whitespace/comments); print value or empty.
read_val() {
	local key="$1" line val
	line="$(grep -E "^${key}=" "$FILE" | head -1 || true)"
	[ -n "$line" ] || { printf ''; return; }
	val="${line#*=}"
	val="${val%"${val##*[![:space:]]}"}"       # trim trailing ws
	case "$val" in \"*\") val="${val%\"}"; val="${val#\"}";; \'*\') val="${val%\'}"; val="${val#\'}";; esac
	printf '%s' "$val"
}

echo "── pushing production secrets → $REPO (environment: production)"
count=0
for key in CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID; do
	val="$(read_val "$key")"
	if [ -z "$val" ]; then echo "  ⚠ $key is empty in $FILE — skipping"; continue; fi
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "  [dry-run] gh secret set $key --repo $REPO --env production (len=${#val})"
	else
		gh secret set "$key" --repo "$REPO" --env production --body "$val"
		echo "  ✓ $key"
	fi
	count=$((count + 1))
done
echo "✅ done ($count secret(s))"
