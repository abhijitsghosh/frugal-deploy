#!/usr/bin/env bash
#
# Frugal in-place upgrade — safe, image-only roll.
#
#   curl -sL https://frugal.run/upgrade.sh | bash
#   curl -sL https://frugal.run/upgrade.sh | bash -s -- --image-tag 0.6.11
#
# Rolls ONLY the Container App image to the target version. The database and Key
# Vault are untouched, and the app runs its Flyway migrations on boot — so code
# AND schema upgrade with zero data loss. It deliberately does NOT re-run the
# install stack, which would mint a new resource suffix and stand up a fresh,
# empty database. Designed for Azure Cloud Shell (Bash), same as install.sh.
#
set -euo pipefail

RG="rg-frugal"
APP="frugal-app"
IMAGE_REPO="ghcr.io/abhijitsghosh/frugal"
VERSION_URL="https://raw.githubusercontent.com/abhijitsghosh/frugal-deploy/main/version.json"
TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--image-tag)      TAG="${2:-}"; shift 2;;
    -g|--resource-group) RG="${2:-}"; shift 2;;
    -n|--app)            APP="${2:-}"; shift 2;;
    -h|--help) echo "Usage: upgrade.sh [--image-tag <ver>] [--resource-group rg-frugal] [--app frugal-app]"; exit 0;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

az account show >/dev/null 2>&1 || { echo "ERROR: not signed in. Run 'az login' first (automatic in Cloud Shell)."; exit 1; }

# Target version: explicit --image-tag, else the latest published.
if [[ -z "$TAG" ]]; then
  TAG="$(curl -sL "$VERSION_URL" | (jq -r '.latest' 2>/dev/null || sed -n 's/.*"latest":"\([^"]*\)".*/\1/p'))"
fi
[[ -z "$TAG" || "$TAG" == "null" ]] && { echo "ERROR: couldn't determine the latest version."; exit 1; }

CURRENT="$(az containerapp show -g "$RG" -n "$APP" --query "properties.template.containers[0].image" -o tsv 2>/dev/null || true)"
[[ -z "$CURRENT" ]] && { echo "ERROR: Frugal app '$APP' not found in resource group '$RG'. Is it installed?"; exit 1; }

echo "▶ Current:  $CURRENT"
echo "▶ Upgrading to: $IMAGE_REPO:$TAG  (image-only — your database is preserved)…"
az containerapp update -g "$RG" -n "$APP" --image "$IMAGE_REPO:$TAG" -o none

FQDN="$(az containerapp show -g "$RG" -n "$APP" --query "properties.configuration.ingress.fqdn" -o tsv)"
echo "▶ Waiting for the new revision to become healthy…"
for _ in $(seq 1 40); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "https://${FQDN}/actuator/health" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] && { echo "✅ Upgraded to $TAG — healthy."; echo "   Open: https://${FQDN}"; exit 0; }
  sleep 6
done
echo "⚠ Rolled to $TAG, but health didn't return 200 in time. Check: https://${FQDN}"
exit 1
