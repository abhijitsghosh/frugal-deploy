#!/usr/bin/env bash
#
# Frugal one-shot installer — runs the whole secret-less install and passes the
# outputs between steps for you (no copy-pasting GUIDs).
#
# Designed for Azure Cloud Shell (Bash), so it works the same from Windows,
# macOS or Linux — open https://shell.azure.com and run:
#
#   curl -sL https://frugal.run/install.sh | bash -s -- --region eastus
#
# Prerequisites in the target subscription/tenant:
#   * Owner on the subscription (the deploy creates role assignments)
#   * Global Administrator, or Application Administrator + Privileged Role Administrator
#
set -euo pipefail

BASE="https://raw.githubusercontent.com/abhijitsghosh/frugal-deploy/main"
REGION=""; IMAGE_TAG="latest"; DB_PASSWORD=""; SUBSCRIPTION=""

usage() {
  echo "Usage: install.sh --region <azure-region> [--image-tag <ver>] [--subscription <id>] [--db-password <pw>]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--region)       REGION="${2:-}"; shift 2;;
    -t|--image-tag)    IMAGE_TAG="${2:-}"; shift 2;;
    -p|--db-password)  DB_PASSWORD="${2:-}"; shift 2;;
    -s|--subscription) SUBSCRIPTION="${2:-}"; shift 2;;
    -h|--help)         usage;;
    *) echo "Unknown option: $1"; usage;;
  esac
done
[[ -z "$REGION" ]] && usage

command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found. Run this in Azure Cloud Shell: https://shell.azure.com"; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: not signed in. Run 'az login' first (automatic in Cloud Shell)."; exit 1; }
[[ -n "$SUBSCRIPTION" ]] && az account set --subscription "$SUBSCRIPTION"

echo "▶ Installing Frugal into subscription: $(az account show --query name -o tsv) (region $REGION)"
[[ -z "$DB_PASSWORD" ]] && DB_PASSWORD="Fg$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 22)9!"

echo "▶ [1/3] Creating the sign-in app registration…"
ENTRA_APP_ID=$(az deployment sub create --location "$REGION" --name frugal-auth \
  --template-uri "$BASE/auth.json" --only-show-errors \
  --query "properties.outputs.entraAppId.value" -o tsv)
echo "    app id: $ENTRA_APP_ID"

echo "▶ [2/3] Deploying the platform — 10–15 min (the database is the slow part)…"
az stack sub create --name frugal --location "$REGION" \
  --template-uri "$BASE/azuredeploy.json" \
  --parameters containerImage="ghcr.io/abhijitsghosh/frugal:$IMAGE_TAG" \
               dbAdminPassword="$DB_PASSWORD" \
               entraApiClientId="$ENTRA_APP_ID" \
  --action-on-unmanage deleteAll --deny-settings-mode none --yes --only-show-errors -o none
APP_URL=$(az stack sub show --name frugal --query "outputs.appUrl.value" -o tsv)
MI_PRINCIPAL=$(az stack sub show --name frugal --query "outputs.managedIdentityPrincipalId.value" -o tsv)
echo "    app url: $APP_URL"

echo "▶ [3/3] Registering the URL + granting the managed identity directory read…"
az deployment sub create --location "$REGION" --name frugal-auth \
  --template-uri "$BASE/auth.json" --only-show-errors -o none \
  --parameters appUrl="$APP_URL" managedIdentityObjectId="$MI_PRINCIPAL"

# Recycle so the freshly-issued token carries the new Graph permissions.
REV=$(az containerapp revision list -g rg-frugal -n frugal-app --query "[?properties.active].name | [0]" -o tsv 2>/dev/null || true)
[[ -n "${REV:-}" ]] && az containerapp revision restart -g rg-frugal -n frugal-app --revision "$REV" --only-show-errors -o none 2>/dev/null || true

cat <<EOF

✅ Frugal is installed.

   Open:   $APP_URL
   Sign in with your work account (one consent prompt) — you land as Admin.
   Next:   expand a host pool → "Grant admin consent" to turn on FSLogix profiles.

   Tear down later:
     az stack sub delete --name frugal --action-on-unmanage deleteAll --yes
EOF
