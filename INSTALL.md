# Install Frugal

> Source content for the frugal.run install page. Everything below is
> customer-facing; commands are plain `az` CLI and work identically in
> bash, zsh, PowerShell and Azure Cloud Shell.

Frugal is an Azure operations platform — virtual desktop management, cost
analytics and governance — that deploys **into your own Azure subscription**.
Your data never leaves your tenant. There are no agents, no stored secrets,
and no access granted to anyone outside your organisation: the app runs
under a managed identity with read-only cost access and AVD rights scoped
to its own resource group.

---

## What gets deployed

One resource group (default `rg-frugal`) containing:

| Resource | Purpose | Typical cost |
|---|---|---|
| Container App (0.5 vCPU / 1 GiB, scales to zero) | the Frugal app | ~$0 idle |
| PostgreSQL Flexible Server (B1ms, 32 GB) | app database | ~$21/mo |
| Log Analytics workspace | logs | ~$0 (free tier) |
| Key Vault, Managed Identity, Container Apps environment | plumbing | ~$0 |

Plus, outside the resource group:

- An **Entra ID app registration** ("Frugal") with three app roles —
  Admin / Operator / Viewer — used for sign-in. The person who installs is
  granted Admin automatically.
- Role assignments for the managed identity: **Reader** and
  **Cost Management Reader** on the subscription, and
  **Desktop Virtualization Contributor** on the Frugal resource group.

Total running cost: **roughly $21–25/month**, dominated by the database.
The app container costs nothing while idle (first request after idle takes
~30 seconds to warm up).

---

## Prerequisites

You need, in the subscription/tenant you're installing into:

1. **Owner** on the subscription (the deploy creates role assignments)
2. **Global Administrator** in the Entra tenant — or, for least privilege,
   the pair **Application Administrator + Privileged Role Administrator**.
   The deploy both creates the app registration (Application Administrator)
   *and* grants the managed identity Microsoft Graph application permissions
   in step 3 (`User.Read.All` / `Group.Read.All` / `Application.Read.All`).
   Only Privileged Role Administrator or Global Administrator can consent to
   Microsoft Graph app roles — Application / Cloud Application Administrator
   **cannot**, so Application Administrator alone is not sufficient.
