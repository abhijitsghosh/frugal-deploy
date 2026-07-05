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
# The Entra app registration is created directly via Microsoft Graph (az rest),
# NOT the Microsoft Graph Bicep extension — that extension is preview and has
# proven unreliable. Only the platform itself is deployed as an ARM stack.
#
# Prerequisites in the target subscription/tenant:
#   * Owner on the subscription (the deploy creates role assignments)
#   * Global Administrator, or Application Administrator + Privileged Role Administrator
#
set -euo pipefail

BASE="https://raw.githubusercontent.com/abhijitsghosh/frugal-deploy/main"
GRAPH="https://graph.microsoft.com/v1.0"
REGION=""; IMAGE_TAG="latest"; DB_PASSWORD=""; SUBSCRIPTION=""

# Stable role/scope ids so re-runs and the app manifest stay consistent.
ADMIN_ROLE_ID="22222222-2222-2222-2222-2222000000a1"
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"           # Microsoft Graph
MI_GRAPH_ROLES=(                                              # granted to the managed identity
  df021288-bdef-4463-88db-98f22de89214   # User.Read.All
  5b567255-7703-4780-807c-7be8301ae99b   # Group.Read.All
  9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30   # Application.Read.All
  7ab1d382-f21e-4acd-a863-ba3e13f7da61   # Directory.Read.All
)

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
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found (it's preinstalled in Azure Cloud Shell)."; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: not signed in. Run 'az login' first (automatic in Cloud Shell)."; exit 1; }
[[ -n "$SUBSCRIPTION" ]] && az account set --subscription "$SUBSCRIPTION"

TENANT=$(az account show --query tenantId -o tsv)
echo "▶ Installing Frugal into subscription: $(az account show --query name -o tsv) (region $REGION)"
[[ -z "$DB_PASSWORD" ]] && DB_PASSWORD="Fg$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 22)9!"

# ---------- [1/3] Entra app registration (via Microsoft Graph) ----------
echo "▶ [1/3] Creating the sign-in app registration…"
ID_URI="api://frugal-${TENANT}"   # stable identifier → idempotent on re-run
APP_ID=$(az ad app list --identifier-uri "$ID_URI" --query "[0].appId" -o tsv 2>/dev/null || true)
if [[ -z "${APP_ID:-}" || "$APP_ID" == "null" ]]; then
  MANIFEST=$(mktemp)
  cat > "$MANIFEST" <<JSON
{
  "displayName": "Frugal",
  "signInAudience": "AzureADMyOrg",
  "identifierUris": ["$ID_URI"],
  "api": {
    "requestedAccessTokenVersion": 2,
    "oauth2PermissionScopes": [{
      "id": "11111111-1111-1111-1111-1111000000a1",
      "adminConsentDescription": "Allow signed-in users to call the Frugal API on their behalf.",
      "adminConsentDisplayName": "Access Frugal",
      "userConsentDescription": "Allow this app to call Frugal on your behalf.",
      "userConsentDisplayName": "Access Frugal",
      "type": "User", "value": "access_as_user", "isEnabled": true
    }]
  },
  "appRoles": [
    {"id":"$ADMIN_ROLE_ID","allowedMemberTypes":["User"],"description":"Full control: register subscriptions, manage images, all reads/writes.","displayName":"Admin","value":"Admin","isEnabled":true},
    {"id":"22222222-2222-2222-2222-2222000000a2","allowedMemberTypes":["User"],"description":"Operate: trigger syncs, drain/scale host pools, refresh image catalog.","displayName":"Operator","value":"Operator","isEnabled":true},
    {"id":"22222222-2222-2222-2222-2222000000a3","allowedMemberTypes":["User"],"description":"Read-only access to dashboards, costs and inventory.","displayName":"Viewer","value":"Viewer","isEnabled":true}
  ],
  "spa": { "redirectUris": [] },
  "web": { "redirectUris": [] }
}
JSON
  APP_ID=$(az rest --method POST --url "$GRAPH/applications" \
    --headers "Content-Type=application/json" --body @"$MANIFEST" --query appId -o tsv)
  rm -f "$MANIFEST"
fi
echo "    app id: $APP_ID"

# Service principal for the app (idempotent) — retry for Entra replication lag.
SP_OBJ=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || true)
if [[ -z "${SP_OBJ:-}" || "$SP_OBJ" == "null" ]]; then
  for _ in 1 2 3 4 5; do
    SP_OBJ=$(az ad sp create --id "$APP_ID" --query id -o tsv 2>/dev/null || true)
    [[ -n "${SP_OBJ:-}" && "$SP_OBJ" != "null" ]] && break
    sleep 8
  done
fi

# Grant the deploying admin the Frugal Admin app role (ignore if already assigned).
ME=$(az ad signed-in-user show --query id -o tsv)
az rest --method POST --url "$GRAPH/servicePrincipals/$SP_OBJ/appRoleAssignedTo" \
  --headers "Content-Type=application/json" \
  --body "{\"principalId\":\"$ME\",\"resourceId\":\"$SP_OBJ\",\"appRoleId\":\"$ADMIN_ROLE_ID\"}" \
  --only-show-errors -o none 2>/dev/null || true

# ---------- [2/3] Platform (ARM deployment stack) ----------
echo "▶ [2/3] Deploying the platform — 10–15 min (the database is the slow part)…"
az stack sub create --name frugal --location "$REGION" \
  --template-uri "$BASE/azuredeploy.json" \
  --parameters containerImage="ghcr.io/abhijitsghosh/frugal:$IMAGE_TAG" \
               dbAdminPassword="$DB_PASSWORD" \
               entraApiClientId="$APP_ID" \
  --action-on-unmanage deleteAll --deny-settings-mode none --yes --only-show-errors -o none
APP_URL=$(az stack sub show --name frugal --query "outputs.appUrl.value" -o tsv)
MI_PRINCIPAL=$(az stack sub show --name frugal --query "outputs.managedIdentityPrincipalId.value" -o tsv)
echo "    app url: $APP_URL"

# ---------- [3/3] Redirect URI + managed-identity Graph grants ----------
echo "▶ [3/3] Registering the sign-in URL + granting the managed identity directory read…"
APP_OBJ=$(az ad app show --id "$APP_ID" --query id -o tsv)
az rest --method PATCH --url "$GRAPH/applications/$APP_OBJ" \
  --headers "Content-Type=application/json" \
  --body "{\"spa\":{\"redirectUris\":[\"$APP_URL\"]}}" --only-show-errors -o none

# Grant the managed identity read-only Graph roles (user/group search + FSLogix
# consent link + consent verification). Ignore 'already assigned' on re-runs.
GRAPH_SP=$(az ad sp show --id "$GRAPH_APP_ID" --query id -o tsv)
for ROLE in "${MI_GRAPH_ROLES[@]}"; do
  az rest --method POST --url "$GRAPH/servicePrincipals/$MI_PRINCIPAL/appRoleAssignments" \
    --headers "Content-Type=application/json" \
    --body "{\"principalId\":\"$MI_PRINCIPAL\",\"resourceId\":\"$GRAPH_SP\",\"appRoleId\":\"$ROLE\"}" \
    --only-show-errors -o none 2>/dev/null || true
done

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
     az ad app delete --id $APP_ID
EOF
