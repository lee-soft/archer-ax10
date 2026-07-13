#!/bin/sh
# ============================================================
# deploy-to-pages.sh — redeploy the TP-Link Archer AX10 boot payload to
# Cloudflare Pages (archer-boot.pages.dev). The router fetches everything
# from Pages at boot, so this is the ONLY step to push updated boot files.
# NO router change is needed after a deploy (the openvpn up-hook is stable).
#
# Usage:   ./deploy-to-pages.sh
# Edit the assets in this repo first, then run this.
# ============================================================
set -e
# Repo root = this script's directory.
BOOTSERVE="$(cd "$(dirname "$0")" && pwd)"
# Cloudflare API token file (override with CF_TOKEN_FILE); keep it OUTSIDE the repo.
TOKEN_FILE="${CF_TOKEN_FILE:-$HOME/.archer-boot-cf-token}"
# Your Cloudflare account id — supply via the environment, never commit it.
ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:?set CLOUDFLARE_ACCOUNT_ID to your Cloudflare account id}"
PROJECT="${CF_PAGES_PROJECT:-archer-boot}"
APEX="${CF_PAGES_APEX:-https://$PROJECT.pages.dev}"

# The 9 runtime assets the router pulls (must match boot.sh's $SRC fetches +
# the up-hook's boot.sh). Keep this list in sync if boot.sh gains an asset.
# Only what the slim boot.sh fetches directly. The old luci-stack/luci-dist/
# wifiapply/wifiwatch/webwatch are now embedded in their ax10-*.ipk (under repo/)
# and no longer published standalone (pruned 2026-07-12).
ASSETS="boot.sh busybox-armv7l opt.tar.gz dropbear_vanilla"

fail() { echo "ERROR: $*" >&2; exit 1; }

# --- token ---
[ -f "$TOKEN_FILE" ] || fail "no token at $TOKEN_FILE.
  Get a fresh Cloudflare token (account-scoped, permission 'Cloudflare Pages: Edit')
  from the CF dashboard, then:  printf '%s' '<token>' > $TOKEN_FILE && chmod 600 $TOKEN_FILE"
TOKEN=$(cat "$TOKEN_FILE")

echo ">> verifying token..."
curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/tokens/verify" \
  -H "Authorization: Bearer $TOKEN" | grep -q '"success":true' || fail "CF token invalid/EXPIRED.
  Get a fresh token (Pages:Edit) and overwrite $TOKEN_FILE (see above)."

# --- validate assets ---
echo ">> syntax-checking boot.sh..."
sh -n "$BOOTSERVE/boot.sh" || fail "boot.sh has a syntax error — aborting before publish."
for f in $ASSETS; do [ -f "$BOOTSERVE/$f" ] || fail "missing asset: $f"; done

# --- stage (only the runtime assets + a manifest, never the .bak/.cf-token) ---
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
for f in $ASSETS; do cp "$BOOTSERVE/$f" "$STAGE/"; done
( cd "$STAGE" && md5sum $ASSETS > manifest.md5 \
  && { printf '<h1>archer-boot</h1><pre>'; cat manifest.md5; printf '</pre>'; } > index.html )
echo ">> staged $(echo $ASSETS | wc -w) assets + manifest.md5 + index.html"
# publish the ax10-* opkg feed too, if built (repo/Packages(.gz) + *.ipk)
if [ -d "$BOOTSERVE/repo" ]; then
  cp -r "$BOOTSERVE/repo" "$STAGE/repo"
  echo ">> staged opkg feed: $(ls "$BOOTSERVE/repo"/*.ipk 2>/dev/null | wc -l) .ipk(s) under /repo"
fi

# --- ensure project exists (idempotent; harmless if already there) ---
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/pages/projects" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"name\":\"$PROJECT\",\"production_branch\":\"main\"}" >/dev/null 2>&1 || true

# --- deploy ---
echo ">> deploying to Cloudflare Pages ($PROJECT)..."
export CLOUDFLARE_API_TOKEN="$TOKEN" CLOUDFLARE_ACCOUNT_ID="$ACCOUNT_ID" CI=1
npx --yes wrangler@3 pages deploy "$STAGE" --project-name="$PROJECT" --branch=main --commit-dirty=true

# --- verify apex serves the new boot.sh (allow for edge-cache propagation) ---
want=$(md5sum "$BOOTSERVE/boot.sh" | awk '{print $1}')
echo ">> verifying apex serves boot.sh md5 $want ..."
ok=""
for i in 1 2 3 4 5 6; do
  sleep 5
  got=$(curl -s "$APEX/boot.sh" | md5sum | awk '{print $1}')
  [ "$want" = "$got" ] && { ok=1; break; }
  echo "   (attempt $i: apex still $got — edge-cache lag, retrying)"
done
if [ -n "$ok" ]; then
  echo "OK: $APEX/boot.sh md5 matches ($want). Router will pull the new payload on its next boot."
else
  echo "WARN: apex md5 still differs after ~30s (edge cache). It usually settles within a minute; re-check: curl -s $APEX/boot.sh | md5sum"
fi
echo
echo "Done. To make the change take effect NOW rather than next boot, on the router run:"
echo "  /usr/bin/curl -4 -L -k -fs -o /tmp/b.sh $APEX/boot.sh && /bin/sh /tmp/b.sh"