3. [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
   2.61+ — or just use [Azure Cloud Shell](https://shell.azure.com), which
   has everything preinstalled

Self-check before you start:

```
az login
az account show --query "{subscription:name, tenant:tenantId}"
az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) \
  --query "[?roleDefinitionName=='Owner'].scope"
```

The last command should list your subscription scope. If it's empty, ask
whoever manages your Azure for Owner, or have them run the install.

---

## Install — three commands

Pick a region close to your users (e.g. `australiaeast`, `eastus`,
`westeurope`) and use it consistently below.

**1 — Create the sign-in app registration.** Runs with your admin identity;
creates the Entra app, its service principal, and grants *you* the Frugal
Admin role.

```
az deployment sub create --location <region> --name frugal-auth \
  --template-uri https://raw.githubusercontent.com/abhijitsghosh/frugal-deploy/main/auth.json
```

📋 Note the `entraAppId` value in the outputs.

**2 — Deploy the platform.** A [deployment stack](https://learn.microsoft.com/azure/azure-resource-manager/bicep/deployment-stacks)
— Azure tracks everything it creates, so removal later is one command.
Takes 10–15 minutes (the database is the slow part).

```
az stack sub create --name frugal --location <region> \
  --template-uri https://raw.githubusercontent.com/abhijitsghosh/frugal-deploy/main/azuredeploy.json \
  --parameters containerImage=ghcr.io/abhijitsghosh/frugal:0.1.6 \
               dbAdminPassword=<choose a strong password> \
               entraApiClientId=<entraAppId from step 1> \
  --action-on-unmanage deleteAll --deny-settings-mode none --yes
```

📋 Note the `appUrl` **and `managedIdentityPrincipalId`** values in the outputs.

**3 — Register the app's URL for sign-in, and grant the managed identity
directory read.** Same template as step 1, now told where the app lives and
which managed identity to grant Microsoft Graph `User.Read.All` /
`Group.Read.All` / `Application.Read.All` (needed for user-assignment search
and the FSLogix admin-consent link):

```
az deployment sub create --location <region> --name frugal-auth \
  --template-uri https://raw.githubusercontent.com/abhijitsghosh/frugal-deploy/main/auth.json \
  --parameters appUrl=<appUrl from step 2> \
               managedIdentityObjectId=<managedIdentityPrincipalId from step 2>
```

> ⚠️ Don't omit `managedIdentityObjectId` — without it the managed identity
> gets no Graph permissions, and user search + FSLogix consent silently fail.

**4 — Recycle the app so it picks up the new permissions.** The container
started in step 2 cached its identity token *before* step 3 granted these
permissions — and Graph permissions only appear in a freshly-issued token. One
restart fixes it:

```
az containerapp revision restart -g rg-frugal -n frugal-app \
  --revision "$(az containerapp revision list -g rg-frugal -n frugal-app --query "[?properties.active].name | [0]" -o tsv)"
```

(The app also picks this up on its own within ~15 min — it scales to zero when
idle and the next cold start gets a fresh token — but restarting makes user
search and FSLogix consent work immediately.)

**Done.** Open the `appUrl` in a browser, sign in with your work account
(one consent prompt on first sign-in), and you land on the Frugal dashboard
as Admin.

---

## After installing

- **Add your team**: Entra admin center → Enterprise applications →
  Frugal → Users and groups → assign people (or groups) to the Admin,
  Operator or Viewer role.
- **Cost data** syncs nightly at 02:00 UTC. Azure's cost API itself lags
  up to ~72 hours, so a brand-new install shows numbers building up over
  the first couple of days.
- **AVD host pools** appear automatically for every subscription the
  managed identity can read.

### Enable FSLogix profiles (one-time consent)

The deploy provisions an Azure Files profile storage account
(`frugalfsl…` in `rg-frugal-avd`) with **Microsoft Entra Kerberos** — the
identity-based auth that lets Entra-joined session hosts mount profiles.
This needs a **single, one-time admin consent** for the storage account's
auto-created Kerberos app.

**Easiest:** in Frugal, expand a host pool — a **"Grant admin consent"** button
appears at the top of the provisioning view. Click it, approve in the Entra
prompt, done. (You must be a Global / Privileged Role / Cloud Application
admin — the deploying admin already qualifies.)

CLI fallback:

```bash
acct=$(az storage account list -g rg-frugal-avd \
  --query "[?starts_with(name,'frugalfsl')].name | [0]" -o tsv)
appId=$(az ad sp list --all \
  --query "[?contains(displayName,'$acct')].appId | [0]" -o tsv)
az ad app permission admin-consent --id "$appId"
```

Consent is **per storage account, once** — it never expires and isn't needed
again when you add users, hosts or pools. After that, turn FSLogix on per
host pool in Frugal (**Host Pools → expand a pool → FSLogix → Enable**); it
configures every host and grants assigned users profile access. **Reboot the
hosts** to apply (FSLogix mounts at logon; the Kerberos setting needs the
reboot).

---

## Upgrading

Re-run step 2 with a newer image tag, **pinning the resource-name suffix**
so the database and vault are untouched:

```
az stack sub show --name frugal --query "parameters.resourceNameSuffix.value" -o tsv
az stack sub create --name frugal --location <region> \
  --template-uri https://raw.githubusercontent.com/abhijitsghosh/frugal-deploy/main/azuredeploy.json \
  --parameters containerImage=ghcr.io/abhijitsghosh/frugal:<new version> \
               dbAdminPassword=<same password> \
               entraApiClientId=<same appId> \
               resourceNameSuffix=<value from the first command> \
  --action-on-unmanage deleteAll --deny-settings-mode none --yes
```

In-place upgrades take ~3 minutes with zero downtime — traffic moves to the
new revision once it's healthy.

---

## Uninstall

```
# 1. Remove all Azure resources (stack-tracked: RG, database, app, role assignments)
az stack sub delete --name frugal --action-on-unmanage deleteAll --yes

# 2. Remove the app registration — twice, because Entra soft-deletes first
az ad app delete --id <entraAppId>
az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.application?\$select=id,displayName"
az rest --method DELETE \
  --url "https://graph.microsoft.com/v1.0/directory/deletedItems/<id of the Frugal entry>"
```

The second deletion matters: a soft-deleted app keeps its internal unique
name reserved for 30 days, which blocks a future reinstall. If you do plan
to reinstall, also wait ~2 minutes after the hard delete for Entra's
directory replication.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Step 1 fails with `Authorization_RequestDenied` | You don't have app-registration rights in the tenant. See Prerequisites. |
| Step 1 fails with `property 'appId' doesn't exist` | A soft-deleted Frugal app is blocking reinstall. Run the hard-delete from Uninstall step 2, wait ~2 minutes, retry. |
| Step 2 fails with `RoleDefinitionDoesNotExist` or role errors | You're not Owner on the subscription. |
| Sign-in loops or shows `AADSTS50011` (redirect mismatch) | Step 3 wasn't run, or was run with the wrong `appUrl`. Re-run step 3 with the exact `appUrl` from step 2's outputs. |
| Sign-in works but every page says access denied | Your account has no Frugal role. The installer gets Admin automatically; everyone else is assigned via Enterprise applications → Frugal → Users and groups. |
| First page load takes ~30 s | Normal — the app scales to zero when idle and is cold-starting. |
| Deployed seconds after a new Frugal release and hit an odd template error | The template CDN caches for ~5 minutes. Wait a few minutes and retry. |
| Cost pages are empty on day one | Azure Cost Management data lags up to 72 h; the nightly sync fills it in. |
